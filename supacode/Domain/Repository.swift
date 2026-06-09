import Foundation
import IdentifiedCollections

struct Repository: Identifiable, Hashable, Sendable {
  let id: String
  let rootURL: URL
  let name: String
  let worktrees: IdentifiedArrayOf<Worktree>

  var initials: String {
    Self.initials(from: name)
  }

  /// Directory to use for project-scoped skill / slash-command discovery.
  ///
  /// `rootURL` is not always a working checkout: for bare git-wt repos it is a
  /// container that holds the worktrees and has no `.claude/` of its own, so
  /// project skills (e.g. a `.claude/skills -> .agent-os/skills` symlink) live
  /// inside each checkout. Discovering against `rootURL` there finds nothing.
  /// Prefer the primary checkout when it coincides with `rootURL`, otherwise
  /// fall back to any worktree's working directory.
  var skillDiscoveryRoot: URL {
    let standardizedRoot = rootURL.standardizedFileURL
    if worktrees.contains(where: { $0.workingDirectory.standardizedFileURL == standardizedRoot }) {
      return rootURL
    }
    return worktrees.first?.workingDirectory ?? rootURL
  }

  static func name(for rootURL: URL) -> String {
    let name = rootURL.lastPathComponent
    if name == ".bare" || name == ".git" {
      let parentName = rootURL.deletingLastPathComponent().lastPathComponent
      if !parentName.isEmpty, parentName != "/" {
        return parentName
      }
    }
    if name.isEmpty {
      return rootURL.path(percentEncoded: false)
    }
    return name
  }

  static func initials(from name: String) -> String {
    var parts: [String] = []
    var current = ""
    for character in name {
      if character.isLetter || character.isNumber {
        current.append(character)
      } else if !current.isEmpty {
        parts.append(current)
        current = ""
      }
    }
    if !current.isEmpty {
      parts.append(current)
    }
    let initials: String
    if parts.count >= 2 {
      let first = parts[0].prefix(1)
      let second = parts[1].prefix(1)
      initials = String(first + second)
    } else if let part = parts.first {
      initials = String(part.prefix(2))
    } else {
      initials = String(name.prefix(2))
    }
    return initials.uppercased()
  }
}
