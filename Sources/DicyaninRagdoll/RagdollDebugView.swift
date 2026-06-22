//
//  RagdollDebugView.swift
//  DicyaninRagdoll
//
//  Self-contained interactive tuning lab for the hybrid ragdoll. Loads a bundled skinned
//  character, builds a kinematic proxy rig that rides its idle animation, and lets you DROP it
//  into a physics ragdoll, fire test "gunshots" at individual body parts (driving the live
//  hit-jolt spring), live-tune the rig, and dump the dialed-in values to the console.
//
//  Drop `RagdollDebugView()` into any window / volume to use it. Requires
//  `DicyaninRagdoll.registerComponentsAndSystems()` to have run at launch.
//

import SwiftUI
import RealityKit

// MARK: - Local theme (no external dependency)

enum RagdollDebugTheme {
    /// Monospaced font helper — single-weight, size maps 1:1. Replaces the host app's theme.
    static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Scene holder (reference type keeps entities alive across SwiftUI updates)

@MainActor
private final class RagdollDebugScene: ObservableObject {
    var root        = Entity()
    var container: Entity?          // character container — HybridRagdollComponent lives here
    var model: ModelEntity?         // skinned mesh
    var sphere:     ModelEntity?
    var floor:      ModelEntity?

    @Published var ragdollActive   = false
    @Published var showDebugPhysics = false
    @Published var status = "Press DROP to ragdoll · LAUNCH to smash sphere"

    var idleAnimation: AnimationResource?
    weak var animationHost: Entity?
    var shootToken = 0

    @Published var linearDamping: Float  = HybridRagdollRigBuilder.tuning.linearDamping
    @Published var angularDamping: Float = HybridRagdollRigBuilder.tuning.angularDamping
    @Published var massScale: Float      = HybridRagdollRigBuilder.tuning.massScale
    @Published var restitution: Float    = HybridRagdollRigBuilder.tuning.restitution
    @Published var jointFriction: Float  = HybridRagdollRigBuilder.tuning.jointFriction
    typealias ConeAxis = HybridRagdollRigBuilder.Tuning.ConeAxis

    static let boneRegions: [(name: String, suffixes: [String])] = [
        ("Spine",      ["spine"]),
        ("Head/Neck",  ["head"]),
        ("Arms",       ["leftarm", "rightarm"]),
        ("Upper Legs", ["leftupleg", "rightupleg"]),
        ("Lower Legs", ["leftleg", "rightleg"]),
    ]

    typealias JoltRegion = RagdollBodyPartHideComponent.JoltRegion
    static let bodyParts: [(name: String, region: JoltRegion)] = [
        ("Head",      .head),
        ("Torso",     .torso),
        ("Left Arm",  .leftArm),
        ("Right Arm", .rightArm),
        ("Left Leg",  .leftLeg),
        ("Right Leg", .rightLeg),
        ("Both Legs", .bothLegs),
    ]
    @Published var selectedBodyPart: JoltRegion = .torso
    @Published var joltDegrees: Float = 40

    @Published var limitJoints: Bool = HybridRagdollRigBuilder.tuning.limitJoints
    @Published var selectedRegion: String = "Arms" { didSet { loadSelectedRegion() } }
    @Published var selectedAxis: ConeAxis = .x
    @Published var coneY: Float = 70
    @Published var coneZ: Float = 70

    func loadSelectedRegion() {
        let suffix = Self.boneRegions.first { $0.name == selectedRegion }?.suffixes.first ?? "leftarm"
        let t = HybridRagdollRigBuilder.tuning
        selectedAxis = t.coneAxis(for: suffix)
        coneY = t.coneY(for: suffix)
        coneZ = t.coneZ(for: suffix)
    }
    @Published var impulseScale: Float   = HybridRagdollRigBuilder.tuning.impulseScale
    @Published var maxLinearSpeed: Float  = HybridRagdollRigBuilder.tuning.maxLinearSpeed
    @Published var maxAngularSpeed: Float = HybridRagdollRigBuilder.tuning.maxAngularSpeed
    @Published var settleTime: Float      = Float(HybridRagdollRigBuilder.tuning.settleTime)
    @Published var needsRebuild = false

    struct Preset {
        let name: String
        let linearDamping: Float
        let angularDamping: Float
        let massScale: Float
        let restitution: Float
        let jointFriction: Float
        let impulseScale: Float
    }

    static let presets: [Preset] = [
        .init(name: "Floppy",  linearDamping: 0.5, angularDamping: 1.0, massScale: 1.0,
              restitution: 0.0, jointFriction: 0.3, impulseScale: 0.0),
        .init(name: "Natural", linearDamping: 1.5, angularDamping: 3.0, massScale: 20.0,
              restitution: 0.0, jointFriction: 0.5, impulseScale: 0.0),
        .init(name: "Stiff",   linearDamping: 3.5, angularDamping: 7.0, massScale: 40.0,
              restitution: 0.0, jointFriction: 0.7, impulseScale: 0.0),
        .init(name: "Heavy",   linearDamping: 4.0, angularDamping: 8.0, massScale: 120.0,
              restitution: 0.0, jointFriction: 0.8, impulseScale: 0.0),
        .init(name: "Crazy",   linearDamping: 0.3, angularDamping: 0.5, massScale: 0.6,
              restitution: 0.4, jointFriction: 0.2, impulseScale: 2.0),
    ]

    func loadPreset(_ p: Preset) {
        linearDamping  = p.linearDamping
        angularDamping = p.angularDamping
        massScale      = p.massScale
        restitution    = p.restitution
        jointFriction  = p.jointFriction
        impulseScale   = p.impulseScale
        applyTuning()
        needsRebuild = true
        status = "Loaded '\(p.name)' preset · RESET to rebuild, then DROP"
    }

    func applyTuning() {
        var t = HybridRagdollRigBuilder.tuning
        t.linearDamping  = linearDamping
        t.angularDamping = angularDamping
        t.massScale      = massScale
        t.restitution    = restitution
        t.jointFriction  = jointFriction
        t.limitJoints    = limitJoints
        if let region = Self.boneRegions.first(where: { $0.name == selectedRegion }) {
            for suffix in region.suffixes {
                t.jointConeAxes[suffix] = selectedAxis
                t.jointConeY[suffix]    = coneY
                t.jointConeZ[suffix]    = coneZ
            }
        }
        t.impulseScale   = impulseScale
        t.maxLinearSpeed   = maxLinearSpeed
        t.maxAngularSpeed  = maxAngularSpeed
        t.settleTime       = TimeInterval(settleTime)
        HybridRagdollRigBuilder.tuning = t
    }

    // Collision groups local to this debug scene (bits 8–10, clear of the package defaults at 24+).
    static let floorGroup   = CollisionGroup(rawValue: 1 << 8)
    static let boneGroup    = CollisionGroup(rawValue: 1 << 9)
    static let sphereGroup  = CollisionGroup(rawValue: 1 << 10)

    static let characterScale: Float = 0.18
    static let floorY: Float      = -0.30
    static let floorSize: Float   = 3.0
}

// MARK: - View

public struct RagdollDebugView: View {
    @StateObject private var scene = RagdollDebugScene()

    public init() {}

    public var body: some View {
        ZStack(alignment: .bottom) {
            RealityView { content in
                await buildScene(content: content)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 12) {
                ScrollView {
                    VStack(spacing: 12) {
                        gunshotPanel
                        tuningPanel
                        jointAnglePanel
                    }
                }
                .frame(maxHeight: 360)
                controlPanel
            }
            .padding(20)
        }
        .background(.black.opacity(0.85))
    }

    // MARK: - Gunshot Panel (per-body-part hit)

    private var gunshotPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GUNSHOT HIT")
                .font(RagdollDebugTheme.font(12, weight: .bold))
                .foregroundStyle(.cyan)
            Text("Pick a body part and fire a shot at it — drives the same RagdollBodyPartHideComponent spring jolt a non-lethal hit applies.")
                .font(RagdollDebugTheme.font(9))
                .foregroundStyle(.white.opacity(0.5))

            HStack(spacing: 10) {
                Text("Body Part")
                    .font(RagdollDebugTheme.font(11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 110, alignment: .leading)
                Picker("Body Part", selection: $scene.selectedBodyPart) {
                    ForEach(RagdollDebugScene.bodyParts, id: \.region) { entry in
                        Text(entry.name).tag(entry.region)
                    }
                }
                .pickerStyle(.menu)
                .tint(.cyan)
                Spacer()
                Button { shootSelectedBodyPart() } label: {
                    Label("SHOOT", systemImage: "scope")
                        .font(RagdollDebugTheme.font(13, weight: .bold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent).tint(.red)
            }

            HStack(spacing: 10) {
                Text("Jolt Angle")
                    .font(RagdollDebugTheme.font(11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 110, alignment: .leading)
                Slider(value: $scene.joltDegrees, in: 0...160)
                    .tint(.red)
                Text(String(format: "%.1f°", scene.joltDegrees))
                    .font(RagdollDebugTheme.font(11).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 44, alignment: .trailing)
            }
        }
        .padding(14)
        .frame(maxWidth: 460)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func shootSelectedBodyPart() {
        guard let container = scene.container else {
            scene.status = "No model — RESET first"
            return
        }
        let region = scene.selectedBodyPart
        let label = RagdollDebugScene.bodyParts.first { $0.region == region }?.name ?? "?"

        // Stopping the idle releases RealityKit's skeleton ownership so the spring jolt is visible.
        if !scene.ragdollActive {
            scene.animationHost?.stopAllAnimations(recursive: true)
        }

        var targets: [ModelEntity] = []
        func collect(_ e: Entity) {
            if let m = e as? ModelEntity, m.isEnabled, !m.jointNames.isEmpty { targets.append(m) }
            for c in e.children where c.isEnabled { collect(c) }
        }
        collect(container)

        guard !targets.isEmpty else {
            scene.status = "⚠ No jointed mesh found to jolt"
            return
        }

        for model in targets {
            let localDir = model.convert(direction: SIMD3<Float>(0, 0, -1), from: nil)
            let existing = model.components[RagdollBodyPartHideComponent.self]
            var comp = existing ?? RagdollBodyPartHideComponent(region: region, bulletModelDir: localDir)
            let before = existing == nil ? 0 : comp.hits.count
            if existing != nil { comp.add(region: region, bulletModelDir: localDir) }
            let omega = RagdollBodyPartHideComponent.naturalFreq
            let peakRad = scene.joltDegrees * .pi / 180
            for i in before..<comp.hits.count {
                let weight = comp.hits[i].angVel / RagdollBodyPartHideComponent.baseSpeed
                comp.hits[i].angVel = peakRad * omega * weight
            }
            model.components.set(comp)
        }

        scene.status = "💥 Gunshot → \(label) · jolted \(targets.count) mesh(es)"

        scene.shootToken += 1
        let token = scene.shootToken
        if !scene.ragdollActive, let host = scene.animationHost, let idle = scene.idleAnimation {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                guard token == scene.shootToken, !scene.ragdollActive, host.parent != nil else { return }
                host.playAnimation(idle.repeat(), transitionDuration: 0.1, startsPaused: false)
            }
        }
    }

    // MARK: - Tuning Panel

    private func tuningRow(_ label: String, _ value: Binding<Float>,
                           range: ClosedRange<Float>, baked: Bool) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(RagdollDebugTheme.font(11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 110, alignment: .leading)
            Slider(value: value, in: range) { editing in
                if !editing { scene.applyTuning() }
            }
            .tint(baked ? .orange : .cyan)
            Text(String(format: "%.2f", value.wrappedValue))
                .font(RagdollDebugTheme.font(11).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 44, alignment: .trailing)
        }
        .onChange(of: value.wrappedValue) { _, _ in
            scene.applyTuning()
            if baked { scene.needsRebuild = true }
        }
    }

    private var tuningPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("RAGDOLL TUNING")
                    .font(RagdollDebugTheme.font(12, weight: .bold))
                    .foregroundStyle(.cyan)
                Spacer()
                if scene.needsRebuild {
                    Label("RESET to apply", systemImage: "exclamationmark.triangle.fill")
                        .font(RagdollDebugTheme.font(10, weight: .semibold))
                        .foregroundStyle(.orange)
                }
            }
            HStack(spacing: 8) {
                ForEach(RagdollDebugScene.presets, id: \.name) { preset in
                    Button { scene.loadPreset(preset) } label: {
                        Text(preset.name)
                            .font(RagdollDebugTheme.font(11, weight: .bold))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).tint(.cyan)
                }
            }
            tuningRow("Lin Damping",  $scene.linearDamping,  range: 0...12,  baked: true)
            tuningRow("Ang Damping",  $scene.angularDamping, range: 0...20,  baked: true)
            tuningRow("Mass ×",       $scene.massScale,      range: 0.2...300, baked: true)
            tuningRow("Restitution",  $scene.restitution,    range: 0...0.6, baked: true)
            tuningRow("Friction",     $scene.jointFriction,  range: 0...1,  baked: true)
            tuningRow("Impulse ×",    $scene.impulseScale,   range: 0...3,  baked: false)
            tuningRow("Max Lin Spd",  $scene.maxLinearSpeed,  range: 0.2...5,  baked: false)
            tuningRow("Max Ang Spd",  $scene.maxAngularSpeed, range: 1...40,   baked: false)
            tuningRow("Settle Time",  $scene.settleTime,      range: 0.1...3,  baked: false)
            Text("Orange = rebuild needed (RESET) · Cyan = live on next DROP")
                .font(RagdollDebugTheme.font(9))
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(14)
        .frame(maxWidth: 460)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Joint Angle Panel (per-bone cone limits)

    private var jointAnglePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("JOINT ANGLES")
                    .font(RagdollDebugTheme.font(12, weight: .bold))
                    .foregroundStyle(.cyan)
                Spacer()
                Toggle("Limit", isOn: $scene.limitJoints)
                    .labelsHidden()
                    .tint(.orange)
                    .onChange(of: scene.limitJoints) { _, _ in
                        scene.applyTuning(); scene.needsRebuild = true
                    }
                Text(scene.limitJoints ? "ON" : "OFF")
                    .font(RagdollDebugTheme.font(10, weight: .bold))
                    .foregroundStyle(scene.limitJoints ? .orange : .white.opacity(0.4))
            }
            Text("Pick a bone, choose its free-twist axis, and set the Y/Z swing cones (°). Lower = stiffer.")
                .font(RagdollDebugTheme.font(9))
                .foregroundStyle(.white.opacity(0.5))

            Group {
                HStack(spacing: 10) {
                    Text("Bone")
                        .font(RagdollDebugTheme.font(11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 110, alignment: .leading)
                    Picker("Bone", selection: $scene.selectedRegion) {
                        ForEach(RagdollDebugScene.boneRegions, id: \.name) { region in
                            Text(region.name).tag(region.name)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.cyan)
                    Spacer()
                }
                HStack(spacing: 10) {
                    Text("Twist Axis")
                        .font(RagdollDebugTheme.font(11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 110, alignment: .leading)
                    Picker("Axis", selection: $scene.selectedAxis) {
                        Text("X (down bone)").tag(RagdollDebugScene.ConeAxis.x)
                        Text("Y (across)").tag(RagdollDebugScene.ConeAxis.y)
                        Text("Z (front/back)").tag(RagdollDebugScene.ConeAxis.z)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: scene.selectedAxis) { _, _ in
                        scene.applyTuning(); scene.needsRebuild = true
                    }
                }
                tuningRow("Cone Y °",  $scene.coneY,  range: 5...120, baked: true)
                tuningRow("Cone Z °",  $scene.coneZ,  range: 5...120, baked: true)
            }
            .disabled(!scene.limitJoints)
            .opacity(scene.limitJoints ? 1 : 0.4)
        }
        .padding(14)
        .frame(maxWidth: 460)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Control Panel

    private var controlPanel: some View {
        VStack(spacing: 10) {
            Text(scene.status)
                .font(RagdollDebugTheme.font(12))
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                Button {
                    Task { await activateRagdoll() }
                } label: {
                    Label("DROP", systemImage: "figure.fall")
                        .font(RagdollDebugTheme.font(17, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent).tint(.red)
                .disabled(scene.ragdollActive)

                Button { launchSphere() } label: {
                    Label("LAUNCH", systemImage: "arrow.right.circle.fill")
                        .font(RagdollDebugTheme.font(17, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent).tint(.orange)

                Button { toggleProxyVisibility() } label: {
                    Label(scene.showDebugPhysics ? "HIDE PROX" : "SHOW PROX", systemImage: "eye")
                        .font(RagdollDebugTheme.font(17, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent).tint(.cyan)

                Button { printTuningValues() } label: {
                    Label("PRINT VALS", systemImage: "doc.on.clipboard")
                        .font(RagdollDebugTheme.font(17, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent).tint(.green)

                Button { printJointNames() } label: {
                    Label("JOINTS", systemImage: "list.bullet")
                        .font(RagdollDebugTheme.font(17, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent).tint(.purple)

                Button {
                    Task { await resetScene() }
                } label: {
                    Label("RESET", systemImage: "arrow.counterclockwise")
                        .font(RagdollDebugTheme.font(17, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                }
                .buttonStyle(.bordered).tint(.white)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Scene Setup

    @MainActor
    private func buildScene(content: RealityViewContent) async {
        let root = scene.root
        root.name = "RagdollDebugRoot"
        root.components.set(PhysicsSimulationComponent())

        let floor = makeFloor()
        root.addChild(floor)
        scene.floor = floor

        let sphere = makeSphere()
        root.addChild(sphere)
        scene.sphere = sphere

        var light = PointLightComponent()
        light.color = .white; light.intensity = 2000; light.attenuationRadius = 5
        let lightEntity = Entity(); lightEntity.position = [0, 1.5, 0.5]
        lightEntity.components.set(light)
        root.addChild(lightEntity)

        // Add root to the scene FIRST so PhysicsSphericalJoint.addToSimulation() can find entities.
        content.add(root)

        await spawnCharacter(into: root)
    }

    @MainActor
    private func spawnCharacter(into root: Entity) async {
        guard let loaded = try? await Entity(named: "RagdollCharacter_idle", in: Bundle.module) else {
            let fallback = ModelEntity(
                mesh: .generateBox(size: [0.5, 1.8, 0.5]),
                materials: [SimpleMaterial(color: .systemGreen, isMetallic: false)]
            )
            fallback.position = SIMD3(0, RagdollDebugScene.floorY + 0.9, 0)
            root.addChild(fallback)
            scene.container = fallback
            scene.status = "⚠ Model load failed – using fallback"
            return
        }

        let container = Entity()
        container.name = "CharacterContainer"
        container.position = SIMD3(0, RagdollDebugScene.floorY + 0.01, 0)

        let m = loaded.clone(recursive: true)
        m.name = "CharacterModel"

        // Fixed cosmetic scale (authored mesh ~10 m → ~1.8 m). Do NOT derive from visualBounds:
        // on a skinned mesh that returns a collapsed height before the skeleton is evaluated.
        m.scale = .init(repeating: RagdollDebugScene.characterScale)

        if let anim = m.availableAnimations.first {
            scene.idleAnimation = anim
            scene.animationHost = m
            m.playAnimation(anim.repeat(), transitionDuration: 0, startsPaused: false)
        }

        container.addChild(m)
        root.addChild(container)

        scene.container = container
        scene.model     = (m as? ModelEntity) ?? m.findModelEntity()

        if let model = scene.model,
           let rig = HybridRagdollRigBuilder.build(
               model: model,
               simulationRoot: root,
               collisionGroup: RagdollDebugScene.boneGroup,
               collisionMask: [RagdollDebugScene.floorGroup, RagdollDebugScene.sphereGroup]
               // No prescaleToRenderHeight: the debug model is already pre-scaled small.
           ) {
            container.components.set(rig)
            scene.status = "Character loaded · Rig built (\(rig.bones.count) bones) · Press DROP"
        } else {
            scene.status = "Character loaded · Rig failed – check joint names"
        }
    }

    // MARK: - Floor

    private func makeFloor() -> ModelEntity {
        var mat = PhysicallyBasedMaterial()
        mat.baseColor = .init(tint: UIColor(white: 0.35, alpha: 1))
        mat.roughness = .init(floatLiteral: 0.9)
        let entity = ModelEntity(
            mesh: .generatePlane(width: RagdollDebugScene.floorSize,
                                 depth: RagdollDebugScene.floorSize),
            materials: [mat]
        )
        entity.name = "DebugFloor"
        entity.position = SIMD3(0, RagdollDebugScene.floorY, 0)
        entity.components.set(PhysicsBodyComponent(
            massProperties: .default,
            material: .generate(staticFriction: 0.8, dynamicFriction: 0.6, restitution: 0.1),
            mode: .static
        ))
        var col = CollisionComponent(shapes: [
            .generateBox(width: RagdollDebugScene.floorSize, height: 0.1,
                         depth: RagdollDebugScene.floorSize)
        ])
        col.filter = CollisionFilter(
            group: RagdollDebugScene.floorGroup,
            mask: [RagdollDebugScene.boneGroup, RagdollDebugScene.sphereGroup]
        )
        entity.components.set(col)
        return entity
    }

    // MARK: - Sphere

    private func makeSphere() -> ModelEntity {
        var mat = PhysicallyBasedMaterial()
        mat.baseColor = .init(tint: UIColor(red: 1, green: 0.35, blue: 0, alpha: 1))
        mat.roughness = .init(floatLiteral: 0.3); mat.metallic = .init(floatLiteral: 0.8)
        let entity = ModelEntity(mesh: .generateSphere(radius: 0.12), materials: [mat])
        entity.name = "SmashSphere"
        entity.position = SIMD3(0.45, RagdollDebugScene.floorY + 0.12, 0)
        entity.components.set(PhysicsBodyComponent(
            massProperties: .init(mass: 5),
            material: .generate(staticFriction: 0.3, dynamicFriction: 0.2, restitution: 0.4),
            mode: .static
        ))
        var col = CollisionComponent(shapes: [.generateSphere(radius: 0.12)])
        col.filter = CollisionFilter(
            group: RagdollDebugScene.sphereGroup,
            mask: [RagdollDebugScene.floorGroup, RagdollDebugScene.boneGroup]
        )
        entity.components.set(col)
        entity.components.set(PhysicsMotionComponent())
        return entity
    }

    // MARK: - Ragdoll Activation

    @MainActor
    private func activateRagdoll() async {
        guard !scene.ragdollActive,
              let container = scene.container,
              var rag = container.components[HybridRagdollComponent.self] else { return }

        scene.model?.stopAllAnimations(recursive: true)
        container.stopAllAnimations(recursive: true)

        let t = HybridRagdollRigBuilder.tuning
        let tumbleImpulse = t.tumbleImpulse * t.impulseScale
        HybridRagdollRigBuilder.activate(component: &rag, container: container, impulse: tumbleImpulse,
                                         diagLabel: "DEBUG-DROP")
        container.components.set(rag)

        scene.ragdollActive = true
        scene.status = "Ragdoll active · Physics driving skeleton · LAUNCH sphere to smash"
    }

    // MARK: - Proxy Visibility

    private func toggleProxyVisibility() {
        scene.showDebugPhysics.toggle()
        guard let container = scene.container,
              let rag = container.components[HybridRagdollComponent.self] else { return }
        HybridRagdollRigBuilder.setProxiesVisible(scene.showDebugPhysics, component: rag)
    }

    // MARK: - Sphere Launch

    private func launchSphere() {
        guard let sphere = scene.sphere, let container = scene.container else { return }
        var targetPos = container.position(relativeTo: scene.root)
        targetPos.y += 0.08
        let dir = normalize(targetPos - sphere.position(relativeTo: scene.root))

        if var phys = sphere.components[PhysicsBodyComponent.self] {
            phys.mode = .dynamic; sphere.components.set(phys)
        }
        if var motion = sphere.components[PhysicsMotionComponent.self] {
            motion.linearVelocity = dir * 5.0; sphere.components.set(motion)
        }
        scene.status = "Sphere launched!"
    }

    // MARK: - Reset

    @MainActor
    private func resetScene() async {
        for child in scene.root.children where child.name.hasPrefix("RagProxy_") {
            child.removeFromParent()
        }
        scene.container?.removeFromParent()
        scene.sphere?.removeFromParent()
        scene.container = nil; scene.model = nil; scene.sphere = nil
        scene.ragdollActive = false; scene.showDebugPhysics = false
        scene.applyTuning()
        scene.needsRebuild = false

        await spawnCharacter(into: scene.root)

        let sphere = makeSphere()
        scene.root.addChild(sphere)
        scene.sphere = sphere

        scene.status = "Reset · Press DROP to ragdoll"
    }

    // MARK: - Joint / Tuning Debug

    private func printTuningValues() {
        let t = HybridRagdollRigBuilder.tuning
        let block = """
        === RAGDOLL TUNING (paste into HybridRagdollRigBuilder.Tuning defaults) ===
            var linearDamping: Float  = \(String(format: "%.2f", t.linearDamping))
            var angularDamping: Float = \(String(format: "%.2f", t.angularDamping))
            var massScale: Float      = \(String(format: "%.2f", t.massScale))
            var restitution: Float    = \(String(format: "%.2f", t.restitution))
            var jointFriction: Float  = \(String(format: "%.2f", t.jointFriction))
            var limitJoints: Bool = \(t.limitJoints)
            var impulseScale: Float   = \(String(format: "%.2f", t.impulseScale))
            var maxLinearSpeed: Float  = \(String(format: "%.2f", t.maxLinearSpeed))
            var maxAngularSpeed: Float = \(String(format: "%.2f", t.maxAngularSpeed))
            var settleTime: TimeInterval = \(String(format: "%.2f", t.settleTime))
        ========================================================================
        """
        print(block)
        scene.status = "Tuning printed to console — Lin \(String(format: "%.1f", t.linearDamping)) · Ang \(String(format: "%.1f", t.angularDamping)) · Mass \(String(format: "%.1f", t.massScale))×"
    }

    private func printJointNames() {
        guard let model = scene.model else {
            scene.status = "No model — load character first"
            return
        }
        let names = model.jointNames
        print("=== jointNames (\(names.count)) on '\(model.name)' ===")
        for (i, name) in names.enumerated() { print("  [\(i)] \(name)") }
        scene.status = "Joints printed to console (\(names.count) total)"
    }
}

// MARK: - Preview

#Preview {
    RagdollDebugView()
        .frame(width: 520, height: 620)
}
