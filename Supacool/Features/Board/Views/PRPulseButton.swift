import AppKit
import ComposableArchitecture
import SwiftUI

/// Toolbar badge summarizing open PRs that need the authenticated GitHub
/// user's attention — ones they authored or are assigned to — across the
/// board's (filtered) repositories: total count plus green / red / pending
/// breakdown. Expands into a popover listing each PR with its
/// CI state, review decision, and Greptile confidence score; clicking a row
/// opens the PR on GitHub.
///
/// Data comes from `BoardFeature`'s PR Pulse snapshots (`gh pr list` per
/// repo on a 3-minute tick). Hidden until at least one filtered repo has a
/// snapshot with a GitHub remote.
struct PRPulseButton: View {
  let store: StoreOf<BoardFeature>
  let repositories: IdentifiedArrayOf<Repository>
  /// Live board status (busy / idle / …) for a session, threaded down from
  /// `BoardRootView` which owns the `WorktreeTerminalManager`. Lets a PR row
  /// with an associated session mirror the board card's status glyph. Invoked
  /// inside the popover body so `@Observable` terminal state stays tracked.
  let sessionStatus: (AgentSession) -> BoardSessionStatus

  @State private var isPresented: Bool = false

  /// Rows whose per-check breakdown is expanded, keyed by
  /// "repositoryID#prNumber" so numbers can't collide across repos.
  /// View-local: collapses again when the popover closes and the view
  /// is torn down.
  @State private var expandedCheckKeys: Set<String> = []

  /// Which slice of PRs the popover shows. View-local: resets to `.active`
  /// when the popover closes and the view is torn down.
  @State private var filter: PRPulseFilter = .active

  /// Last prompt fired at each associated session's agent terminal, keyed by
  /// tab and loaded lazily off-main from the transcript. Powers the status
  /// glyph's hover tooltip.
  @State private var lastPromptByTab: [TerminalTabID: String] = [:]

  var body: some View {
    if !visibleSnapshots.isEmpty {
      Button {
        isPresented.toggle()
      } label: {
        badgeLabel
      }
      .help(
        "Your open pull requests across board repos — authored by or assigned to you. "
          + "Green: CI passed & Greptile 5/5, red: conflicts, failing checks, or score below 5/5. "
          + "Click for details."
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

  /// Keys of PRs the user has ignored, hidden from the list and counts.
  private var ignoredKeys: Set<String> { Set(store.prPulseIgnoredPRKeys) }

  private func isIgnored(_ repositoryID: String, _ number: Int) -> Bool {
    ignoredKeys.contains(PRPulseIgnoreKey.make(repositoryID: repositoryID, number: number))
  }

  /// A snapshot's PRs minus the ones the user ignored.
  private func activePullRequests(_ snapshot: RepoPullRequestSnapshot) -> [MonitoredPullRequest] {
    snapshot.pullRequests.filter { !isIgnored(snapshot.repositoryID, $0.number) }
  }

  /// A snapshot's PRs narrowed to the popover's currently selected filter.
  private func filteredPullRequests(_ snapshot: RepoPullRequestSnapshot) -> [MonitoredPullRequest] {
    switch filter {
    case .active:
      return activePullRequests(snapshot)
    case .drafts:
      return activePullRequests(snapshot).filter(\.isDraft)
    case .ignored:
      return snapshot.pullRequests.filter { isIgnored(snapshot.repositoryID, $0.number) }
    }
  }

  /// Total PRs shown under the current filter — drives the empty state.
  private var filteredCount: Int {
    visibleSnapshots.reduce(0) { $0 + filteredPullRequests($1.snapshot).count }
  }

  /// All non-ignored PRs across visible repos — the basis for every count.
  private var activePullRequests: [MonitoredPullRequest] {
    visibleSnapshots.flatMap { activePullRequests($0.snapshot) }
  }

  private var draftCount: Int { activePullRequests.count(where: \.isDraft) }

  /// Ignored PRs still present in a snapshot, paired with their repo so the
  /// "N ignored" section can label and restore them.
  private var ignoredEntries: [(repositoryID: String, repository: Repository, pullRequest: MonitoredPullRequest)] {
    visibleSnapshots.flatMap { entry in
      entry.snapshot.pullRequests
        .filter { isIgnored(entry.snapshot.repositoryID, $0.number) }
        .map { (entry.snapshot.repositoryID, entry.repository, $0) }
    }
  }

  private var totalCount: Int { activePullRequests.count }
  private var greenCount: Int { activePullRequests.count(where: { $0.health == .green }) }
  private var redCount: Int { activePullRequests.count(where: { $0.health == .red }) }
  private var pendingCount: Int { activePullRequests.count(where: { $0.health == .pending }) }

  // MARK: - Badge

  private var badgeLabel: some View {
    HStack(spacing: 6) {
      Image(systemName: "list.bullet.clipboard")
        .accessibilityHidden(true)
      Text("\(totalCount)")
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
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
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(.secondary)
    }
  }

  // MARK: - Popover

  private var popoverContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("My Pull Requests")
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
      filterPicker
      Divider()
      if filteredCount == 0 {
        Text(emptyStateText)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .center)
          .padding(24)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(visibleSnapshots, id: \.repository.id) { entry in
              let rows = filteredPullRequests(entry.snapshot)
              if !rows.isEmpty {
                if visibleSnapshots.count > 1 {
                  repoHeader(entry.repository, count: rows.count)
                }
                ForEach(rows) { pullRequest in
                  row(pullRequest, in: entry)
                }
              }
            }
          }
          .padding(8)
        }
        .frame(maxHeight: 440)
      }
    }
    .frame(width: 640)
  }

  /// Single-select filter replacing the old buried "N ignored" section:
  /// ignored PRs are now just another slice surfaced in the main list.
  private var filterPicker: some View {
    Picker("Filter", selection: $filter) {
      Text("Active (\(totalCount))").tag(PRPulseFilter.active)
      Text("Drafts (\(draftCount))").tag(PRPulseFilter.drafts)
      Text("Ignored (\(ignoredEntries.count))").tag(PRPulseFilter.ignored)
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  private var emptyStateText: String {
    switch filter {
    case .active: "No open pull requests authored by or assigned to you"
    case .drafts: "No draft pull requests"
    case .ignored: "No ignored pull requests"
    }
  }

  /// Renders one PR under the active/drafts filters as a full interactive row;
  /// under the ignored filter as a compact restore row.
  @ViewBuilder
  private func row(
    _ pullRequest: MonitoredPullRequest,
    in entry: (repository: Repository, snapshot: RepoPullRequestSnapshot)
  ) -> some View {
    if filter == .ignored {
      ignoredRow(entry.snapshot.repositoryID, entry.repository, pullRequest)
    } else {
      let expansionKey = PRPulseIgnoreKey.make(
        repositoryID: entry.snapshot.repositoryID,
        number: pullRequest.number
      )
      pullRequestRow(
        pullRequest,
        repositoryID: entry.snapshot.repositoryID,
        expansionKey: expansionKey,
        associatedSession: associatedSession(snapshot: entry.snapshot, pullRequest: pullRequest)
      )
      if expandedCheckKeys.contains(expansionKey) {
        checkDetailRows(pullRequest)
      }
    }
  }

  private func ignoredRow(
    _ repositoryID: String,
    _ repository: Repository,
    _ pullRequest: MonitoredPullRequest
  ) -> some View {
    HStack(spacing: 8) {
      Circle()
        .fill(healthColor(pullRequest.health))
        .frame(width: 8, height: 8)
        .opacity(0.5)
      Text("#\(pullRequest.number)")
        .monospacedDigit()
        .foregroundStyle(.tertiary)
      Text(pullRequest.title)
        .lineLimit(1)
        .truncationMode(.tail)
        .foregroundStyle(.secondary)
      Spacer(minLength: 12)
      if visibleSnapshots.count > 1 {
        Text(repository.name)
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      Button {
        store.send(.prPulseIgnoreToggled(repositoryID: repositoryID, number: pullRequest.number))
      } label: {
        Image(systemName: "arrow.uturn.backward")
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityLabel("Restore pull request")
      }
      .buttonStyle(.plain)
      .help("Restore — bring this PR back into the pulse")
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 4)
    .opacity(0.8)
  }

  private func repoHeader(_ repository: Repository, count: Int) -> some View {
    HStack(spacing: 6) {
      Text(repository.name)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      Text("\(count)")
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.tertiary)
      Spacer()
    }
    .padding(.horizontal, 6)
    .padding(.top, 8)
    .padding(.bottom, 2)
  }

  private func pullRequestRow(
    _ pullRequest: MonitoredPullRequest,
    repositoryID: String,
    expansionKey: String,
    associatedSession: AgentSession?
  ) -> some View {
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
          conflictChip(pullRequest)
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
      sessionStatusGlyph(associatedSession)
      Button {
        isPresented = false
        store.send(
          .prPulseSessionRequested(
            repositoryID: repositoryID,
            number: pullRequest.number,
            repositories: Array(repositories)
          )
        )
      } label: {
        Image(systemName: associatedSession == nil ? "plus.rectangle" : "terminal")
          .font(.caption)
          .foregroundStyle(associatedSession == nil ? .secondary : .primary)
          .accessibilityLabel(associatedSession == nil ? "Start associated session" : "Open associated session")
      }
      .buttonStyle(.plain)
      .help(
        associatedSession == nil
          ? "Start an associated session for this PR"
          : "Open the associated session for this PR"
      )
      Button {
        store.send(.prPulseIgnoreToggled(repositoryID: repositoryID, number: pullRequest.number))
      } label: {
        Image(systemName: "eye.slash")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .accessibilityLabel("Ignore this pull request")
      }
      .buttonStyle(.plain)
      .help("Ignore — hide this PR from the pulse and exclude it from the counts")
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 4)
  }

  private func associatedSession(
    snapshot: RepoPullRequestSnapshot,
    pullRequest: MonitoredPullRequest
  ) -> AgentSession? {
    guard let refKey = PRPulseReference.dedupeKey(
      slug: snapshot.slug,
      number: pullRequest.number
    ) else { return nil }
    return store.sessions.first { session in
      session.references.contains(where: { $0.dedupeKey == refKey })
    }
  }

  /// Busy/idle glyph for a PR's associated session, mirroring the board
  /// card's status indicator. Hover reveals the last prompt fired at the
  /// session's agent terminal (loaded lazily from the transcript). Nothing
  /// renders for PRs without a session — the "+" button already signals that.
  @ViewBuilder
  private func sessionStatusGlyph(_ session: AgentSession?) -> some View {
    if let session {
      let status = sessionStatus(session)
      let tabID = TerminalTabID(rawValue: session.id)
      Image(systemName: status.systemImage)
        .font(.caption)
        .foregroundStyle(status.color)
        .accessibilityLabel("Session status: \(status.label)")
        .help(statusHelp(status, tabID: tabID))
        .task(id: tabID) { await loadLastPrompt(tabID) }
    }
  }

  /// Reconstructs the most recent prompt for `tabID` off the main thread and
  /// caches it. Cheap to re-enter: skips work once a prompt is cached.
  private func loadLastPrompt(_ tabID: TerminalTabID) async {
    guard lastPromptByTab[tabID] == nil else { return }
    let loaded = await Task.detached(priority: .utility) {
      TranscriptReader.aggregatePrompts(from: TranscriptReader.loadEntries(tabID: tabID)).first?.text
    }.value
    guard let loaded else { return }
    lastPromptByTab[tabID] = loaded.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func statusHelp(_ status: BoardSessionStatus, tabID: TerminalTabID) -> String {
    guard let prompt = lastPromptByTab[tabID], !prompt.isEmpty else { return status.label }
    let capped = prompt.count > 100 ? "\(prompt.prefix(100))…" : prompt
    return "\(status.label) · last prompt: \(capped)"
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
  private func conflictChip(_ pullRequest: MonitoredPullRequest) -> some View {
    if pullRequest.hasMergeConflict {
      HStack(spacing: 3) {
        Image(systemName: "arrow.triangle.branch")
          .font(.caption2.weight(.semibold))
          .accessibilityHidden(true)
        Text("Conflicts")
          .font(.caption)
      }
      .foregroundStyle(.red)
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .background(Color.red.opacity(0.15), in: Capsule())
      .help("Merge conflicts must be resolved before this PR can merge")
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
    if pullRequest.hasMergeConflict {
      parts.append("merge conflicts")
    }
    parts.append("Click to open on GitHub")
    return parts.joined(separator: " · ")
  }
}

/// Which slice of monitored PRs the pulse popover shows. `nonisolated` so its
/// synthesized `Equatable`/`Hashable` satisfies `Picker(selection:)` under
/// Swift 6 global `@MainActor` isolation.
nonisolated private enum PRPulseFilter: String, CaseIterable, Identifiable {
  case active
  case drafts
  case ignored

  var id: String { rawValue }
}
