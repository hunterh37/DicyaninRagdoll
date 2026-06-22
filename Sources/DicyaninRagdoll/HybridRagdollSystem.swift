//
//  HybridRagdollSystem.swift
//  DicyaninRagdoll
//
//  Hybrid kinematic→physics skeletal ragdoll for RealityKit skinned models.
//
//  Invisible physics proxy entities (capsules / spheres + spherical joints) are built from a
//  skinned mesh's skeleton. While kinematic they ride the playing animation; on `activate` they
//  flip to dynamic and the system maps each proxy's world orientation back into a parent-local
//  joint rotation, writing the whole pose into `model.jointTransforms` in one batch per frame.
//
//  Key hard-won details preserved from the original:
//    • JointTransformBuffer (a class) avoids per-frame CoW copies of the 50+ joint array.
//    • Positional joint projection catches a stretched spherical pin the same frame it breaks
//      instead of letting it become a perpetual energy source ("ragdoll goes crazy").
//    • Per-frame velocity clamps + a settle timer freeze the rig once it has gone slow.
//    • Render-scale prescale is baked into modelWorld (NOT proxy.scale) — a non-unit scale on a
//      dynamic PhysicsBody breaks the spherical-joint cone solver.
//    • Cooked collision shapes are cached per (asset, scale, inflation, suffix) and can be
//      pre-warmed so the first activation doesn't cook 9 shapes on the hot frame.
//

import Foundation
import RealityKit
import simd

private extension float4x4 {
    init(_ t: Transform) {
        var m = float4x4(t.rotation)
        m.columns.0 *= t.scale.x; m.columns.1 *= t.scale.y; m.columns.2 *= t.scale.z
        m.columns.3 = SIMD4<Float>(t.translation.x, t.translation.y, t.translation.z, 1)
        self = m
    }
    var upperLeft3x3: float3x3 {
        float3x3(SIMD3(columns.0.x, columns.0.y, columns.0.z),
                 SIMD3(columns.1.x, columns.1.y, columns.1.z),
                 SIMD3(columns.2.x, columns.2.y, columns.2.z))
    }
}

/// Reference wrapper to avoid CoW copies of the joint transform array every frame.
/// Once ragdoll activates, the animation system no longer drives the skeleton, so
/// re-reading from model.jointTransforms is redundant — we mutate this in-place.
public final class JointTransformBuffer {
    public var transforms: [Transform]
    public init(_ transforms: [Transform]) { self.transforms = transforms }
}

// MARK: - Component

public struct HybridRagdollComponent: Component {

    public struct BoneLink {
        public let jointIndex: Int
        public let jointName: String
        public let suffix: String
        public let proxyEntity: Entity
        public let parentJointIndex: Int?
        public let parentProxyEntity: Entity?
    }

    public var model: ModelEntity
    public var bones: [BoneLink]
    public var rootProxyEntity: Entity
    public var rootJointOffset: SIMD3<Float> = .zero
    public var isActive: Bool = false
    public var showProxies: Bool = false
    /// Cached joint transforms — only read from model.jointTransforms once.
    /// Mutated in-place every subsequent frame to avoid full array copy + getter overhead.
    public var cachedJointTransforms: JointTransformBuffer?

    // MARK: - Settling state (anti-jitter)
    /// Seconds the rig has been active. Used to (a) ignore the first few frames where the
    /// joints snap into place, and (b) drive the settle timer.
    public var activeElapsed: TimeInterval = 0
    /// Seconds the whole rig has been continuously "slow" (below the settle thresholds).
    /// When this exceeds Tuning.settleTime the proxies are frozen to kinematic so the
    /// contact/joint solver can't keep re-injecting energy → no more crazy flailing.
    public var slowElapsed: TimeInterval = 0
    /// Once true the proxies are frozen and the system stops touching their physics.
    public var settled: Bool = false

    // MARK: - Diagnostics (set at build time)
    public var jointsAdded: Int = 0
    public var jointsFailed: Int = 0
    /// Each bone's joint anchor length measured at BUILD time, keyed by suffix.
    public var builtAnchorLengths: [String: Float] = [:]
}

// MARK: - System

public final class HybridRagdollSystem: System {

    public static let query = EntityQuery(where: .has(HybridRagdollComponent.self))
    public required init(scene: Scene) {}

    public func update(context: SceneUpdateContext) {
        let dt = context.deltaTime
        for entity in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            guard var rag = entity.components[HybridRagdollComponent.self],
                  rag.isActive else { continue }
            let firstFrame = rag.cachedJointTransforms == nil

            // Stabilize the physics BEFORE mapping proxies → mesh so a runaway velocity
            // never makes it into the rendered skeleton.
            let stateChanged = stabilize(rag: &rag, dt: dt)

            syncProxiesToSkeleton(rag: &rag, container: entity)
            // JointTransformBuffer is a class — its array mutates in-place each frame.
            // The struct itself only changes on the first frame (cache init) or when the
            // settle timers/flag advance, so we only write the component back then.
            if firstFrame || stateChanged { entity.components.set(rag) }
        }
    }

    /// Per-frame anti-jitter pass. Clamps each proxy's linear/angular velocity to the tuning
    /// ceilings and tracks how long the whole rig has stayed slow. Once it has been continuously
    /// slow for `settleTime` seconds the proxies are switched back to kinematic and left frozen.
    private func stabilize(rag: inout HybridRagdollComponent, dt: TimeInterval) -> Bool {
        if rag.settled { return false }

        let t = HybridRagdollRigBuilder.tuning
        rag.activeElapsed += dt

        // ── Joint projection (ALWAYS on, from the very first dynamic frame) ──────────────
        // A spherical pin holds its two anchors coincident, but the solver enforces that with
        // velocity impulses; when overwhelmed for even one step it stretches and from then on
        // becomes an energy source. Enforce the constraint POSITIONALLY: if a bone has drifted
        // beyond its build-time anchor length (+30% slack for cone swing), snap it back onto the
        // anchor sphere around its parent and zero its velocity.
        for bone in rag.bones {
            guard let parent = bone.parentProxyEntity,
                  let built = rag.builtAnchorLengths[bone.suffix], built > 1e-4 else { continue }
            let pPos = parent.position(relativeTo: nil)
            let cPos = bone.proxyEntity.position(relativeTo: nil)
            let offset = cPos - pPos
            let d = simd_length(offset)
            if d > built * 1.3 {
                let dir = d > 1e-5 ? offset / d : SIMD3<Float>(0, -1, 0)
                bone.proxyEntity.setPosition(pPos + dir * built, relativeTo: nil)
                var motion = bone.proxyEntity.components[PhysicsMotionComponent.self] ?? PhysicsMotionComponent()
                motion.linearVelocity = .zero
                motion.angularVelocity = .zero
                bone.proxyEntity.components.set(motion)
            }
        }

        let maxLin = t.maxLinearSpeed
        let maxLinSq = maxLin * maxLin
        let maxAng = t.maxAngularSpeed
        let maxAngSq = maxAng * maxAng
        let settleLinSq = t.settleLinearSpeed * t.settleLinearSpeed
        let settleAngSq = t.settleAngularSpeed * t.settleAngularSpeed

        var allSlow = true
        for bone in rag.bones {
            guard var motion = bone.proxyEntity.components[PhysicsMotionComponent.self] else { continue }
            var dirty = false

            let linSq = simd_length_squared(motion.linearVelocity)
            if linSq > maxLinSq {
                motion.linearVelocity *= (maxLin / linSq.squareRoot())
                dirty = true
            }
            let angSq = simd_length_squared(motion.angularVelocity)
            if angSq > maxAngSq {
                motion.angularVelocity *= (maxAng / angSq.squareRoot())
                dirty = true
            }

            let curLinSq = min(linSq, maxLinSq)
            let curAngSq = min(angSq, maxAngSq)
            if curLinSq > settleLinSq || curAngSq > settleAngSq { allSlow = false }

            if dirty { bone.proxyEntity.components.set(motion) }
        }

        if allSlow {
            rag.slowElapsed += dt
            if rag.slowElapsed >= t.settleTime {
                freeze(rag: rag)
                rag.settled = true
            }
        } else {
            rag.slowElapsed = 0
        }
        return true
    }

    /// Freeze every proxy: zero velocities and switch back to kinematic so the physics
    /// solver stops touching them. The mesh stays pinned to the (now static) proxies.
    private func freeze(rag: HybridRagdollComponent) {
        for bone in rag.bones {
            var motion = bone.proxyEntity.components[PhysicsMotionComponent.self] ?? PhysicsMotionComponent()
            motion.linearVelocity = .zero
            motion.angularVelocity = .zero
            bone.proxyEntity.components.set(motion)
            if var phys = bone.proxyEntity.components[PhysicsBodyComponent.self] {
                phys.mode = .kinematic
                bone.proxyEntity.components.set(phys)
            }
        }
    }

    private func syncProxiesToSkeleton(rag: inout HybridRagdollComponent, container: Entity) {
        let model = rag.model
        let rootWorldPos = rag.rootProxyEntity.position(relativeTo: nil)
        container.setPosition(rootWorldPos - rag.rootJointOffset, relativeTo: nil)

        if rag.cachedJointTransforms == nil {
            rag.cachedJointTransforms = JointTransformBuffer(model.jointTransforms)
        }
        guard !rag.cachedJointTransforms!.transforms.isEmpty else { return }

        for bone in rag.bones {
            let childWorldOri  = bone.proxyEntity.orientation(relativeTo: nil)
            let parentWorldOri = bone.parentProxyEntity?.orientation(relativeTo: nil)
                                 ?? model.orientation(relativeTo: nil)
            rag.cachedJointTransforms!.transforms[bone.jointIndex].rotation = parentWorldOri.inverse * childWorldOri
        }
        model.jointTransforms = rag.cachedJointTransforms!.transforms
    }
}

// MARK: - Rig Builder

@MainActor
public enum HybridRagdollRigBuilder {

    struct BoneDef {
        let suffix: String
        let parentSuffix: String?
        let shape: ShapeResource
        let mesh: MeshResource
        let mass: Float
    }

    // Cooking a ShapeResource is expensive and fully deterministic for a given asset at a given
    // render height + torso inflation, so cook each bone's finished offset shape ONCE per
    // (asset, scale, inflation, suffix) and reuse it across every activation of that model type.
    private struct ShapeCacheKey: Hashable {
        let asset: String
        let prescale: Float
        let bodyInflation: Float
        let bodyHeightInflation: Float
        let suffix: String
    }
    nonisolated(unsafe) private static var shapeCache: [ShapeCacheKey: ShapeResource] = [:]

    private struct PrewarmKey: Hashable { let asset: String; let prescale: Float }
    nonisolated(unsafe) private static var prewarmedRigs: Set<PrewarmKey> = []

    // Sizes in world-space metres for a small (~12 cm) authored model.
    static let boneDefs: [BoneDef] = [
        .init(suffix: "hips",       parentSuffix: nil,
              shape: .generateBox(width: 0.022, height: 0.014, depth: 0.014),
              mesh:  .generateBox(size: [0.022, 0.014, 0.014], cornerRadius: 0.002), mass: 12),
        .init(suffix: "spine",      parentSuffix: "hips",
              shape: .generateCapsule(height: 0.0067, radius: 0.003),
              mesh:  .generateCylinder(height: 0.0067, radius: 0.003), mass: 10),
        .init(suffix: "head",       parentSuffix: "spine",
              shape: .generateSphere(radius: 0.0432),
              mesh:  .generateSphere(radius: 0.0432), mass: 4),
        .init(suffix: "leftarm",    parentSuffix: "spine",
              shape: .generateCapsule(height: 0.018, radius: 0.004),
              mesh:  .generateCylinder(height: 0.018, radius: 0.004), mass: 3),
        .init(suffix: "rightarm",   parentSuffix: "spine",
              shape: .generateCapsule(height: 0.018, radius: 0.004),
              mesh:  .generateCylinder(height: 0.018, radius: 0.004), mass: 3),
        .init(suffix: "leftupleg",  parentSuffix: "hips",
              shape: .generateCapsule(height: 0.022, radius: 0.006),
              mesh:  .generateCylinder(height: 0.022, radius: 0.006), mass: 6),
        .init(suffix: "rightupleg", parentSuffix: "hips",
              shape: .generateCapsule(height: 0.022, radius: 0.006),
              mesh:  .generateCylinder(height: 0.022, radius: 0.006), mass: 6),
        .init(suffix: "leftleg",    parentSuffix: "leftupleg",
              shape: .generateCapsule(height: 0.022, radius: 0.005),
              mesh:  .generateCylinder(height: 0.022, radius: 0.005), mass: 4),
        .init(suffix: "rightleg",   parentSuffix: "rightupleg",
              shape: .generateCapsule(height: 0.022, radius: 0.005),
              mesh:  .generateCylinder(height: 0.022, radius: 0.005), mass: 4),
    ]

    public static let debugMaterial: UnlitMaterial = {
        UnlitMaterial(color: .init(red: 0, green: 0.9, blue: 1, alpha: 0.45))
    }()

    public static let debugVisualName = "RagProxyDebugViz"

    nonisolated(unsafe) static var logPivotOnce = true

    // MARK: - Live Tuning Knobs

    public struct Tuning {
        // "Natural" preset — confirmed stable on visionOS 26.4. The old dialed-in defaults
        // (massScale 273, restitution 0.6, damping 12/20) were tuned on an earlier SDK; on 26.4
        // the spherical-joint solver can't satisfy the joint pins when each tiny limb collider is
        // scaled to that much mass, so the body scattered/flailed. Lower mass + no bounce = stable.
        public var linearDamping: Float  = 0.50
        public var angularDamping: Float = 1.00
        public var massScale: Float      = 1.00
        public var restitution: Float    = 0.00
        public var jointFriction: Float  = 0.30

        // MARK: - Joint angular limits (baked at BUILD time — change then rebuild to apply)
        public var limitJoints: Bool = true
        public enum ConeAxis: String, CaseIterable, Codable, Sendable {
            case x, y, z
            /// Orientation applied to BOTH pins so the cone's X axis aligns to this local axis.
            public var pinOrientation: simd_quatf {
                switch self {
                case .x: return simd_quatf(angle: 0,        axis: [0, 1, 0])
                case .y: return simd_quatf(angle:  .pi / 2, axis: [0, 0, 1])
                case .z: return simd_quatf(angle: -.pi / 2, axis: [0, 1, 0])
                }
            }
        }
        public var jointConeAxes: [String: ConeAxis] = [
            "spine":     .x, "head":       .x,
            "leftarm":   .x, "rightarm":   .x,
            "leftupleg": .x, "rightupleg": .x,
            "leftleg":   .x, "rightleg":   .x,
        ]
        public var jointConeY: [String: Float] = [
            "spine":      20, "head":       20,
            "leftarm":    70, "rightarm":   70,
            "leftupleg":  60, "rightupleg": 60,
            "leftleg":    65, "rightleg":   65,
        ]
        public var jointConeZ: [String: Float] = [
            "spine":      20, "head":       20,
            "leftarm":    70, "rightarm":   70,
            "leftupleg":  45, "rightupleg": 45,
            "leftleg":    12, "rightleg":   12,
        ]
        public var jointConeLimit: Float = 45.0
        public func coneAxis(for suffix: String) -> ConeAxis { jointConeAxes[suffix] ?? .x }
        public func coneY(for suffix: String) -> Float { jointConeY[suffix] ?? jointConeLimit }
        public func coneZ(for suffix: String) -> Float { jointConeZ[suffix] ?? jointConeLimit }
        public var tumbleImpulse: SIMD3<Float> = .init(0.05, 0.0, -0.05)
        public var impulseScale: Float   = 0.0

        // MARK: - Anti-jitter / settling
        public var maxLinearSpeed: Float  = 2.51
        public var maxAngularSpeed: Float = 26.61
        public var settleLinearSpeed: Float  = 0.06
        public var settleAngularSpeed: Float = 0.5
        public var settleTime: TimeInterval = 2.45
        public var settleGrace: TimeInterval = 0.15

        public init() {}
    }
    nonisolated(unsafe) public static var tuning = Tuning()

    // MARK: - Build

    public static func build(
        model: ModelEntity,
        simulationRoot: Entity,
        collisionGroup: CollisionGroup,
        collisionMask: CollisionGroup,
        prescaleToRenderHeight: Float? = nil,
        bodyInflation: Float = 1.0,
        bodyHeightInflation: Float = 1.0,
        includeDebugViz: Bool = true,
        prewarmOnly: Bool = false
    ) -> HybridRagdollComponent? {

        guard let skinnedModel = findSkinnedModel(in: model) else {
            return nil
        }

        let names      = skinnedModel.jointNames
        let transforms = skinnedModel.jointTransforms
        guard !names.isEmpty, names.count == transforms.count else { return nil }

        var indexBySuffix: [String: Int] = [:]
        for (i, name) in names.enumerated() { indexBySuffix[canonicalSuffix(name)] = i }

        let rawModelWorld = skinnedModel.transformMatrix(relativeTo: nil)
        let msByName = jointModelSpaceMatrices(for: skinnedModel)
        var proxyBySuffix: [String: Entity] = [:]

        // PRESCALE BAKED INTO modelWorld (not into proxy.scale). A NON-UNIT scale on a DYNAMIC
        // PhysicsBody breaks the spherical-joint solver: cones stop constraining and limbs fling.
        // Baking it here keeps proxy.scale = 1 — exactly like the working debug rig.
        let modelWorld: float4x4 = {
            guard let targetH = prescaleToRenderHeight else { return rawModelWorld }
            var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
            for def in boneDefs {
                guard let ji = indexBySuffix[def.suffix], let ms = msByName[names[ji]] else { continue }
                let y = (rawModelWorld * ms).columns.3.y
                lo = min(lo, y); hi = max(hi, y)
            }
            let span = hi - lo
            guard span > 1e-4 else { return rawModelWorld }
            let s = targetH / span
            let o = SIMD3<Float>(rawModelWorld.columns.3.x, rawModelWorld.columns.3.y, rawModelWorld.columns.3.z)
            let toOrigin   = Transform(translation: -o).matrix
            let scaleM     = Transform(scale: SIMD3<Float>(repeating: s)).matrix
            let fromOrigin = Transform(translation: o).matrix
            return fromOrigin * scaleM * toOrigin * rawModelWorld
        }()

        func jointWorldPos(_ jointName: String) -> SIMD3<Float>? {
            guard let ms = msByName[jointName] else { return nil }
            let c = (modelWorld * ms).columns.3
            return SIMD3(c.x, c.y, c.z)
        }

        var childrenByName: [String: [String]] = [:]
        if let skel = firstSkeleton(of: skinnedModel) {
            let js = skel.joints
            for i in js.indices {
                if let p = js[i].parentIndex { childrenByName[js[p].name, default: []].append(js[i].name) }
            }
        }
        func farthestDescendant(of jointName: String) -> SIMD3<Float>? {
            guard let origin = jointWorldPos(jointName) else { return nil }
            var bestPos: SIMD3<Float>?; var bestD: Float = 0
            var stack = childrenByName[jointName] ?? []
            while let n = stack.popLast() {
                if let p = jointWorldPos(n) {
                    let d = distance(p, origin)
                    if d > bestD { bestD = d; bestPos = p }
                }
                stack.append(contentsOf: childrenByName[n] ?? [])
            }
            return bestPos
        }

        let t = tuning
        let proxyPhysicsMaterial = PhysicsMaterialResource.generate(
            staticFriction: 0.5, dynamicFriction: t.jointFriction, restitution: t.restitution)

        for def in boneDefs {
            guard let jointIndex = indexBySuffix[def.suffix] else { continue }
            let jointName = names[jointIndex]
            guard let ms = msByName[jointName], let jPos = jointWorldPos(jointName) else { continue }
            let jointWorldT = Transform(matrix: modelWorld * ms)

            let offsetShape: ShapeResource
            var vizMesh: MeshResource? = nil
            var vizPos: SIMD3<Float> = .zero
            var vizOri = simd_quatf(angle: 0, axis: [0, 1, 0])

            let cacheKey = ShapeCacheKey(asset: skinnedModel.name,
                                         prescale: prescaleToRenderHeight ?? 0,
                                         bodyInflation: bodyInflation,
                                         bodyHeightInflation: bodyHeightInflation,
                                         suffix: def.suffix)

            if !includeDebugViz, let cached = Self.shapeCache[cacheKey] {
                offsetShape = cached
            } else {
                var endPos: SIMD3<Float>?
                let childBones = boneDefs.filter { $0.parentSuffix == def.suffix }
                if def.suffix == "spine", let hi = indexBySuffix["head"],
                   let spinePos = jointWorldPos(jointName),
                   let headPos  = jointWorldPos(names[hi]) {
                    endPos = spinePos + (headPos - spinePos) * 0.55
                } else if childBones.count == 1, let ci = indexBySuffix[childBones[0].suffix] {
                    endPos = jointWorldPos(names[ci])
                } else if childBones.isEmpty {
                    endPos = farthestDescendant(of: jointName)
                }

                let shape: ShapeResource

                if def.suffix == "hips" {
                    let lw = indexBySuffix["leftupleg"].flatMap { jointWorldPos(names[$0]) }
                    let rw = indexBySuffix["rightupleg"].flatMap { jointWorldPos(names[$0]) }
                    let hipW = (lw != nil && rw != nil) ? max(distance(lw!, rw!), 0.003) : 0.008
                    let w = hipW * 1.3 * bodyInflation, h = hipW * bodyInflation * bodyHeightInflation, d = hipW * 0.8 * bodyInflation
                    shape = .generateBox(width: w, height: h, depth: d)
                    vizMesh = includeDebugViz ? .generateBox(size: [w, h, d]) : nil
                } else if def.suffix == "head" {
                    let sp = indexBySuffix["spine"].flatMap { jointWorldPos(names[$0]) }
                    let r = max((sp.map { distance($0, jPos) } ?? 0.008) * 0.81, 0.018)
                    shape = .generateSphere(radius: r)
                    vizMesh = includeDebugViz ? .generateSphere(radius: r) : nil
                } else if let ePos = endPos {
                    let boneLen = max(distance(jPos, ePos), 0.005)
                    let radiusFactor: Float = def.suffix.contains("arm") ? 0.12
                                            : (def.suffix == "spine" ? 0.24 * bodyInflation : 0.22)
                    let radius = max(boneLen * radiusFactor, 0.002)
                    let length = def.suffix == "spine" ? boneLen * bodyHeightInflation : boneLen
                    shape = .generateCapsule(height: length, radius: radius)
                    vizMesh = includeDebugViz ? .generateCylinder(height: length, radius: radius) : nil
                    let invOri = jointWorldT.rotation.inverse
                    vizOri = simd_quatf(from: SIMD3(0, 1, 0), to: normalize(invOri.act(ePos - jPos)))
                    vizPos = invOri.act((ePos - jPos) * 0.5)
                } else {
                    shape = .generateSphere(radius: 0.004)
                    vizMesh = includeDebugViz ? .generateSphere(radius: 0.004) : nil
                }

                offsetShape = shape.offsetBy(rotation: vizOri, translation: vizPos)
                if !includeDebugViz { Self.shapeCache[cacheKey] = offsetShape }
            }
            if prewarmOnly { continue }
            let proxy = makeProxy(shape: offsetShape, debugMesh: vizMesh,
                                  vizPosition: vizPos, vizOrientation: vizOri, mass: def.mass,
                                  physicsMaterial: proxyPhysicsMaterial,
                                  collisionGroup: collisionGroup, collisionMask: collisionMask)
            proxy.name = "RagProxy_\(def.suffix)"
            simulationRoot.addChild(proxy)
            proxy.setPosition(jointWorldT.translation, relativeTo: nil)
            proxy.setOrientation(jointWorldT.rotation, relativeTo: nil)

            proxyBySuffix[def.suffix] = proxy
        }

        if prewarmOnly { return nil }

        guard let hipsProxy = proxyBySuffix["hips"] else { return nil }

        var boneLinks: [HybridRagdollComponent.BoneLink] = []
        var jointsAdded = 0
        var jointsFailed = 0
        var builtAnchorLengths: [String: Float] = [:]
        for def in boneDefs {
            guard let jointIndex = indexBySuffix[def.suffix],
                  let proxy = proxyBySuffix[def.suffix] else { continue }
            let parentProxy = def.parentSuffix.flatMap { proxyBySuffix[$0] }

            if let parent = parentProxy {
                let anchorInParent = proxy.position(relativeTo: parent)
                builtAnchorLengths[def.suffix] = simd_length(anchorInParent)
                let pinOri = tuning.coneAxis(for: def.suffix).pinOrientation
                let pin0 = parent.pins.set(named: "rag_\(def.suffix)_p",
                                           position: anchorInParent, orientation: pinOri)
                let pin1 = proxy.pins.set(named: "rag_\(def.suffix)_c",
                                          position: .zero, orientation: pinOri)

                let coneLimit: (Float, Float)? = tuning.limitJoints
                    ? (tuning.coneY(for: def.suffix) * .pi / 180,
                       tuning.coneZ(for: def.suffix) * .pi / 180)
                    : nil
                let joint = PhysicsSphericalJoint(pin0: pin0, pin1: pin1,
                                                  angularLimitInYZ: coneLimit,
                                                  checksForInternalCollisions: false)
                do { try joint.addToSimulation(); jointsAdded += 1 }
                catch {
                    jointsFailed += 1
                    ragdollLog("🦴❌ RAGDOLL JOINT FAILED '\(def.suffix)': \(error)")
                }
            }

            boneLinks.append(.init(
                jointIndex: jointIndex,
                jointName: names[jointIndex],
                suffix: def.suffix,
                proxyEntity: proxy,
                parentJointIndex: def.parentSuffix.flatMap { indexBySuffix[$0] },
                parentProxyEntity: parentProxy
            ))
        }

        ragdollLog("🦴 RAGDOLL JOINTS: \(jointsAdded) added, \(jointsFailed) FAILED, limitJoints=\(tuning.limitJoints)")

        var component = HybridRagdollComponent(
            model: skinnedModel,
            bones: boneLinks,
            rootProxyEntity: hipsProxy
        )
        component.jointsAdded = jointsAdded
        component.jointsFailed = jointsFailed
        component.builtAnchorLengths = builtAnchorLengths
        return component
    }

    /// Pre-cook + cache the collision shapes for one model type, so the FIRST activation of that
    /// type doesn't pay the shape-generation cost on the hot frame. `prescaleToRenderHeight` MUST
    /// match the value the activation path uses for this type. Builds NO proxies/joints.
    @discardableResult
    public static func prewarmShapeCache(
        model: ModelEntity,
        prescaleToRenderHeight: Float,
        collisionGroup: CollisionGroup = RagdollCollision.ragdoll,
        collisionMask: CollisionGroup = RagdollCollision.defaultMask
    ) -> Bool {
        guard let skinned = findSkinnedModel(in: model) else { return false }
        let key = PrewarmKey(asset: skinned.name, prescale: prescaleToRenderHeight)
        guard !prewarmedRigs.contains(key) else { return false }
        prewarmedRigs.insert(key)
        _ = build(model: model,
                  simulationRoot: Entity(),
                  collisionGroup: collisionGroup,
                  collisionMask: collisionMask,
                  prescaleToRenderHeight: prescaleToRenderHeight,
                  includeDebugViz: false,
                  prewarmOnly: true)
        return true
    }

    // MARK: - Activate

    public static func activate(component: inout HybridRagdollComponent, container: Entity,
                                impulse: SIMD3<Float> = .zero, diagLabel: String = "?") {
        component.cachedJointTransforms = nil
        component.activeElapsed = 0
        component.slowElapsed = 0
        component.settled = false

        component.rootJointOffset = component.rootProxyEntity.position(relativeTo: nil)
                                  - container.position(relativeTo: nil)

        for bone in component.bones {
            var motion = PhysicsMotionComponent()
            motion.linearVelocity = .zero
            motion.angularVelocity = .zero
            bone.proxyEntity.components.set(motion)

            if var phys = bone.proxyEntity.components[PhysicsBodyComponent.self] {
                phys.mode = .dynamic
                bone.proxyEntity.components.set(phys)
            }
        }

        if impulse != .zero {
            var motion = component.rootProxyEntity.components[PhysicsMotionComponent.self] ?? PhysicsMotionComponent()
            motion.linearVelocity = impulse
            component.rootProxyEntity.components.set(motion)
        }
        component.isActive = true
    }

    // MARK: - Debug visibility

    public static func setProxiesVisible(_ visible: Bool, component: HybridRagdollComponent) {
        for bone in component.bones {
            bone.proxyEntity.findEntity(named: debugVisualName)?.isEnabled = visible
        }
    }

    // MARK: - Private skeleton plumbing

    @MainActor
    private final class SkeletonScratch {
        let names: [String]
        let parents: [Int?]
        let order: [Int]
        let restLocals: [float4x4]
        let indexByName: [String: Int]
        let suffixes: [String]
        var modelSpace: [float4x4]

        init?(model: ModelEntity) {
            let names: [String]
            let rawParents: [Int?]
            let restLocals: [float4x4]
            if let skeleton = firstSkeleton(of: model) {
                let joints = skeleton.joints
                names      = joints.map { $0.name }
                rawParents = joints.map { $0.parentIndex }
                restLocals = joints.map { float4x4($0.restPoseTransform) }
            } else {
                let jointNames = model.jointNames
                guard !jointNames.isEmpty else { return nil }
                var indexByPath: [String: Int] = [:]
                for (i, n) in jointNames.enumerated() { indexByPath[n] = i }
                names      = jointNames
                rawParents = jointNames.map { name in
                    guard let slash = name.range(of: "/", options: .backwards) else { return nil }
                    return indexByPath[String(name[..<slash.lowerBound])]
                }
                let transforms = model.jointTransforms
                restLocals = names.indices.map {
                    $0 < transforms.count ? float4x4(transforms[$0]) : matrix_identity_float4x4
                }
            }
            guard !names.isEmpty else { return nil }

            let n = names.count
            var safeParents: [Int?] = []
            safeParents.reserveCapacity(n)
            for i in 0..<n {
                if let p = rawParents[i], p >= 0, p < n, p != i { safeParents.append(p) }
                else { safeParents.append(nil) }
            }
            self.names      = names
            self.parents    = safeParents
            self.restLocals = restLocals
            var order: [Int] = []
            order.reserveCapacity(n)
            var visited = [Bool](repeating: false, count: n)
            for i in 0..<n where !visited[i] {
                var stack = [i]
                while let p = safeParents[stack[stack.count - 1]], !visited[p], stack.count <= n {
                    stack.append(p)
                }
                while let j = stack.popLast() {
                    if !visited[j] { visited[j] = true; order.append(j) }
                }
            }
            self.order = order

            var indexByName: [String: Int] = [:]
            indexByName.reserveCapacity(n)
            for (i, name) in names.enumerated() { indexByName[name] = i }
            self.indexByName = indexByName
            self.suffixes    = names.map { canonicalSuffix($0) }
            self.modelSpace  = [float4x4](repeating: matrix_identity_float4x4, count: n)
        }

        func refresh(from model: ModelEntity) {
            let current = model.jointTransforms
            for i in order {
                let local = i < current.count ? float4x4(current[i]) : restLocals[i]
                if let p = parents[i], p >= 0, p < modelSpace.count, p != i {
                    modelSpace[i] = modelSpace[p] * local
                } else {
                    modelSpace[i] = local
                }
            }
        }
    }

    private static let scratchCache = NSMapTable<ModelEntity, SkeletonScratch>(
        keyOptions: .weakMemory, valueOptions: .strongMemory)

    private static func jointModelSpaceScratch(for model: ModelEntity) -> SkeletonScratch? {
        let scratch: SkeletonScratch
        if let cached = scratchCache.object(forKey: model) {
            scratch = cached
        } else {
            guard let built = SkeletonScratch(model: model) else { return nil }
            scratchCache.setObject(built, forKey: model)
            scratch = built
        }
        scratch.refresh(from: model)
        return scratch
    }

    private static func jointModelSpaceMatrices(for model: ModelEntity) -> [String: float4x4] {
        guard let s = jointModelSpaceScratch(for: model) else { return [:] }
        var out: [String: float4x4] = [:]
        out.reserveCapacity(s.names.count)
        for i in s.names.indices { out[s.names[i]] = s.modelSpace[i] }
        return out
    }

    /// Exposes the skinned mesh's skeleton joints (name + parent index) so procedural joint
    /// overrides — e.g. a head look-at — can accumulate model-space matrices the same way the
    /// ragdoll does. Returns `nil` when the model carries no skeleton.
    public static func skeletonJointHierarchy(of model: ModelEntity) -> [(name: String, parentIndex: Int?)]? {
        guard let skeleton = firstSkeleton(of: model) else { return nil }
        return skeleton.joints.map { ($0.name, $0.parentIndex) }
    }

    private static func firstSkeleton(of model: ModelEntity) -> MeshResource.Skeleton? {
        guard let contents = model.model?.mesh.contents else { return nil }
        for skeleton in contents.skeletons where !skeleton.joints.isEmpty { return skeleton }
        return nil
    }

    private static func findSkinnedModel(in entity: Entity) -> ModelEntity? {
        if let m = entity as? ModelEntity, !m.jointNames.isEmpty { return m }
        for child in entity.children { if let m = findSkinnedModel(in: child) { return m } }
        return nil
    }

    /// World-space position of every skeleton joint, keyed by canonical suffix.
    public static func jointWorldPositionsBySuffix(in root: Entity) -> (model: ModelEntity, positions: [String: SIMD3<Float>])? {
        guard let skinned = findSkinnedModel(in: root),
              let out = jointWorldPositionsBySuffix(model: skinned) else { return nil }
        return (skinned, out)
    }

    public static func jointWorldPositionsBySuffix(model skinned: ModelEntity) -> [String: SIMD3<Float>]? {
        guard let s = jointModelSpaceScratch(for: skinned) else { return nil }
        let modelWorld = skinned.transformMatrix(relativeTo: nil)
        var out: [String: SIMD3<Float>] = [:]
        out.reserveCapacity(s.suffixes.count)
        for i in s.suffixes.indices {
            let c = (modelWorld * s.modelSpace[i]).columns.3
            out[s.suffixes[i]] = SIMD3(c.x, c.y, c.z)
        }
        return out
    }

    public static func jointModelLocalPositionsBySuffix(model skinned: ModelEntity) -> [String: SIMD3<Float>]? {
        guard let s = jointModelSpaceScratch(for: skinned) else { return nil }
        var out: [String: SIMD3<Float>] = [:]
        out.reserveCapacity(s.suffixes.count)
        for i in s.suffixes.indices {
            let c = s.modelSpace[i].columns.3
            out[s.suffixes[i]] = SIMD3(c.x, c.y, c.z)
        }
        return out
    }

    /// Deep-finds the skinned mesh under `root` (the entity actually carrying joints).
    public static func skinnedModel(under root: Entity) -> ModelEntity? {
        findSkinnedModel(in: root)
    }

    /// Drives each proxy to its joint's CURRENT world transform — applied every frame so a
    /// kinematic (non-activated) rig rides the live animation exactly. Position + rotation only.
    public static func driveProxiesToSkeleton(_ rag: HybridRagdollComponent, scale: Float = 1, verticalSquash: Float = 1, headDropMeters: Float = 0, armDropMeters: Float = 0) {
        let model = rag.model
        guard let scratch = jointModelSpaceScratch(for: model) else { return }
        let modelWorld = model.transformMatrix(relativeTo: nil)

        var worldT: [(bone: HybridRagdollComponent.BoneLink, t: Transform)] = []
        worldT.reserveCapacity(rag.bones.count)
        var minY = Float.greatestFiniteMagnitude
        for bone in rag.bones {
            guard let ji = scratch.indexByName[bone.jointName] else { continue }
            let t = Transform(matrix: modelWorld * scratch.modelSpace[ji])
            minY = min(minY, t.translation.y)
            worldT.append((bone, t))
        }
        let anchor = SIMD3<Float>(modelWorld.columns.3.x, modelWorld.columns.3.y, modelWorld.columns.3.z)
        _ = minY

        for (bone, t) in worldT {
            var pos = t.translation
            if scale != 1 {
                pos = anchor + (t.translation - anchor) * scale
            }
            if headDropMeters != 0, bone.suffix == "head" {
                pos.y -= headDropMeters
            }
            if armDropMeters != 0, bone.suffix == "leftarm" || bone.suffix == "rightarm" { pos.y -= armDropMeters }
            bone.proxyEntity.setPosition(pos, relativeTo: nil)
            bone.proxyEntity.setOrientation(t.rotation, relativeTo: nil)
            if scale != 1 {
                bone.proxyEntity.scale = SIMD3<Float>(repeating: scale)
            }
        }
    }

    /// Vertical extent (max−min Y) of the rig's proxies in world space, as currently positioned.
    public static func rigWorldHeight(_ rag: HybridRagdollComponent) -> Float {
        let ys = rag.bones.map { $0.proxyEntity.position(relativeTo: nil).y }
        guard let lo = ys.min(), let hi = ys.max() else { return 0 }
        return hi - lo
    }

    /// Maps a bone suffix to the coarse body part used for damage / headshots.
    public static func bodyPart(forSuffix suffix: String) -> RagdollBodyPart {
        switch suffix {
        case "head":                       return .head
        case "hips", "spine":              return .torso
        case "leftarm":                    return .leftArm
        case "rightarm":                   return .rightArm
        case "leftupleg", "leftleg",
             "rightupleg", "rightleg":     return .legs
        default:                           return .torso
        }
    }

    public static func canonicalSuffix(_ name: String) -> String {
        var s = name
        if let r = s.range(of: "/", options: .backwards) { s = String(s[r.upperBound...]) }
        if let r = s.range(of: ":", options: .backwards) { s = String(s[r.upperBound...]) }
        return s.lowercased().replacingOccurrences(of: " ", with: "")
    }

    private static func makeProxy(
        shape: ShapeResource,
        debugMesh: MeshResource?,
        vizPosition: SIMD3<Float>,
        vizOrientation: simd_quatf,
        mass: Float,
        physicsMaterial: PhysicsMaterialResource,
        collisionGroup: CollisionGroup,
        collisionMask: CollisionGroup
    ) -> Entity {
        let entity = Entity()
        let t = Self.tuning
        var body = PhysicsBodyComponent(
            massProperties: .init(mass: mass * t.massScale),
            material: physicsMaterial,
            mode: .kinematic
        )
        body.linearDamping = t.linearDamping
        body.angularDamping = t.angularDamping
        entity.components.set(body)
        entity.components.set(PhysicsMotionComponent())
        var col = CollisionComponent(shapes: [shape])
        col.filter = CollisionFilter(group: collisionGroup, mask: collisionMask)
        entity.components.set(col)

        if let debugMesh {
            let viz = ModelEntity(mesh: debugMesh, materials: [debugMaterial])
            viz.name = debugVisualName
            viz.position = vizPosition
            viz.orientation = vizOrientation
            viz.isEnabled = false
            entity.addChild(viz)
        }
        return entity
    }
} // end HybridRagdollRigBuilder
