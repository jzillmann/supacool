# Swift 6 gotchas (as hit in Supacool)

Supacode's Xcode project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. Everything in the module is `@MainActor`-isolated by default unless opted out. That plus strict concurrency creates a few traps.

## 1. `nonisolated enum` for Picker selection types

**Symptom**:
```
main actor-isolated conformance of 'MyEnum' to 'Equatable'
cannot satisfy conformance requirement for a 'Sendable' type parameter
```

When SwiftUI's `Picker(selection: $store.mode)` binds to an enum, that enum's `Equatable`/`Hashable` conformance must be `Sendable`. Under global `@MainActor`, the synthesized conformance is actor-isolated, which doesn't satisfy `Sendable`.

**Fix**: mark the enum `nonisolated` at the type declaration:

```swift
nonisolated enum WorkspaceMode: String, CaseIterable, Equatable, Sendable {
  case directory
  case newWorktree
  case existingWorktree
}
```

Follow supacode's established pattern — examples already exist at `supacode/Features/Settings/Models/PullRequestMergeStrategy.swift` and `MergedWorktreeAction.swift`.

## 2. `@Dependency(Type.self)` over `@Dependency(\.keyPath)`

**Symptom** (inside a `.run { send in … }` effect):
```
type 'WritableKeyPath<DependencyValues, X>' does not conform to the 'Sendable' protocol
```

TCA key-path dependencies can be non-Sendable under strict concurrency. The type-based form always works.

**Fix**:
```swift
// ❌ breaks in .run closures
@Dependency(\.gitClient) var gitClient

// ✅ always Sendable-safe
@Dependency(GitClientDependency.self) var gitClient
@Dependency(TerminalClient.self) var terminalClient
```

Supacode's reducers (e.g. `RepositoriesFeature`) already use the type-based form consistently. Match that.

## 3. Crossing `@MainActor` boundaries in `.run`

**Symptom**:
```
main actor-isolated conformance of 'Worktree' to 'Identifiable' cannot be used in nonisolated context
```

TCA `.run { send in ... }` operations are nonisolated by default. When you touch `IdentifiedArrayOf<T>` where `T`'s `Identifiable` conformance is MainActor-isolated, it fails.

**Fix**: wrap the MainActor-dependent read in an explicit `MainActor.run`:

```swift
return .run { send in
  let worktree: Worktree = await MainActor.run {
    let rootURL = repository.rootURL.standardizedFileURL
    return repository.worktrees.first(where: { $0.workingDirectory == rootURL })
      ?? Worktree(id: ..., name: ..., ...)
  }
  // Now use `worktree` in nonisolated context: it's just a value.
  await terminalClient.send(.createTabWithInput(worktree, input: ..., id: ...))
}
```

Pattern: do the MainActor-coupled lookup up front, capture the resulting plain value, then continue the async work without crossing the boundary again.

## 4. `@Observable` classes need `@MainActor`

Supacode convention (from `AGENTS.md`): "Always mark `@Observable` classes with `@MainActor`." `WorktreeTerminalManager` and `WorktreeTerminalState` both follow this. When adding a new `@Observable` class, keep the pattern — otherwise you'll fight isolation warnings every time a view reads it.

## 5. `@ObservationIgnored @Shared(...)` inside `@Observable`

When an `@Observable` class needs a `@Shared(...)` property, mark it `@ObservationIgnored`. Otherwise the Observable macro tries to track it and conflicts with `@Shared`'s own tracking.

Example from `WorktreeTerminalManager.swift` (after Supacool added session-id capture):

```swift
@MainActor
@Observable
final class WorktreeTerminalManager {
  @ObservationIgnored
  @Shared(.agentSessions) private var agentSessions: [AgentSession]
  // ...
}
```

## 6. `@FocusState` vs `NSViewRepresentable`

`@FocusState` + `.focused($binding)` only works on native SwiftUI text inputs (`TextField`, `TextEditor`). If you switch to an `NSViewRepresentable` (like `PlainTextEditor` or Supacool's `PromptTextEditor`), `@FocusState` doesn't apply. Implement auto-focus manually via:

```swift
DispatchQueue.main.async { [weak textView] in
  textView?.window?.makeFirstResponder(textView)
}
```

…inside `makeNSView`. See `Supacool/Features/Board/Views/PromptTextEditor.swift` for the full example.

## 7. `decodeIfPresent ?? default` (see [persistence.md](./persistence.md))

Not strictly a Swift 6 issue, but in the same family of "the compiler won't catch you, but your users will." All persisted Codable types need manual decoders.

---

If you hit an isolation error not listed here, the first debugging moves that usually work:

1. **Add `nonisolated` to the smallest thing that compiles it** — a single method, or a whole type declaration. Don't sprinkle `@MainActor` everywhere.
2. **Wrap MainActor-coupled reads in `MainActor.run { }` inside `.run` effects.**
3. **Use type-based `@Dependency(X.self)` when a key-path gives you Sendable errors.**
4. **Check supacode itself for the pattern** — there's a 99% chance upstream already has a working example.
