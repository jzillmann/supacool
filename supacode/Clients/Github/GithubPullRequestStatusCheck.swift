import Foundation

nonisolated struct GithubPullRequestStatusCheck: Decodable, Equatable, Hashable {
  let name: String?
  let detailsUrl: String?
  let status: String?
  let conclusion: String?
  let state: String?
  /// `CheckRun.workflowName` — nil for legacy StatusContext entries. Part of
  /// the identity used to collapse superseded runs (see `latestRunPerCheck`):
  /// two workflows may legitimately publish a same-named job.
  let workflowName: String?
  /// Raw ISO-8601 timestamps as GitHub reports them (`startedAt`/`completedAt`
  /// on a CheckRun, `createdAt` on a StatusContext). Deliberately kept as
  /// strings rather than `Date`: every call site builds its own `JSONDecoder`,
  /// and only some set `.dateDecodingStrategy = .iso8601` — decoding a Date
  /// here would throw on the others and take the whole rollup down with it.
  let startedAt: String?
  let completedAt: String?
  let createdAt: String?

  init(
    name: String? = nil,
    detailsUrl: String? = nil,
    status: String? = nil,
    conclusion: String? = nil,
    state: String? = nil,
    workflowName: String? = nil,
    startedAt: String? = nil,
    completedAt: String? = nil,
    createdAt: String? = nil
  ) {
    self.name = name
    self.detailsUrl = detailsUrl
    self.status = status
    self.conclusion = conclusion
    self.state = state
    self.workflowName = workflowName
    self.startedAt = startedAt
    self.completedAt = completedAt
    self.createdAt = createdAt
  }

  enum CodingKeys: String, CodingKey {
    case name
    case context
    case detailsUrl
    case targetUrl
    case status
    case conclusion
    case state
    case workflowName
    case startedAt
    case completedAt
    case createdAt
  }

  nonisolated init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let name = try container.decodeIfPresent(String.self, forKey: .name)
    let context = try container.decodeIfPresent(String.self, forKey: .context)
    self.name = name ?? context
    let detailsUrl = try container.decodeIfPresent(String.self, forKey: .detailsUrl)
    let targetUrl = try container.decodeIfPresent(String.self, forKey: .targetUrl)
    self.detailsUrl = detailsUrl ?? targetUrl
    self.status = try container.decodeIfPresent(String.self, forKey: .status)
    self.conclusion = try container.decodeIfPresent(String.self, forKey: .conclusion)
    self.state = try container.decodeIfPresent(String.self, forKey: .state)
    self.workflowName = try container.decodeIfPresent(String.self, forKey: .workflowName)
    self.startedAt = try container.decodeIfPresent(String.self, forKey: .startedAt)
    self.completedAt = try container.decodeIfPresent(String.self, forKey: .completedAt)
    self.createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
  }

  /// When this run last reported, used to pick the newest of several runs of
  /// the same check. Comparison is lexicographic on the raw string, which is
  /// chronological for GitHub's fixed `2026-07-29T00:44:35Z` shape — no date
  /// parsing, no locale, no decoder-strategy coupling.
  var reportedAt: String? {
    completedAt ?? startedAt ?? createdAt
  }

  /// Identity of the *check*, as opposed to this particular run of it.
  var runIdentity: RunIdentity {
    RunIdentity(workflowName: workflowName, name: displayName)
  }

  nonisolated struct RunIdentity: Equatable, Hashable {
    let workflowName: String?
    let name: String
  }

  var checkState: GithubPullRequestCheckState {
    if let status, status.uppercased() != "COMPLETED" {
      return .inProgress
    }
    if let state {
      switch state.uppercased() {
      case "SUCCESS":
        return .success
      case "FAILURE", "ERROR":
        return .failure
      case "EXPECTED":
        return .expected
      case "PENDING":
        return .inProgress
      default:
        return .inProgress
      }
    }
    if let conclusion {
      switch conclusion.uppercased() {
      case "SUCCESS", "NEUTRAL":
        return .success
      case "CANCELLED", "SKIPPED":
        return .skipped
      case "FAILURE", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE":
        return .failure
      default:
        return .inProgress
      }
    }
    return .inProgress
  }

  var displayName: String {
    name ?? "Check"
  }
}

extension [GithubPullRequestStatusCheck] {
  /// The rollup with superseded runs dropped — one entry per check, newest run wins.
  ///
  /// GitHub's status-check rollup lists **every** check run attached to the head
  /// commit, including runs a later re-run replaced. Re-run a red build green and
  /// the failing run stays in the payload forever, so counting the array reports
  /// failures on a PR that GitHub's own UI (which collapses to the latest run per
  /// check) shows as green — and that the user then merges. Seen on
  /// `centrumai/centrum_backend#4811`: 38 entries for 19 checks, two of them a
  /// dead run's `FAILURE`, which the board rendered as a red "2 checks failed"
  /// pill 65 seconds before the PR merged.
  ///
  /// Identity is `(workflowName, name)` rather than name alone so two workflows
  /// publishing a same-named job stay distinct. Ties and undated entries fall
  /// back to array order — GitHub returns runs roughly oldest-first, so last
  /// seen wins. Each surviving check keeps its first-seen position, which is
  /// what the popover's display ordering builds on.
  nonisolated var latestRunPerCheck: [GithubPullRequestStatusCheck] {
    var winners: [GithubPullRequestStatusCheck.RunIdentity: GithubPullRequestStatusCheck] = [:]
    var order: [GithubPullRequestStatusCheck.RunIdentity] = []
    for check in self {
      let identity = check.runIdentity
      guard let incumbent = winners[identity] else {
        winners[identity] = check
        order.append(identity)
        continue
      }
      if check.supersedes(incumbent) {
        winners[identity] = check
      }
    }
    return order.compactMap { winners[$0] }
  }
}

extension GithubPullRequestStatusCheck {
  /// Whether `self` — encountered later in the rollup than `incumbent` — is the
  /// more recent run of the same check. An undated entry never displaces a dated
  /// one; with no timestamps on either side, later-in-the-array wins.
  nonisolated func supersedes(_ incumbent: GithubPullRequestStatusCheck) -> Bool {
    switch (reportedAt, incumbent.reportedAt) {
    case (let mine?, let theirs?): return mine >= theirs
    case (nil, .some): return false
    case (.some, nil): return true
    case (nil, nil): return true
    }
  }
}

nonisolated struct GithubPullRequestStatusCheckRollup: Decodable, Equatable, Hashable {
  let checks: [GithubPullRequestStatusCheck]

  init(checks: [GithubPullRequestStatusCheck]) {
    self.checks = checks
  }

  /// Decoded rollups are deduped here, at the boundary, so every consumer —
  /// breakdown counts, `BoardPullRequestChecks`, `PRBallState`, the Pulse
  /// popover rows, auto-resume — sees the same one-run-per-check list.
  init(from decoder: Decoder) throws {
    if let checks = try? [GithubPullRequestStatusCheck](from: decoder) {
      self.checks = checks.latestRunPerCheck
      return
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let checks = try? container.decode([GithubPullRequestStatusCheck].self, forKey: .contexts) {
      self.checks = checks.latestRunPerCheck
      return
    }
    if let contexts = try? container.decode(GithubPullRequestStatusCheckContexts.self, forKey: .contexts) {
      self.checks = contexts.nodes.latestRunPerCheck
      return
    }
    self.checks = []
  }

  private enum CodingKeys: String, CodingKey {
    case contexts
  }
}

nonisolated private struct GithubPullRequestStatusCheckContexts: Decodable, Equatable {
  let nodes: [GithubPullRequestStatusCheck]
}

nonisolated struct PullRequestCheckBreakdown: Equatable {
  let passed: Int
  let failed: Int
  let inProgress: Int
  let expected: Int
  let skipped: Int

  var total: Int {
    passed + failed + inProgress + expected + skipped
  }

  var summaryText: String {
    var parts: [String] = []
    if failed > 0 {
      parts.append("\(failed) failed")
    }
    if inProgress > 0 {
      parts.append("\(inProgress) in progress")
    }
    if skipped > 0 {
      parts.append("\(skipped) skipped")
    }
    if expected > 0 {
      parts.append("\(expected) expected")
    }
    if total > 0 {
      parts.append("\(passed) successful")
    }
    if parts.isEmpty {
      return ""
    }
    return parts.joined(separator: ", ")
  }

  init(checks: [GithubPullRequestStatusCheck]) {
    var passed = 0
    var failed = 0
    var inProgress = 0
    var expected = 0
    var skipped = 0
    for check in checks {
      switch check.checkState {
      case .success:
        passed += 1
      case .failure:
        failed += 1
      case .inProgress:
        inProgress += 1
      case .expected:
        expected += 1
      case .skipped:
        skipped += 1
      }
    }
    self.passed = passed
    self.failed = failed
    self.inProgress = inProgress
    self.expected = expected
    self.skipped = skipped
  }
}
