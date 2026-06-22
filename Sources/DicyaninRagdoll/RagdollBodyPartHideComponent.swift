//
//  RagdollBodyPartHideComponent.swift
//  DicyaninRagdoll
//
//  Drives per-joint ROTATIONAL spring impulses on a VISIBLE skinned ModelEntity. The companion
//  `RagdollBodyPartHideSystem` reads this with .rendering timing and rotates each struck joint
//  around its pivot (axis-angle spring), layered on top of the running animation — so the hit
//  bone visibly SWINGS in the bullet direction and oscillates back to rest while the walk / idle
//  cycle keeps playing. Rotation (not translation) is what reads as a real hit recoil.
//
//  This is the "got shot but didn't die" reaction. The full ragdoll (HybridRagdoll*) takes over
//  on death; this one is for live, non-lethal impacts.
//

import RealityKit
import simd

public struct RagdollBodyPartHideComponent: Component {

    public struct JointHit {
        public let suffix: String
        /// Rotation axis (unit) in the joint's local frame — the bone swings around this.
        public var axis: SIMD3<Float>
        /// Current angular displacement around `axis`, radians (the live spring state).
        public var angle: Float
        /// Current angular velocity, rad/s. The initial impulse seeds this; the spring decays it.
        public var angVel: Float
        /// Seconds since this joint was last struck. The system force-resets the joint once this
        /// exceeds `maxAge`, so a joint can never jitter indefinitely.
        public var age: Float = 0
    }

    /// Hard safety cap: a struck joint is forced back to rest at most this long after its most
    /// recent hit, even if the damped-spring math hasn't fully settled yet.
    public static let maxAge: Float = 1.0

    // MARK: - Spring tuning
    // ω₀ = √stiffness ≈ 14.7 rad/s → half-period ≈ 0.21 s. ζ ≈ 0.51 — underdamped, overshoots once.
    public static let stiffness: Float = 215
    public static let damping:   Float =  15

    /// Undamped natural frequency ω₀ = √stiffness. Peak swing angle ≈ angVel / ω₀.
    public static var naturalFreq: Float { stiffness.squareRoot() }

    /// Base angular impulse (rad/s) seeded into a struck joint.
    public static let baseSpeed: Float = 7.0

    public var hits: [JointHit] = []

    // MARK: - Jolt region

    /// Finer-grained hit region than the coarse `RagdollBodyPart`. Separates left/right limbs so a
    /// leg shot only swings THAT leg, while an upper-body shot cascades through torso + arms.
    public enum JoltRegion: Sendable {
        case head, torso, leftArm, rightArm, leftLeg, rightLeg, bothLegs

        /// Map the coarse body-part onto a reaction region. `.legs` has no side info, so it
        /// falls back to swinging both legs; callers that know the struck leg pass it explicitly.
        public init(_ part: RagdollBodyPart) {
            switch part {
            case .head:     self = .head
            case .torso:    self = .torso
            case .leftArm:  self = .leftArm
            case .rightArm: self = .rightArm
            case .legs:     self = .bothLegs
            }
        }
    }

    // MARK: - Init / update

    public init(bodyPart: RagdollBodyPart, bulletModelDir: SIMD3<Float>? = nil,
                peakDegrees: Float? = nil) {
        addHit(for: JoltRegion(bodyPart), bulletModelDir: bulletModelDir, peakDegrees: peakDegrees)
    }

    public init(region: JoltRegion, bulletModelDir: SIMD3<Float>? = nil, peakDegrees: Float? = nil) {
        addHit(for: region, bulletModelDir: bulletModelDir, peakDegrees: peakDegrees)
    }

    public mutating func add(bodyPart: RagdollBodyPart, bulletModelDir: SIMD3<Float>? = nil,
                             peakDegrees: Float? = nil) {
        addHit(for: JoltRegion(bodyPart), bulletModelDir: bulletModelDir, peakDegrees: peakDegrees)
    }

    public mutating func add(region: JoltRegion, bulletModelDir: SIMD3<Float>? = nil,
                             peakDegrees: Float? = nil) {
        addHit(for: region, bulletModelDir: bulletModelDir, peakDegrees: peakDegrees)
    }

    /// Per-shot peak swing angle (degrees) for a full-weight struck bone, scaled by weapon damage
    /// and randomised so no two shots look identical.
    public static func randomPeakDegrees(forWeaponDamage damage: Int) -> Float {
        let power = max(0, min(1, (Float(damage) - 10) / 50))
        let lo = 0.5 + (3.0 - 0.5) * power
        let hi = 3.0 + (5.0 - 3.0) * power
        return Float.random(in: lo...hi)
    }

    private mutating func addHit(
        for region: JoltRegion,
        bulletModelDir: SIMD3<Float>?,
        peakDegrees: Float?
    ) {
        let primary: SIMD3<Float>
        if let d = bulletModelDir, simd_length_squared(d) > 1e-6 {
            let jitter = SIMD3<Float>(
                Float.random(in: -0.25...0.25),
                Float.random(in: -0.10...0.10),
                Float.random(in: -0.25...0.25)
            )
            primary = simd_normalize(d + jitter)
        } else {
            primary = randomDir()
        }

        let up = SIMD3<Float>(0, 1, 0)
        var axis = simd_cross(up, primary)
        if simd_length_squared(axis) < 1e-5 { axis = SIMD3<Float>(1, 0, 0) }
        axis = simd_normalize(axis)

        let omega = Self.naturalFreq
        for (suffix, weight) in Self.bones(for: region) {
            let jitteredAxis = simd_normalize(axis + SIMD3<Float>(
                Float.random(in: -0.12...0.12),
                Float.random(in: -0.12...0.12),
                Float.random(in: -0.12...0.12)
            ))
            let angVel: Float
            if let deg = peakDegrees {
                angVel = (deg * .pi / 180) * omega * weight
            } else {
                angVel = Self.baseSpeed * weight
            }
            // Merge into an existing mid-swing entry rather than appending a second oscillator,
            // so there is always at most one spring per joint and it reliably converges.
            if let idx = hits.firstIndex(where: { $0.suffix == suffix }) {
                hits[idx].axis = jitteredAxis
                hits[idx].angVel += angVel
                hits[idx].age = 0
            } else {
                hits.append(JointHit(suffix: suffix, axis: jitteredAxis, angle: 0, angVel: angVel))
            }
        }
    }

    // MARK: - Bone cascade tables

    /// (suffix, impulse_weight) pairs — the struck bone gets 1.0, anatomically-connected neighbours
    /// get attenuated impulses so the reaction radiates realistically. Suffixes the skeleton doesn't
    /// contain are ignored by the system, so the extra entries are safe across different rigs.
    private static func bones(for region: JoltRegion) -> [(String, Float)] {
        switch region {
        case .head:
            return [("head", 1.0), ("neck", 0.85),
                    ("spine2", 0.55), ("spine1", 0.40), ("spine", 0.30),
                    ("leftshoulder", 0.22), ("rightshoulder", 0.22),
                    ("leftarm", 0.18), ("rightarm", 0.18), ("hips", 0.12)]

        case .torso:
            return [("spine", 1.0), ("spine1", 0.92), ("spine2", 0.82),
                    ("neck", 0.55), ("head", 0.45),
                    ("leftshoulder", 0.60), ("rightshoulder", 0.60),
                    ("leftarm", 0.55), ("rightarm", 0.55),
                    ("leftforearm", 0.38), ("rightforearm", 0.38),
                    ("lefthand", 0.22), ("righthand", 0.22),
                    ("hips", 0.45), ("leftupleg", 0.18), ("rightupleg", 0.18)]

        case .leftArm:
            return [("leftarm", 1.0), ("leftforearm", 0.80), ("lefthand", 0.55),
                    ("leftshoulder", 0.45), ("spine2", 0.22), ("spine1", 0.14),
                    ("spine", 0.10), ("head", 0.06)]

        case .rightArm:
            return [("rightarm", 1.0), ("rightforearm", 0.80), ("righthand", 0.55),
                    ("rightshoulder", 0.45), ("spine2", 0.22), ("spine1", 0.14),
                    ("spine", 0.10), ("head", 0.06)]

        case .leftLeg:
            return [("leftupleg", 1.0), ("leftleg", 0.80), ("leftfoot", 0.45),
                    ("hips", 0.15)]

        case .rightLeg:
            return [("rightupleg", 1.0), ("rightleg", 0.80), ("rightfoot", 0.45),
                    ("hips", 0.15)]

        case .bothLegs:
            return [("leftupleg", 0.90), ("rightupleg", 0.90),
                    ("leftleg", 0.65), ("rightleg", 0.65),
                    ("leftfoot", 0.35), ("rightfoot", 0.35),
                    ("hips", 0.30), ("spine", 0.10)]
        }
    }

    public var isEmpty: Bool { hits.isEmpty }
}

// MARK: - Helpers

private func randomDir() -> SIMD3<Float> {
    let v = SIMD3<Float>(
        Float.random(in: -1...1),
        Float.random(in: 0.1...0.5),
        Float.random(in: -1...1)
    )
    let len = simd_length(v)
    return len > 0.001 ? v / len : SIMD3<Float>(1, 0, 0)
}
