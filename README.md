# DicyaninRagdoll

A production hybrid **kinematic→physics skeletal ragdoll** for RealityKit skinned models on
visionOS. There is no good public RealityKit ragdoll package — this fills that gap.

Invisible physics proxy bodies (capsules / spheres + spherical joints) are built from a skinned
mesh's skeleton. While **kinematic** they ride the playing animation; on `activate` they flip to
**dynamic** and the system maps each proxy's world orientation back into a parent-local joint
rotation, writing the whole pose into `model.jointTransforms` in one batch per frame. The result
is a real ragdoll that takes over a live, animated character on death.

A SwiftUI **debug/tuning lab** (`RagdollDebugView`) ships with a bundled rigged character so you
can DROP, smash, fire per-bone test "gunshots", live-tune every knob, and dump the dialed-in
values straight back into the defaults.

## Why it's not trivial

This encodes a lot of hard-won detail that a naive implementation gets wrong:

- **`JointTransformBuffer`** — a reference wrapper that avoids per-frame copy-on-write of the
  50+ element joint-transform array once the rig owns the skeleton.
- **Positional joint projection** — a stretched spherical pin becomes a perpetual energy source
  ("ragdoll goes crazy"); the system catches it the same frame it breaks and snaps the bone back
  onto its build-time anchor sphere instead of letting velocity clamps chase the symptom.
- **Settle + freeze** — per-frame velocity clamps plus a slow-timer that freezes the rig back to
  kinematic so the contact/joint solver can't keep re-exciting it after it lands.
- **Scale baked into `modelWorld`, never `proxy.scale`** — a non-unit scale on a *dynamic*
  `PhysicsBody` breaks RealityKit's spherical-joint cone solver and limbs fling free. The render
  prescale is baked into the joint/shape measurement so every proxy stays unit-scale.
- **Shape cache + prewarm** — cooked collision shapes are cached per (asset, scale, inflation,
  suffix) and can be pre-warmed so the first activation doesn't cook 9 shapes on the hot frame.
- **Live cap + graceful overflow** — `RagdollManager` hard-caps simultaneous physics ragdolls
  (default 5); past the cap an `onBudgetExhausted` hook lets you substitute a cheap dissolve.
- **FIFO build queue** — at most one rig built per frame so a wave of simultaneous deaths can't
  pile every expensive build into one tick.
- **Split build→activate** — the rig sits kinematic for a beat so RealityKit registers every
  collider and resolves overlapping capsule contacts before the dynamic flip; collapsing the two
  into one tick is what makes a rig explode on activation.

### SDK 26.4 tuning note

The shipped `Tuning` defaults are the **"Natural"** preset (massScale 1, restitution 0, damping
0.5/1.0). Earlier dialed-in values (massScale 273, restitution 0.6, damping 12/20) were tuned on
an older SDK; on visionOS 26.4 the spherical-joint solver can't satisfy the joint pins when each
tiny limb collider carries that much mass, so the body scatters. Lower mass + no bounce keeps the
solver stable. Re-tune in `RagdollDebugView` → **PRINT VALS** if you need a different feel.

## Requirements

- visionOS 2.0+
- Swift 6 / RealityKit

## Installation

Swift Package Manager:

```swift
.package(url: "https://github.com/<you>/DicyaninRagdoll.git", from: "1.0.0")
```

## Usage

### 1. Register at launch

```swift
import DicyaninRagdoll

@main
struct MyApp: App {
    init() {
        DicyaninRagdoll.registerComponentsAndSystems()
    }
    // ...
}
```

### 2. Ragdoll a character on death

```swift
// `character` contains a skinned ModelEntity somewhere in its subtree.
// `worldRoot` must be in the same physics simulation as your floor / scene mesh.
RagdollManager.shared.activateRagdoll(
    on: character,
    config: .init(
        simulationRoot: worldRoot,
        renderHeight: 1.8,
        collisionGroup: RagdollCollision.ragdoll,
        collisionMask: [myFloorGroup, mySceneMeshGroup, myWallGroup]
    )
)

// Optional: cheap fallback when the live-ragdoll budget is full.
RagdollManager.shared.onBudgetExhausted = { entity in
    myParticleDissolve(entity)
}

// Optional: pre-warm shapes when a character spawns so the first kill never hitches.
RagdollManager.shared.prewarmRagdollShapes(for: character, renderHeight: 1.8)
```

### 3. Non-lethal hit reaction (optional)

For a "got shot but didn't die" recoil that swings the struck bone and cascades to its neighbours
on top of the running animation, attach a hit-jolt spring to the visible skinned model:

```swift
let dir = model.convert(direction: bulletWorldDirection, from: nil)
if var comp = model.components[RagdollBodyPartHideComponent.self] {
    comp.add(bodyPart: .torso, bulletModelDir: dir)
    model.components.set(comp)
} else {
    model.components.set(RagdollBodyPartHideComponent(bodyPart: .torso, bulletModelDir: dir))
}
```

### 4. Tuning lab

```swift
import DicyaninRagdoll
// Drop into any window / volume:
RagdollDebugView()
```

## Skeleton conventions

The rig keys bones by a **canonical suffix** (last path/`:`-delimited segment, lowercased, spaces
stripped). It recognises: `hips`, `spine`, `head`, `left/rightarm`, `left/rightupleg`,
`left/rightleg` for the physics proxies, plus `neck`, `spine1/2`, `left/rightshoulder`,
`left/rightforearm`, `left/righthand`, `left/rightfoot` for the hit-jolt cascade. Suffixes a given
skeleton lacks are simply ignored, so mixed rigs are safe. Mixamo-style names work out of the box.

## Bundled asset

A rigged character (`RagdollCharacter_idle.usdz`) is bundled solely so `RagdollDebugView` works
out of the box. Your own characters never need it — pass any skinned `ModelEntity` to the manager.

## License

MIT — see [LICENSE](LICENSE).
