---
name: Add a Supacool feature
description: End-to-end walk-through for adding a new TCA feature to the Supacool board. Use when asked to add a new persisted type, a new card action, a new sheet, or anything that extends BoardFeature.
---

# Adding a Supacool feature end-to-end

Goal: you've been asked to add something new to the Matrix Board (e.g. a "pin session" action, a new card metadata chip, or a new sheet). This is the full recipe, stolen from the commits that built Phase 4.

## Before you write any code

1. Read [`docs/agent-guides/architecture.md`](../../../docs/agent-guides/architecture.md) and [`docs/agent-guides/out-of-scope.md`](../../../docs/agent-guides/out-of-scope.md).
2. Decide where the feature lives:
   - New persisted domain data? → `Supacool/Domain/`
   - New reducer logic? → extend `Supacool/Features/Board/Reducer/BoardFeature.swift`
   - New sub-reducer (own state + actions + sheet)? → new file under `Supacool/Features/Board/Reducer/`
   - New view? → `Supacool/Features/Board/Views/`
   - New persistence key? → `Supacool/Features/Board/Persistence/`
3. Check the out-of-scope list. If the feature is there, ask Comandante to re-scope before you start.

## The checklist

### If you're adding or extending a persisted Codable type

1. Add the field(s) to the struct with a sensible default.
2. Add a parameter (with default) to the memberwise init.
3. Add the key to `CodingKeys`.
4. Add a `try c.decodeIfPresent(T.self, forKey: .newKey) ?? defaultValue` line in `init(from decoder:)`.
5. **Do not remove the manual `init(from decoder:)` if your IDE suggests it.**
6. Reference: [`docs/agent-guides/persistence.md`](../../../docs/agent-guides/persistence.md).

### If you're adding a reducer action

1. Add the case to `Action` enum.
2. Add its handler in the `Reduce { state, action in … }` block.
3. For side effects that call `terminalClient` or `gitClient`: use `@Dependency(Type.self)` (type-based), not `@Dependency(\.keyPath)`. Under Swift 6, the key-path form breaks Sendable. See [`docs/agent-guides/swift6-gotchas.md`](../../../docs/agent-guides/swift6-gotchas.md#2-dependencytypeself-over-dependencykeypath).
4. For IdentifiedArrayOf lookups inside `.run` blocks, wrap in `await MainActor.run { … }` — the `Identifiable` conformance is MainActor-isolated under global isolation.

### If you're adding a view

1. Use SwiftUI, not AppKit, unless you need NSView-specific capabilities (text editors, cursor APIs, first-responder).
2. For text inputs, use Supacool's `PromptTextEditor` with the `PromptTextEditor.inset`-based placeholder pattern, not native `TextEditor`. See [`docs/agent-guides/ui-patterns.md`](../../../docs/agent-guides/ui-patterns.md#multi-line-text-input).
3. For toolbars, place items thoughtfully:
   - `.navigation` = leading cluster (next to title area)
   - `.primaryAction` = trailing
   - Between clusters: `ToolbarSpacer(.flexible)`
   - Between items in the same cluster you want visually separated: `ToolbarSpacer(.fixed)`
   - Don't wrap button labels in custom Capsule backgrounds — toolbar already renders a pill.

### If the view has a clickable card

Add:
```swift
.onHover { hovering in
  if hovering { NSCursor.pointingHand.push() }
  else { NSCursor.pop() }
}
```

Don't use `.pointerStyle(.link)` — the hand-rolled push/pop pattern matches supacode's convention.

### If you're adding state that must survive relaunch

Create a new `@Shared` key under `Supacool/Features/Board/Persistence/`, following `AgentSessionsKey.swift` or `BoardFiltersKey.swift`:

1. Value type: Codable struct with manual `init(from decoder:)`.
2. Key struct conforming to `SharedKey` with `load`, `subscribe` (empty), `save`.
3. Extension on `SharedReaderKey` adding a static `myKey` accessor.
4. Wire it into `BoardFeature.State` via `@Shared(.myKey) var value: T = .empty`.
5. Storage lives at `~/.supacode/<your-file>.json` using `SupacodePaths.baseDirectory`.

### Tests

Add a test file under `supacodeTests/`. Pattern:

```swift
import ComposableArchitecture
import DependenciesTestSupport
import Testing

@testable import supacode

@MainActor
struct MyFeatureTests {
  @Test(.dependencies) func myAction() async {
    var state = MyFeature.State()
    let store = TestStore(initialState: state) { MyFeature() }
    await store.send(.myAction) { $0.someField = expected }
  }
}
```

Run with:
```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode \
  -destination "platform=macOS" \
  -only-testing:supacodeTests/MyFeatureTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  -skipMacroValidation 2>&1 | tee /tmp/test.log | grep -E "Test case|TEST"
```

### Verify everything

1. `make build-app` succeeds.
2. Your new tests pass.
3. `xcodebuild test ... -only-testing:supacodeTests/BoardFeatureTests -only-testing:supacodeTests/NewTerminalFeatureTests` all pass (you didn't break the existing Supacool tests).
4. `make run-app` launches and the feature works when you exercise it by hand.

## Commit hygiene

- Commit in meaningful chunks per [CLAUDE.md](../../../CLAUDE.md) (the user's global preference).
- Commit message: one-line summary, then paragraph-ish body explaining WHY, not just WHAT.
- End with `Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>`.
- Don't `git add .` — add specific paths. Protects against accidentally committing secrets, `.env`, or leftover debug artifacts.
- Push with `git push origin supacool`. Never commit to `main`.

## Before handing back to Comandante

1. Summarize what you changed, including the commit SHA.
2. Describe what to look for when they live-drive it.
3. List anything that's NOT done (follow-ups, known issues).
