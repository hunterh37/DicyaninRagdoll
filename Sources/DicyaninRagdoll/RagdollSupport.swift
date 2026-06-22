//
//  RagdollSupport.swift
//  DicyaninRagdoll
//
//  Shared, game-agnostic support types for the hybrid ragdoll: lightweight debug logging,
//  the body-part taxonomy used by the hit-jolt cascade, and the default collision groups
//  the rig uses. Everything here is overridable by the host app — the manager and rig
//  builder all take collision group/mask parameters so these constants are only defaults.
//

import Foundation
import RealityKit

// MARK: - Logging

/// DEBUG-only logger. Mirrors the original project's `dlog`; compiled out of release builds.
@inline(__always)
func ragdollLog(_ items: Any..., separator: String = " ", terminator: String = "\n") {
#if DEBUG
    Swift.print(items.map { "\($0)" }.joined(separator: separator), terminator: terminator)
#endif
}

// MARK: - Body parts

/// Coarse body-part taxonomy used by the per-bone hit-jolt cascade and by
/// `HybridRagdollRigBuilder.bodyPart(forSuffix:)`. Game-agnostic — map your own
/// damage model onto these cases.
public enum RagdollBodyPart: String, Codable, Sendable {
    case head, torso, leftArm, rightArm, legs
}

// MARK: - Collision groups

/// Default collision groups for the proxy rig and the catch floor. These occupy bits
/// 24–27 to stay clear of most host-app group assignments; every public API that needs a
/// group/mask accepts an override so you can slot the rig into your own collision registry.
public enum RagdollCollision {
    /// Group the proxy bone bodies belong to.
    public static var ragdoll: CollisionGroup { CollisionGroup(rawValue: 1 << 24) }
    /// Group for the package-spawned catch floor.
    public static var floor: CollisionGroup { CollisionGroup(rawValue: 1 << 25) }
    /// Optional scene-reconstruction mesh group (host app supplies the real one).
    public static var sceneMesh: CollisionGroup { CollisionGroup(rawValue: 1 << 26) }
    /// Optional wall group (host app supplies the real one).
    public static var wall: CollisionGroup { CollisionGroup(rawValue: 1 << 27) }

    /// Default mask the proxies collide against (floor + scene + walls).
    public static var defaultMask: CollisionGroup { [floor, sceneMesh, wall] }
}
