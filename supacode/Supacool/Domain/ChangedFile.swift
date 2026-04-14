import Foundation

/// A single file with uncommitted changes — the row model for the quick-
/// diff sheet's left column. Populated from `git status --porcelain=v1 -z`.
nonisolated struct ChangedFile: Identifiable, Hashable, Sendable {
  /// Repo-relative path. Serves as the stable id.
  let path: String
  let status: ChangeStatus
  /// Added line count from `git diff HEAD --numstat`. `nil` for binary
  /// or untracked (untracked files emit no numstat entry).
  var linesAdded: Int?
  var linesRemoved: Int?

  var id: String { path }
}

nonisolated enum ChangeStatus: Hashable, Sendable {
  case added
  case modified
  case deleted
  case renamed
  case copied
  case untracked
  case typeChanged
  case unknown(String)

  /// Parses a single-character porcelain status code from
  /// `git status --porcelain=v1`. The index/worktree codes overlap;
  /// we prefer the worktree code when both carry meaning so the dialog
  /// reflects what `git diff` would show.
  static func fromPorcelain(index: Character, worktree: Character) -> ChangeStatus {
    // Untracked gets a distinct "??" marker.
    if index == "?" && worktree == "?" { return .untracked }
    // Worktree (unstaged) changes win when present; otherwise fall back
    // to the index (staged) code.
    let primary = worktree == " " ? index : worktree
    switch primary {
    case "A": return .added
    case "M": return .modified
    case "D": return .deleted
    case "R": return .renamed
    case "C": return .copied
    case "T": return .typeChanged
    default: return .unknown(String(primary))
    }
  }

  var shortLabel: String {
    switch self {
    case .added: "A"
    case .modified: "M"
    case .deleted: "D"
    case .renamed: "R"
    case .copied: "C"
    case .untracked: "?"
    case .typeChanged: "T"
    case .unknown(let code): code
    }
  }

  var systemImage: String {
    switch self {
    case .added: "plus.circle"
    case .modified: "pencil.circle"
    case .deleted: "minus.circle"
    case .renamed: "arrow.turn.up.right.circle"
    case .copied: "doc.on.doc"
    case .untracked: "questionmark.diamond"
    case .typeChanged: "arrow.triangle.2.circlepath"
    case .unknown: "questionmark.circle"
    }
  }
}

/// Splits `git status --porcelain=v1 -z` output into `ChangedFile`s.
/// Porcelain-v1 format per entry: `XY <path>\0` where `XY` is the two
/// status chars followed by a space. Renames/copies carry an extra
/// `\0<old-path>` after the new path; we skip the old path.
enum PorcelainStatusParser {
  static func parse(_ output: String) -> [ChangedFile] {
    guard !output.isEmpty else { return [] }
    let entries = output.split(separator: "\0", omittingEmptySubsequences: true)
    var result: [ChangedFile] = []
    var index = entries.startIndex
    while index < entries.endIndex {
      let entry = String(entries[index])
      index = entries.index(after: index)
      guard entry.count >= 4 else { continue }
      let chars = Array(entry)
      let statusX = chars[0]
      let statusY = chars[1]
      // Skip the single space separator at position 2.
      let path = String(chars[3...])
      let status = ChangeStatus.fromPorcelain(index: statusX, worktree: statusY)
      result.append(ChangedFile(path: path, status: status))
      // Rename/copy entries are followed by the *old* path — consume it.
      if status == .renamed || status == .copied, index < entries.endIndex {
        index = entries.index(after: index)
      }
    }
    return result
  }
}
