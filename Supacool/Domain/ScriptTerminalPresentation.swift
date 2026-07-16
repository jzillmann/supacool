import Foundation

/// A blocking archive/delete/run script's terminal tab, surfaced over the
/// board so the user can read the script's output.
///
/// `runBlockingScript` creates these tabs on the worktree's shared terminal
/// state, but no session card points at them — and a card is the board's
/// only other route to a terminal. Hence this separate presentation.
///
/// Not persisted: a script tab dies with the app, so a restored
/// presentation would only ever render "Terminal no longer running".
///
/// Not `nonisolated`: `Worktree` and `TerminalTabID` are main-actor
/// isolated, so a nonisolated wrapper can't use their `Equatable`
/// conformances.
struct ScriptTerminalPresentation: Equatable, Identifiable {
  /// May be a shim — enough for the terminal manager, which keys its
  /// states by `worktree.id`.
  let worktree: Worktree
  let tabID: TerminalTabID
  /// Rendered in the sheet header, e.g. "Delete Script".
  let title: String

  var id: UUID { tabID.rawValue }
}
