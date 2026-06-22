//
//  RagdollBodyPartHideSystem.swift
//  DicyaninRagdoll
//
//  Integrates per-joint spring physics on a VISIBLE skinned ModelEntity every render frame.
//  Reads `RagdollBodyPartHideComponent`, steps the damped spring, and writes the resulting
//  displacement into model.jointTransforms on top of the animation pose. Runs with .rendering
//  timing so it overlays AFTER the animation system sets the base pose for the frame.
//

import RealityKit
import simd

public final class RagdollBodyPartHideSystem: System {

    public static let query = EntityQuery(where: .has(RagdollBodyPartHideComponent.self))

    public required init(scene: Scene) {}

    public func update(context: SceneUpdateContext) {
        let dt = Float(context.deltaTime)
        guard dt > 0 else { return }

        let k = RagdollBodyPartHideComponent.stiffness
        let c = RagdollBodyPartHideComponent.damping

        for entity in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            guard let model = entity as? ModelEntity,
                  var comp  = model.components[RagdollBodyPartHideComponent.self],
                  model.scene != nil else { continue }

            // OWNERSHIP RULE: while a ragdoll drives this skeleton, NOTHING else may write
            // model.jointTransforms. If an ACTIVE HybridRagdollComponent exists on this entity or
            // an ancestor, drop the spring instead of fighting the ragdoll — two writers on one
            // skeleton is the "limbs flying around the scene" flail. (An INACTIVE rig — e.g. the
            // debug view's always-present kinematic rig — must still allow the live jolt.)
            var owner: Entity? = model
            var ragdollActive = false
            while let node = owner {
                if node.components[HybridRagdollComponent.self]?.isActive == true {
                    ragdollActive = true
                    break
                }
                owner = node.parent
            }
            if ragdollActive {
                model.components.remove(RagdollBodyPartHideComponent.self)
                continue
            }

            // Integrate the angular springs and prune settled joints: θ'' = -k·θ - c·θ'.
            comp.hits = comp.hits.compactMap { hit -> RagdollBodyPartHideComponent.JointHit? in
                var h = hit
                h.age += dt
                if h.age >= RagdollBodyPartHideComponent.maxAge { return nil }
                let acc = -k * h.angle - c * h.angVel
                h.angVel += acc * dt
                h.angle  += h.angVel * dt
                if abs(h.angle) < 1e-4 && abs(h.angVel) < 1e-4 { return nil }
                return h
            }

            if comp.hits.isEmpty {
                model.components.remove(RagdollBodyPartHideComponent.self)
                continue
            }

            let names = model.jointNames
            guard !names.isEmpty else { model.components.set(comp); continue }
            var transforms = model.jointTransforms
            guard transforms.count == names.count else { model.components.set(comp); continue }

            var mutated = false
            for (i, name) in names.enumerated() {
                let suffix = canonicalSuffix(name)
                for hit in comp.hits where hit.suffix == suffix {
                    let swing = simd_quatf(angle: hit.angle, axis: hit.axis)
                    transforms[i].rotation = swing * transforms[i].rotation
                    mutated = true
                }
            }

            if mutated { model.jointTransforms = transforms }
            model.components.set(comp)
        }
    }

    /// Matches HybridRagdollRigBuilder.canonicalSuffix.
    private func canonicalSuffix(_ name: String) -> String {
        var s = name
        if let r = s.range(of: "/", options: .backwards) { s = String(s[r.upperBound...]) }
        if let r = s.range(of: ":", options: .backwards) { s = String(s[r.upperBound...]) }
        return s.lowercased().replacingOccurrences(of: " ", with: "")
    }
}
