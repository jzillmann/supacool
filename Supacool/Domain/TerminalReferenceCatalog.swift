import Foundation
import Sharing

/// What Supacool knows about the tickets and PRs that terminal text can
/// mention, flattened for the terminal layer.
///
/// The board owns the data (Linear fetches, PR snapshots, PR Pulse) and
/// publishes this value through `@Shared(.terminalReferenceCatalog)`. The
/// terminal layer reads it for three things: which `repo#N` names are worth
/// matching, the `link-color` rules that tint ticket ids and PR refs by state
/// (`TerminalLinkRules.colorConfigLines`), and the hover card shown while
/// ⌘-hovering a link (`TerminalReferenceHoverCard`).
nonisolated struct TerminalReferenceCatalog: Equatable, Sendable {
  /// `owner/repo` slugs of GitHub repos the board knows. Only these can be
  /// written as a bare `repo#123` — anything else needs the owner.
  var repositorySlugs: [String] = []
  /// Keyed by ticket identifier, e.g. `CEN-1234`.
  var tickets: [String: Ticket] = [:]
  /// Keyed by `PullRequest.key` (`owner/repo#123`, lowercased owner/repo).
  var pullRequests: [String: PullRequest] = [:]

  static let empty = TerminalReferenceCatalog()

  /// A color bucket. The terminal layer resolves it to a concrete color,
  /// so the domain stays free of AppKit.
  nonisolated enum Tone: String, CaseIterable, Equatable, Sendable {
    case green, yellow, orange, red, purple, blue, gray
  }

  nonisolated struct Ticket: Equatable, Sendable {
    var identifier: String
    var title: String?
    var stateName: String?
    /// Linear's state category: `triage`/`backlog`/`unstarted`/`started`/
    /// `completed`/`canceled`.
    var stateType: String?
    /// Linear's own hex color for the workflow state, e.g. `#f2c94c`.
    var stateColor: String?
    var assigneeName: String?

    /// The hex color the ticket id is drawn in, or nil to leave it alone.
    /// Linear's own state color wins, so the terminal matches what you see
    /// in Linear. Not-yet-started states stay uncolored: Linear draws them
    /// in light grays that vanish on a light terminal background.
    var colorHex: String? {
      switch stateType {
      case "triage", "backlog", "unstarted", nil: return nil
      default: break
      }
      if let stateColor, Self.isHexColor(stateColor) { return stateColor.lowercased() }
      return nil
    }

    /// Fallback when Linear sent no usable color.
    var fallbackTone: Tone? {
      switch stateType {
      case "started": return .yellow
      case "completed": return .purple
      case "canceled": return .gray
      default: return nil
      }
    }

    static func isHexColor(_ raw: String) -> Bool {
      raw.wholeMatch(of: /#[0-9a-fA-F]{6}/) != nil
    }
  }

  nonisolated struct PullRequest: Equatable, Sendable {
    var owner: String
    var repo: String
    var number: Int
    var title: String?
    var tone: Tone?
    /// Short state, e.g. `Ready to merge` or `2 checks failed`.
    var statusLabel: String
    /// Extra facts for the hover card, e.g. `checks passed · Greptile 5/5`.
    var detail: String?

    var key: String { Self.key(owner: owner, repo: repo, number: number) }

    static func key(owner: String, repo: String, number: Int) -> String {
      "\(owner.lowercased())/\(repo.lowercased())#\(number)"
    }
  }
}

// MARK: - Building from board state

extension TerminalReferenceCatalog {
  /// Assemble the catalog from what the board already tracks. Pure, so the
  /// board can recompute it on every change and tests can pin the mapping.
  ///
  /// PR data comes from three places, best first: the per-PR snapshot
  /// (`gh pr view`), PR Pulse's repo-wide snapshot, and finally the state
  /// cached on the session reference itself — enough to color a merged PR
  /// after a relaunch, before any fetch ran.
  static func build(
    sessions: [AgentSession],
    referenceSnapshots: [String: PullRequestSnapshot],
    pulseSnapshots: [String: RepoPullRequestSnapshot],
    linearIssues: [String: LinearIssue]
  ) -> TerminalReferenceCatalog {
    var catalog = TerminalReferenceCatalog()
    var slugs = Set<String>()
    var snapshotsByKey: [String: SnapshotEntry] = [:]

    for repo in pulseSnapshots.values {
      guard let coordinates = PRPulseReference.coordinates(slug: repo.slug) else { continue }
      slugs.insert("\(coordinates.owner)/\(coordinates.repo)")
      for pullRequest in repo.pullRequests {
        let key = PullRequest.key(owner: coordinates.owner, repo: coordinates.repo, number: pullRequest.number)
        snapshotsByKey[key] = SnapshotEntry(
          owner: coordinates.owner,
          repo: coordinates.repo,
          number: pullRequest.number,
          snapshot: pullRequest.referenceSnapshot
        )
      }
    }

    for session in sessions {
      for reference in session.references {
        guard case .pullRequest(let owner, let repo, let number, let state, let title) = reference else {
          continue
        }
        slugs.insert("\(owner)/\(repo)")
        let key = PullRequest.key(owner: owner, repo: repo, number: number)
        if let snapshot = referenceSnapshots[reference.dedupeKey] {
          snapshotsByKey[key] = SnapshotEntry(owner: owner, repo: repo, number: number, snapshot: snapshot)
        } else if snapshotsByKey[key] == nil, catalog.pullRequests[key] == nil, let state {
          catalog.pullRequests[key] = PullRequest(
            owner: owner,
            repo: repo,
            number: number,
            title: title,
            tone: tone(for: state),
            statusLabel: label(for: state),
            detail: nil
          )
        }
      }
    }

    for (key, entry) in snapshotsByKey {
      let ball = PRBallState(snapshot: entry.snapshot)
      let suffix = entry.snapshot.statusHelpSuffix
      let detail = suffix.hasPrefix(" · ") ? String(suffix.dropFirst(3)) : suffix
      catalog.pullRequests[key] = PullRequest(
        owner: entry.owner,
        repo: entry.repo,
        number: entry.number,
        title: entry.snapshot.title,
        tone: tone(for: ball),
        statusLabel: label(for: ball),
        detail: detail.isEmpty ? nil : detail
      )
    }

    for issue in linearIssues.values {
      catalog.tickets[issue.identifier] = Ticket(
        identifier: issue.identifier,
        title: issue.title,
        stateName: issue.stateName,
        stateType: issue.stateType,
        stateColor: issue.stateColor,
        assigneeName: issue.assigneeName
      )
    }

    catalog.repositorySlugs = slugs.sorted()
    return catalog
  }

  private struct SnapshotEntry {
    var owner: String
    var repo: String
    var number: Int
    var snapshot: PullRequestSnapshot
  }

  static func tone(for ball: PRBallState) -> Tone {
    switch ball {
    case .readyToMerge: return .green
    case .ciFailed, .mergeConflict: return .red
    case .changesRequested, .greptileLow: return .orange
    case .ciRunning: return .yellow
    case .awaitingReview: return .blue
    case .draft, .closedUnmerged: return .gray
    case .merged: return .purple
    }
  }

  static func label(for ball: PRBallState) -> String {
    switch ball {
    case .ciRunning: return "Checks running"
    case .awaitingReview: return "Awaiting review"
    case .merged: return "Merged"
    default: return ball.reasonLabel ?? "Open"
    }
  }

  /// Without a snapshot only the coarse state is known. An open PR stays
  /// uncolored: green or red would be a guess.
  static func tone(for state: PRState) -> Tone? {
    switch state {
    case .merged: return .purple
    case .closed, .draft: return .gray
    case .open: return nil
    }
  }

  static func label(for state: PRState) -> String {
    switch state {
    case .merged: return "Merged"
    case .closed: return "Closed"
    case .draft: return "Draft"
    case .open: return "Open"
    }
  }
}

// MARK: - Hover lookup

extension TerminalReferenceCatalog {
  nonisolated enum Entry: Equatable, Sendable {
    case ticket(Ticket)
    case pullRequest(PullRequest)
  }

  /// The catalog entry for the link text ghostty reports under the mouse:
  /// a ticket id, `owner/repo#123`, `repo#123`, or a GitHub PR URL. Nil
  /// when the text is none of those, or the board knows nothing about it.
  func entry(forLinkText text: String) -> Entry? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let ticket = tickets[trimmed] { return .ticket(ticket) }
    if let url = trimmed.wholeMatch(of: /https?:\/\/github\.com\/([^\/\s]+)\/([^\/\s]+)\/pull\/(\d+)(?:[\/?#].*)?/),
      let number = Int(url.output.3)
    {
      let key = PullRequest.key(owner: String(url.output.1), repo: String(url.output.2), number: number)
      return pullRequests[key].map(Entry.pullRequest)
    }
    guard
      let reference = TerminalLinkRules.pullRequestReference(in: trimmed, repositorySlugs: repositorySlugs)
    else { return nil }
    let key = PullRequest.key(owner: reference.owner, repo: reference.repo, number: reference.number)
    return pullRequests[key].map(Entry.pullRequest)
  }
}

// MARK: - Shared key

nonisolated extension SharedReaderKey
where Self == InMemoryKey<TerminalReferenceCatalog>.Default {
  /// Written by `BoardFeature`, read by the terminal layer. In memory only:
  /// it is a cache the board rebuilds from its own state on every launch.
  static var terminalReferenceCatalog: Self {
    Self[.inMemory("terminalReferenceCatalog"), default: .empty]
  }
}
