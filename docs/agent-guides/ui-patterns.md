# UI patterns (things that surprised me)

## Toolbar: ordering, grouping, and the double-pill trap

macOS `.toolbar { }` items with the same `placement` cluster together visually — they render as a single pill. When you want TWO visually distinct items next to each other on the leading side, insert a `ToolbarSpacer(.fixed)` between them:

```swift
.toolbar {
  ToolbarItem(placement: .navigation) {
    Text("Supacool").font(.headline)
  }
  ToolbarSpacer(.fixed)                  // ← without this, the two merge into one pill
  ToolbarItem(placement: .navigation) {
    RepoPickerButton(...)
  }
  ToolbarSpacer(.flexible)               // ← pushes .primaryAction items to the far right
  ToolbarItem(placement: .primaryAction) {
    Button { ... } label: { Label("New Terminal", systemImage: "plus") }
  }
}
```

`.flexible` = expands to fill available space. `.fixed` = small gap. Use `.flexible` between leading-cluster and trailing-cluster; `.fixed` inside a cluster when you want visual separation but small spacing.

**Don't** add your own `Capsule().background(...)` chrome to button labels inside toolbar items. macOS already wraps them in a pill. Double pills look bad — supacool hit this once (commit `eec89bd`, "stop that nonsense").

```swift
// ❌ double pill
Button { ... } label: {
  HStack { ... }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(Color.secondary.opacity(0.12))
    .clipShape(Capsule())
}
.buttonStyle(.plain)

// ✅ let the toolbar be the pill
Button { ... } label: {
  HStack { ... }  // no padding/background/clipShape
}
```

## Hiding the window title

By default macOS renders the `Window("Supacool", id: ...)` title string above or inline with the toolbar. If you want to substitute your own title item (or just remove it):

```swift
.toolbar(removing: .title)
```

The title string still drives the menu-bar name, the Window menu, and Spotlight. It's just invisible in the chrome.

## Pointer cursor on card hover

Use the `NSCursor.pointingHand.push() / .pop()` pattern supacode already uses (see `GhosttySurfaceSearchOverlay.swift`, `TerminalSplitTreeView.swift`):

```swift
.onHover { hovering in
  if hovering { NSCursor.pointingHand.push() }
  else { NSCursor.pop() }
}
```

Don't use `.pointerStyle(.link)` — it's macOS 15+ only and Supacool's deployment target (macOS 26) supports it but the `push/pop` pattern matches upstream conventions.

## Multi-line text input

Native `TextEditor` has unspecified-and-sometimes-changing internal insets (`textContainerInset` on the underlying `NSTextView`), which makes it hard to align a placeholder with the cursor in a `ZStack`. Supacool's solution: a custom `NSViewRepresentable` called **`PromptTextEditor`** (see `supacode/Supacool/Features/Board/Views/PromptTextEditor.swift`) with:

- **Known** inset exposed as `PromptTextEditor.inset = NSSize(width: 5, height: 6)`.
- Auto-focus on appear via `textView.window?.makeFirstResponder(textView)` scheduled to `DispatchQueue.main.async` so the view is attached to a window when the call fires.
- Same `drawsBackground = false`, `isRichText = false`, substitutions off setup as supacode's `PlainTextEditor`.

Placeholder usage:

```swift
ZStack(alignment: .topLeading) {
  PromptTextEditor(text: $store.prompt, autoFocus: true)
    .frame(minHeight: 100, maxHeight: 220)
  if store.prompt.isEmpty {
    Text("Describe what the agent should do…")
      .foregroundStyle(.tertiary)
      .padding(.leading, PromptTextEditor.inset.width)   // 5
      .padding(.top, PromptTextEditor.inset.height)       // 6
      .allowsHitTesting(false)
  }
}
.background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor).opacity(0.4)))
.overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1))
```

If you change the inset, the placeholder picks up the new value automatically.

## App-name in the macOS menu bar

The macOS menu bar shows `CFBundleName`. When `PRODUCT_NAME = "$(TARGET_NAME)"` and the target is named `supacode`, `CFBundleName` is synthesized as `supacode` — **even if your `Info.plist` explicitly sets `CFBundleName = Supacool`**. The Info.plist value loses.

Fix: set `PRODUCT_NAME = Supacool` literally in the main target's build config. The synthesized `CFBundleName` now reads `Supacool`. Also set `INFOPLIST_KEY_CFBundleDisplayName = Supacool` + `INFOPLIST_KEY_CFBundleName = Supacool` as belt-and-braces. Side effect: the bundle filename goes from `supacode.app` to `Supacool.app` — the Makefile reads `FULL_PRODUCT_NAME` dynamically so it adapts.

## Empty-state dead-ends

When a primary action's precondition isn't met, offer the setup action inline:

```swift
if repositories.isEmpty {
  Text("No repositories yet")
  Button("Add Repository") { onAddRepository() }
    .keyboardShortcut("o", modifiers: .command)
} else if sessions.isEmpty {
  Text("No terminals yet")
  Text("Press ⌘N to create a new terminal.")
}
```

Pattern: the empty state tells the user what to do AND gives them the one-click button to do it. Don't leave them at "Press ⌘N" when ⌘N is disabled because they haven't registered a repo.

## Don't auto-focus destructive state transitions

When `BoardFeature.createSession` creates a new card, it does **not** set `state.focusedSessionID` — the user stays on the board and sees the card appear. Rationale: creating a terminal is fire-and-forget (you already committed to the prompt in the sheet); forcing the user into the full-screen terminal disorients them if they were going to check on another session next. Mirror this pattern for any future "creation" actions.

Resume-session DOES focus, because reclaiming an old session implies you want to see it immediately.

## When you need the `Worktree` object but only have a `session`

`FullScreenTerminalView.resolveWorktree()` is the pattern: look up `repository.worktrees` first, fall back to synthesizing a `Worktree(id: sessionID, workingDirectory: URL(...))` if missing. The terminal manager keys state by `id` (which is the path), so a synthesized Worktree with the right id works identically to a "real" one. Copy this when a view gets a session and needs to pass a Worktree to something deeper.
