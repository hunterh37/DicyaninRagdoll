//
//  RagdollManager.swift
//  DicyaninRagdoll
//
//  Game-agnostic driver for turning a live, animated skinned character into a physics ragdoll.
//
//  Generalised from the original ZombieShooter manager. It keeps the hard-won machinery:
//    • a hard LIVE-CAP on simultaneous physics ragdolls with graceful overflow,
//    • the FIFO build queue (one rig build per frame),
//    • the split build→activate timing that prevents a same-tick solver explosion,
//    • an optional per-death catch floor for when the host floor hasn't resolved (simulator),
//  while dropping all the zombie-specific coupling (waves, portals, components). The host app
//  supplies the entity, the simulation root, and a render height; an `onBudgetExhausted` hook
//  lets the host substitute its own dissolve / particle effect when the cap is hit.
//

import Foundation
import RealityKit

@MainActor
public final class RagdollManager {
    public static let shared = RagdollManager()
    public init() {}

    // MARK: - Live-ragdoll budget (graceful degradation)

    /// Hard cap on simultaneously-simulated physics ragdolls. Each live rig is ~9 proxy bodies +
    /// spherical joints in the global physics world, so a pile of simultaneous deaths can spike the
    /// solver. Beyond this count new deaths should fall back to a cheaper effect (see
    /// `onBudgetExhausted`). The player can't visually track this many flopping bodies at once,
    /// so the fallback is invisible while bounding the worst case hard.
    public var maxLiveRagdolls = 5

    private(set) public var liveRagdollCount = 0

    /// True when the live-ragdoll budget is already full — callers should use their cheap fallback.
    public var ragdollBudgetExhausted: Bool { liveRagdollCount >= maxLiveRagdolls }

    /// Optional host hook invoked (instead of building a rig) when an activation request arrives
    /// while the budget is exhausted. Use it to trigger a particle dissolve or similar.
    public var onBudgetExhausted: ((Entity) -> Void)?

    private func releaseRagdollSlot() {
        if liveRagdollCount > 0 { liveRagdollCount -= 1 }
    }

    // MARK: - Configuration

    public struct Config {
        /// Entity under which proxy bodies + catch floor are parented. MUST be in the same physics
        /// simulation as your floor / scene mesh (i.e. NOT under a `WorldComponent` boundary).
        public var simulationRoot: Entity
        /// Target rendered height (metres) the rig is prescaled to.
        public var renderHeight: Float
        /// Collision group the proxy bodies belong to.
        public var collisionGroup: CollisionGroup
        /// Mask the proxies collide against (your floor / scene mesh / walls).
        public var collisionMask: CollisionGroup
        /// Activation impulse on the hips. Defaults to the tuning's tumble × impulseScale.
        public var impulse: SIMD3<Float>?
        /// Spawn a package catch floor under the body when no host floor is detected near its feet.
        public var spawnCatchFloor: Bool
        /// Seconds before the island is torn down and the budget slot released.
        public var teardownDelay: TimeInterval

        public init(simulationRoot: Entity,
                    renderHeight: Float = 1.80,
                    collisionGroup: CollisionGroup = RagdollCollision.ragdoll,
                    collisionMask: CollisionGroup = RagdollCollision.defaultMask,
                    impulse: SIMD3<Float>? = nil,
                    spawnCatchFloor: Bool = true,
                    teardownDelay: TimeInterval = 5) {
            self.simulationRoot = simulationRoot
            self.renderHeight = renderHeight
            self.collisionGroup = collisionGroup
            self.collisionMask = collisionMask
            self.impulse = impulse
            self.spawnCatchFloor = spawnCatchFloor
            self.teardownDelay = teardownDelay
        }
    }

    // MARK: - Public API

    /// Turn a live, animated character `entity` into a physics ragdoll.
    ///
    /// `entity` must contain (anywhere in its subtree) a skinned `ModelEntity` with joints. The
    /// call returns immediately; the actual rig build is queued (one per frame) and the dynamic
    /// flip is deferred a beat so the solver starts from a settled, contact-resolved state.
    ///
    /// If the budget is exhausted this calls `onBudgetExhausted(entity)` and returns `false`.
    @discardableResult
    public func activateRagdoll(on entity: Entity, config: Config) -> Bool {
        guard !ragdollBudgetExhausted else {
            onBudgetExhausted?(entity)
            return false
        }
        guard let model = resolveModel(from: entity) else {
            ragdollLog("RagdollManager: could not find skinned model for \(entity.name)")
            return false
        }

        let worldTransform = entity.transformMatrix(relativeTo: nil)
        let worldPosition = SIMD3<Float>(worldTransform.columns.3.x,
                                         worldTransform.columns.3.y,
                                         worldTransform.columns.3.z)

        // Release RealityKit's ownership of the skeleton and remove any live hit-jolt spring so
        // nothing fights the ragdoll over model.jointTransforms.
        Self.prepareSkeletonForRagdoll(entity)

        let t = HybridRagdollRigBuilder.tuning
        let impulse = config.impulse ?? (t.tumbleImpulse * t.impulseScale)

        // Reserve a budget slot synchronously the instant we commit — makes the cap race-proof
        // for several deaths in one frame. Every exit path releases it exactly once.
        liveRagdollCount += 1

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.05))
            guard !Task.isCancelled, let self, entity.parent != nil else {
                RagdollManager.shared.releaseRagdollSlot()
                return
            }
            RagdollBuildQueue.shared.enqueue { [weak self] in
                guard let self, entity.parent != nil else {
                    RagdollManager.shared.releaseRagdollSlot()
                    return
                }
                self.buildAndActivate(entity: entity, model: model,
                                      impulse: impulse, feet: worldPosition, config: config)
            }
        }
        return true
    }

    // MARK: - Build + activate

    private func buildAndActivate(entity: Entity, model: ModelEntity,
                                  impulse: SIMD3<Float>, feet: SIMD3<Float>, config: Config) {
        guard entity.parent != nil else { releaseRagdollSlot(); return }

        let island = Entity()
        island.name = "RagdollIsland"
        config.simulationRoot.addChild(island)

        guard let rag = HybridRagdollRigBuilder.build(
            model: model,
            simulationRoot: island,
            collisionGroup: config.collisionGroup,
            collisionMask: config.collisionMask,
            prescaleToRenderHeight: config.renderHeight,
            includeDebugViz: false
        ) else {
            ragdollLog("RagdollManager: rig build failed for \(entity.name)")
            island.removeFromParent()
            releaseRagdollSlot()
            return
        }

        Self.fullyStopAnimations(entity)

        if config.spawnCatchFloor {
            let catchFloor = makeCatchFloor(collisionGroup: config.collisionGroup,
                                            collidesWith: config.collisionGroup)
            island.addChild(catchFloor)
            // Box centre 0.35 m below feet → top surface ~0.15 m below feet, giving proxies a small
            // clearance so they don't overlap the floor on the first tick and get ejected upward.
            catchFloor.setPosition(SIMD3<Float>(feet.x, feet.y - 0.35, feet.z), relativeTo: nil)
        }

        // SPLIT BUILD FROM ACTIVATE: set the rig kinematic now, defer the dynamic flip ~0.3 s so
        // RealityKit registers every proxy's collision shape and resolves the overlapping capsule
        // contacts at the shared joints first. Collapsing build+activate into one tick is what made
        // the in-game rig explode while the debug DROP (kinematic for seconds) never did.
        entity.components.set(rag)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
            guard entity.parent != nil,
                  var liveRag = entity.components[HybridRagdollComponent.self] else { return }
            Self.fullyStopAnimations(liveRag.model)
            HybridRagdollRigBuilder.activate(component: &liveRag, container: entity,
                                             impulse: impulse, diagLabel: "RAGDOLL")
            entity.components.set(liveRag)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + config.teardownDelay) {
            island.removeFromParent()
            RagdollManager.shared.releaseRagdollSlot()
        }
    }

    /// Pre-cook the collision shapes for a character type so the FIRST ragdoll of that type doesn't
    /// cook 9 shapes on the hot frame. Cheap to call on every spawn (deduped per asset + height).
    public func prewarmRagdollShapes(for entity: Entity, renderHeight: Float,
                                     collisionGroup: CollisionGroup = RagdollCollision.ragdoll,
                                     collisionMask: CollisionGroup = RagdollCollision.defaultMask) {
        guard let model = resolveModel(from: entity) else { return }
        HybridRagdollRigBuilder.prewarmShapeCache(model: model,
                                                  prescaleToRenderHeight: renderHeight,
                                                  collisionGroup: collisionGroup,
                                                  collisionMask: collisionMask)
    }

    // MARK: - Catch floor

    private static let catchFloorShape = ShapeResource.generateBox(width: 6, height: 0.4, depth: 6)
    private static let catchFloorMaterial = PhysicsMaterialResource.generate(
        staticFriction: 0.8, dynamicFriction: 0.6, restitution: 0.05)

    private func makeCatchFloor(collisionGroup: CollisionGroup, collidesWith: CollisionGroup) -> Entity {
        let floor = Entity()
        floor.name = "RagdollCatchFloor"
        floor.components.set(PhysicsBodyComponent(
            massProperties: .default,
            material: Self.catchFloorMaterial,
            mode: .static
        ))
        var col = CollisionComponent(shapes: [Self.catchFloorShape])
        col.filter = CollisionFilter(group: RagdollCollision.floor, mask: [collidesWith])
        floor.components.set(col)
        return floor
    }

    // MARK: - Skeleton preparation

    /// Single-pass preparation of the subtree for the ragdoll: stop animation playback + drop the
    /// AnimationLibrary driver (so RealityKit releases the skeleton), and strip the hit-jolt spring
    /// so it doesn't fight the ragdoll over the same joints.
    public static func prepareSkeletonForRagdoll(_ entity: Entity) {
        entity.stopAllAnimations(recursive: false)
        entity.components.remove(AnimationLibraryComponent.self)
        entity.components.remove(RagdollBodyPartHideComponent.self)
        for child in entity.children { prepareSkeletonForRagdoll(child) }
    }

    /// Completely halt animation across the whole subtree so RealityKit fully releases ownership of
    /// the skinned skeleton before the ragdoll takes it over.
    public static func fullyStopAnimations(_ entity: Entity) {
        entity.stopAllAnimations(recursive: true)
        func strip(_ e: Entity) {
            e.stopAllAnimations(recursive: false)
            e.components.remove(AnimationLibraryComponent.self)
            for child in e.children { strip(child) }
        }
        strip(entity)
    }

    // MARK: - Model resolution

    private func resolveModel(from entity: Entity) -> ModelEntity? {
        HybridRagdollRigBuilder.skinnedModel(under: entity) ?? entity.findModelEntity()
    }
}

// MARK: - Entity extension

public extension Entity {
    /// Depth-first search for the first ModelEntity descendant with joints. Falls back to the
    /// first ModelEntity of any kind. Single pass.
    func findModelEntity() -> ModelEntity? {
        var fallback: ModelEntity? = nil
        func search(_ entity: Entity) -> ModelEntity? {
            if let m = entity as? ModelEntity {
                if !m.jointNames.isEmpty { return m }
                if fallback == nil { fallback = m }
            }
            for child in entity.children {
                if let found = search(child) { return found }
            }
            return nil
        }
        return search(self) ?? fallback
    }
}
