import Foundation

/// Utilities for writing repo-relative paths into `.gitignore`.
nonisolated enum GitignorePattern {
  /// Returns a repo-root-anchored pattern for a porcelain-status path.
  ///
  /// Examples:
  /// - `tmp/log.txt` → `/tmp/log.txt`
  /// - `scratch dir/file?.json` → `/scratch\ dir/file\?.json`
  static func repoRootAnchoredPattern(for path: String) -> String {
    "/" + escape(path)
  }

  private static func escape(_ path: String) -> String {
    var result = ""
    for character in path {
      switch character {
      case "\\", " ", "#", "!", "*", "?", "[":
        result.append("\\")
        result.append(character)
      default:
        result.append(character)
      }
    }
    return result
  }
}
