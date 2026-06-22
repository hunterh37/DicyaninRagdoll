//
//  RagdollRegistration.swift
//  DicyaninRagdoll
//
//  One-call registration of every component + system this package provides. Call once at app
//  launch, BEFORE the first RealityView content closure runs.
//

import Foundation
import RealityKit

public enum DicyaninRagdoll {

    /// Register all ragdoll components and systems with RealityKit. Idempotent-safe to call once
    /// at launch (e.g. from your App init).
    @MainActor
    public static func registerComponentsAndSystems() {
        HybridRagdollComponent.registerComponent()
        RagdollBodyPartHideComponent.registerComponent()

        HybridRagdollSystem.registerSystem()
        RagdollBodyPartHideSystem.registerSystem()
        RagdollBuildQueueSystem.registerSystem()
    }
}
