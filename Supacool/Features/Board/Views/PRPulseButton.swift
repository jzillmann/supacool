import AppKit
import ComposableArchitecture
import SwiftUI

/// Toolbar badge summarizing open PRs assigned to the authenticated GitHub
/// user across the board's (filtered) repositories: total count plus green /
/// red / pending breakdown. Expands into a popover listing each PR with its
/// CI state, review decision, and Greptile confidence score; clicking a row
/// opens the PR on GitHub.
///
/// Data comes from `BoardFeature`'s PR Pulse snapshots (`gh pr list` per
/// repo on a 3-minute tick). Hidden until at least one filtered repo has a
/// snapshot with a GitHub remote.
struct PRPulseButton: View {
  let store: StoreOf<BoardFeature>
  let repositories: IdentifiedArrayOf<Repository>

  @State private var isPresented: Bool = false

  /// Rows whose per-check breakdown is expanded, keyed by
  /// "repositoryID#prNumber" so numbers can't collide across repos.
  /// View-local: collapses again when the popover closes and the view
  /// is torn down.
  @State private var expandedCheckKeys: Set<String> = []

  var body: some View {
    if !visibleSnapshots.isEmpty {
      Button {
        isPresented.toggle()
      } label: {
        badgeLabel
      }
      .help(
        "Open pull requests assigned to you across board repos — green: CI passed & Greptile 5/5, "
          + "red: failing checks or score below 5/5. Click for details."
      )
      .popover(isPresented: $isPresented, arrowEdge: .bottom) {
        popoverContent
      }
    }
  }

  // MARK: - Aggregation

  /// Snapshots of repos that pass the board's repo filter, in the
  /// repository list's display order. Repos without a GitHub remote are
  /// skipped entirely.
  private var visibleSnapshots: [(repository: Repository, snapshot: RepoPullRequestSnapshot)] {
    repositories.compactMap { repository in
      guard store.filters.includes(repositoryID: repository.id) else { return nil }
      guard let snapshot = store.prPulseSnapshots[repository.id], snapshot.hasGithubRemote else {
        return nil
      }
      return (repository, snapshot)
    }
  }

  private var totalCount: Int { visibleSnapshots.reduce(0) { $0 + $1.snapshot.pullRequests.count } }
  private var greenCount: Int { visibleSnapshots.reduce(0) { $0 + $1.snapshot.greenCount } }
  private var redCount: Int { visibleSnapshots.reduce(0) { $0 + $1.snapshot.redCount } }
  private var pendingCount: Int { visibleSnapshots.reduce(0) { $0 + $1.snapshot.pendingCount } }

  // MARK: - Badge

  private var badgeLabel: some View {
    HStack(spacing: 6) {
      Image(systemName: "person.crop.circle.badge.checkmark")
        .accessibilityHidden(true)
      Text("\(totalCount)")
        .monospacedDigit()
      if greenCount > 0 {
        countDot(greenCount, color: .green)
      }
      if redCount > 0 {
        countDot(redCount, color: .red)
      }
      if pendingCount > 0 {
        countDot(pendingCount, color: .orange)
      }
    }
  }

  private func countDot(_ count: Int, color: Color) -> some View {
    HStack(spacing: 3) {
      Circle()
        .fill(color)
        .frame(width: 6, height: 6)
      Text("\(count)")
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
  }

  // MARK: - Popover

  private var popoverContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Pull Requests Assigned to Me")
          .font(.headline)
        Spacer()
        if !store.prPulseInFlight.isEmpty {
          ProgressView()
            .controlSize(.small)
        }
        Button {
          store.send(.prPulseRefreshRequested)
        } label: {
          Image(systemName: "arrow.clockwise")
            .accessibilityLabel("Refresh pull request status now")
        }
        .buttonStyle(.borderless)
        .help("Refresh pull request status now")
      }
      .padding(12)
      Divider()
      if totalCount == 0 {
        Text("No open pull requests assigned to you")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .center)
          .padding(24)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(visibleSnapshots, id: \.repository.id) { entry in
              if visibleSnapshots.count > 1 {
                repoHeader(entry.repository, snapshot: entry.snapshot)
              }
              ForEach(entry.snapshot.pullRequests) { pullRequest in
                let expansionKey = "\(entry.snapshot.repositoryID)#\(pullRequest.number)"
                pullRequestRow(pullRequest, expansionKey: expansionKey)
                if expandedCheckKeys.contains(expansionKey) {
                  checkDetailRows(pullRequest)
                }
              }
            }
          }
          .padding(8)
        }
        .frame(maxHeight: 440)
      }
    }
    .frame(width: 480)
  }

  private func repoHeader(_ repository: Repository, snapshot: RepoPullRequestSnapshot) -> some View {
    HStack(spacing: 6) {
      Text(repository.name)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      Text("\(snapshot.pullRequests.count)")
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.tertiary)
      Spacer()
    }
    .padding(.horizontal, 6)
    .padding(.top, 8)
    .padding(.bottom, 2)
  }

  private func pullRequestRow(_ pullRequest: MonitoredPullRequest, expansionKey: String) -> some View {
    HStack(spacing: 8) {
      Button {
        if let url = URL(string: pullRequest.url) {
          NSWorkspace.shared.open(url)
        }
      } label: {
        HStack(spacing: 8) {
          Circle()
            .fill(healthColor(pullRequest.health))
            .frame(width: 8, height: 8)
          Text("#\(pullRequest.number)")
            .monospacedDigit()
            .foregroundStyle(.secondary)
          if pullRequest.isDraft {
            Image(systemName: "pencil.circle")
              .foregroundStyle(.secondary)
              .accessibilityLabel("Draft")
              .help("Draft")
          }
          Text(pullRequest.title)
            .lineLimit(1)
            .truncationMode(.tail)
          Spacer(minLength: 12)
          reviewDecisionIcon(pullRequest)
          scoreChip(pullRequest.greptileScore)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .onHover { hovering in
        if hovering {
          NSCursor.pointingHand.push()
        } else {
          NSCursor.pop()
        }
      }
      .help(rowHelp(pullRequest))
      checksToggle(pullRequest, expansionKey: expansionKey)
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 4)
  }

  /// Trailing checks summary doubling as the expand/collapse toggle for
  /// the per-check breakdown. Hidden when the PR reports no checks.
  @ViewBuilder
  private func checksToggle(_ pullRequest: MonitoredPullRequest, expansionKey: String) -> some View {
    if !pullRequest.statusChecks.isEmpty {
      let isExpanded = expandedCheckKeys.contains(expansionKey)
      Button {
        withAnimation(.snappy(duration: 0.15)) {
          if isExpanded {
            expandedCheckKeys.remove(expansionKey)
          } else {
            expandedCheckKeys.insert(expansionKey)
          }
        }
      } label: {
        HStack(spacing: 3) {
          checksSummaryText(pullRequest)
          Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(isExpanded ? "Hide check details" : "Show check details")
    }
  }

  @ViewBuilder
  private func checksSummaryText(_ pullRequest: MonitoredPullRequest) -> some View {
    if pullRequest.checks.failed > 0 {
      Text("\(pullRequest.checks.failed) failed")
        .font(.caption)
        .foregroundStyle(.red)
    } else if pullRequest.checks.inProgress + pullRequest.checks.expected > 0 {
      Text("\(pullRequest.checks.inProgress + pullRequest.checks.expected) running")
        .font(.caption)
        .foregroundStyle(.orange)
    } else {
      Text("\(pullRequest.checks.total) checks")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  /// Expanded per-check breakdown: failures first, then running, then the
  /// rest. Checks with a details URL open their CI run on click.
  private func checkDetailRows(_ pullRequest: MonitoredPullRequest) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      ForEach(
        Array(pullRequest.statusChecksForDisplay.enumerated()),
        id: \.offset
      ) { _, check in
        checkRow(check)
      }
    }
    .padding(.leading, 28)
    .padding(.trailing, 6)
    .padding(.bottom, 4)
  }

  @ViewBuilder
  private func checkRow(_ check: GithubPullRequestStatusCheck) -> some View {
    let label = HStack(spacing: 6) {
      Image(systemName: checkStateSymbol(check.checkState))
        .font(.caption)
        .foregroundStyle(checkStateColor(check.checkState))
        .accessibilityHidden(true)
      Text(check.displayName)
        .font(.caption)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 8)
      if check.detailsUrl != nil {
        Image(systemName: "arrow.up.right")
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .accessibilityHidden(true)
      }
    }
    .contentShape(Rectangle())
    .padding(.vertical, 1)

    if let detailsUrl = check.detailsUrl, let url = URL(string: detailsUrl) {
      Button {
        NSWorkspace.shared.open(url)
      } label: {
        label
      }
      .buttonStyle(.plain)
      .onHover { hovering in
        if hovering {
          NSCursor.pointingHand.push()
        } else {
          NSCursor.pop()
        }
      }
      .help("Open this check's run")
    } else {
      label
    }
  }

  private func checkStateSymbol(_ state: GithubPullRequestCheckState) -> String {
    switch state {
    case .success: "checkmark.circle.fill"
    case .failure: "xmark.circle.fill"
    case .inProgress: "clock.fill"
    case .expected: "clock"
    case .skipped: "minus.circle"
    }
  }

  private func checkStateColor(_ state: GithubPullRequestCheckState) -> Color {
    switch state {
    case .success: .green
    case .failure: .red
    case .inProgress, .expected: .orange
    case .skipped: Color(nsColor: .tertiaryLabelColor)
    }
  }

  @ViewBuilder
  private func reviewDecisionIcon(_ pullRequest: MonitoredPullRequest) -> some View {
    switch pullRequest.reviewDecision?.uppercased() {
    case "APPROVED":
      Image(systemName: "checkmark.seal.fill")
        .foregroundStyle(.green)
        .accessibilityLabel("Approved")
        .help("Approved")
    case "CHANGES_REQUESTED":
      Image(systemName: "exclamationmark.bubble.fill")
        .foregroundStyle(.orange)
        .accessibilityLabel("Changes requested")
        .help("Changes requested")
    default:
      EmptyView()
    }
  }

  @ViewBuilder
  private func scoreChip(_ score: Int?) -> some View {
    if let score {
      Text("\(score)/5")
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(score >= 5 ? Color.green : Color.red)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(
          (score >= 5 ? Color.green : Color.red).opacity(0.15),
          in: Capsule()
        )
        .help("Greptile confidence score")
    } else {
      Text("—")
        .font(.caption)
        .foregroundStyle(.tertiary)
        .help("No Greptile review yet")
    }
  }

  private func healthColor(_ health: MonitoredPullRequest.Health) -> Color {
    switch health {
    case .green: .green
    case .red: .red
    case .pending: .orange
    case .neutral: Color(nsColor: .tertiaryLabelColor)
    }
  }

  private func rowHelp(_ pullRequest: MonitoredPullRequest) -> String {
    var parts: [String] = []
    if !pullRequest.author.isEmpty {
      parts.append("by \(pullRequest.author)")
    }
    parts.append(pullRequest.headRefName)
    let checksSummary = pullRequest.checks.summaryText
    if !checksSummary.isEmpty {
      parts.append(checksSummary)
    }
    parts.append("Click to open on GitHub")
    return parts.joined(separator: " · ")
  }
}
