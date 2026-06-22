import SwiftUI
import DicyaninRagdoll

@main
struct RagdollDemoApp: App {
    init() {
        DicyaninRagdoll.registerComponentsAndSystems()
    }

    var body: some Scene {
        WindowGroup {
            RagdollDebugView()
        }
        .windowStyle(.plain)
        .defaultSize(width: 1.0, height: 1.2, depth: 0.1, in: .meters)
    }
}
