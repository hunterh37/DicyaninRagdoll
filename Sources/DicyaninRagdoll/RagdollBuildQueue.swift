//
//  RagdollBuildQueue.swift
//  DicyaninRagdoll
//
//  Global FIFO throttle for ragdoll rig construction.
//
//  `HybridRagdollRigBuilder.build()` is expensive (walks 50+ joints, stack-walks per bone). Fine
//  for one activation; brutal when several models ragdoll on the same frame and every build lands
//  in the same tick. This queue pops AT MOST ONE build per frame; excess work waits a handful of
//  frames. There's no visual regression because the build already starts a beat after death.
//

import Foundation
import RealityKit

/// Global FIFO of pending ragdoll builds, drained one-per-frame by `RagdollBuildQueueSystem`.
@MainActor
public final class RagdollBuildQueue {
    public static let shared = RagdollBuildQueue()

    private var pending: [() -> Void] = []

    /// Enqueue a build closure. It runs on the main actor in a later frame, FIFO order.
    public func enqueue(_ build: @escaping () -> Void) {
        pending.append(build)
    }

    /// Pop and run at most one build. Called once per frame by the system.
    fileprivate func drainOne() {
        guard !pending.isEmpty else { return }
        let build = pending.removeFirst()
        build()
    }
}

/// Ticks `RagdollBuildQueue` exactly once per frame so no more than one ragdoll rig is built
/// per tick regardless of how many models died simultaneously.
public final class RagdollBuildQueueSystem: System {
    public required init(scene: RealityKit.Scene) { }

    public func update(context: SceneUpdateContext) {
        MainActor.assumeIsolated {
            RagdollBuildQueue.shared.drainOne()
        }
    }
}
