import ComposableArchitecture
import SwiftUI

/// Compact toolbar status for one repository/worktree:
/// - current branch (click for commit history)
/// - commits ahead/behind origin/<default>
/// - local uncommitted change count
/// - optional one-click Quick Diff opener
/// - optional diverged-branch resolution sheet on click
struct RepoStatusChip: View {
  let repositoryName: String
  let repositoryRootURL: URL
  let worktreeURL: URL
  let refreshID: String
  let showsQuickDiffButton: Bool
  let allowsSyncActions: Bool

  init(
    repository: Repository,
    worktreeURL: URL? = nil,
    refreshID: String? = nil,
    showsQuickDiffButton: Bool = true,
    allowsSyncActions: Bool = true
  ) {
    self.repositoryName = repository.name
    repositoryRootURL = repository.rootURL
    self.worktreeURL = worktreeURL ?? repository.rootURL
    self.refreshID = refreshID ?? repository.id
    self.showsQuickDiffButton = showsQuickDiffButton
    self.allowsSyncActions = allowsSyncActions
  }

  @State private var behindCount: Int?
  @State private var aheadCount: Int?
  @State private var localChangeCount: Int?
  @State private var currentBranch: String?
  @State private var isLoading: Bool = false
  @State private var isSyncing: Bool = false
  @State private var lastOutcome: RepoSyncOutcome?
  @State private var isQuickDiffPresented: Bool = false
  @State private var isDivergeSheetPresented: Bool = false
  @State private var isCommitHistoryPresented: Bool = false

  @Dependency(WorktreeInventoryClient.self) private var worktreeInventory
  @Dependency(GitClientDependency.self) private var gitClient
  @Dependency(RepoSyncClient.self) private var repoSync

  /// Keep the chip fresh while the board/terminal is open.
  private let refreshInterval: Duration = .seconds(8)

  var body: some View {
    HStack(spacing: 6) {
      branchHistoryButton
      Text("·")
        .foregroundStyle(.tertiary)
      syncStatusView
      localChangesView
      if showsQuickDiffButton && isDirty {
        Button {
          isQuickDiffPresented = true
        } label: {
          Image(systemName: "plus.forwardslash.minus")
            .font(.caption2.weight(.semibold))
            .accessibilityLabel("Open diff viewer")
        }
        .buttonStyle(.plain)
        .help("Open diff viewer")
      }
    }
    .font(.caption2.monospacedDigit())
    .padding(.horizontal, 10)
    .padding(.vertical, 4)
    .help(helpText)
    .animation(.snappy(duration: 0.22), value: currentBranch)
    .animation(.snappy(duration: 0.22), value: aheadCount)
    .animation(.snappy(duration: 0.22), value: behindCount)
    .animation(.snappy(duration: 0.22), value: localChangeCount)
    .task(id: refreshID) {
      await refreshLoop()
    }
    .sheet(isPresented: $isQuickDiffPresented) {
      QuickDiffSheet(
        worktreeURL: worktreeURL,
        onDismiss: { isQuickDiffPresented = false }
      )
    }
    .sheet(isPresented: $isDivergeSheetPresented) {
      RepoDivergeSheet(
        repoURL: repositoryRootURL,
        defaultBranch: currentBranch ?? "main",
        ahead: aheadCount ?? 0,
        behind: behindCount ?? 0,
        onClose: { isDivergeSheetPresented = false },
        onResolved: {
          isDivergeSheetPresented = false
          Task { await refreshNow() }
        }
      )
    }
    .sheet(isPresented: $isCommitHistoryPresented) {
      CommitHistorySheet(
        repositoryName: repositoryName,
        worktreeURL: worktreeURL,
        branchName: currentBranch,
        ahead: aheadCount,
        behind: behindCount,
        localChanges: localChangeCount,
        onClose: { isCommitHistoryPresented = false }
      )
    }
  }

  /// True when the local branch has both unpushed work AND unmerged
  /// upstream commits. Distinct visual + action affordance because
  /// fast-forward is not possible — the user has to choose rebase, merge,
  /// or open a terminal. In focused terminals we render this as status
  /// only because the resolver is intentionally repo-root-only.
  private var isDiverged: Bool {
    (aheadCount ?? 0) > 0 && (behindCount ?? 0) > 0
  }

  private var branchHistoryButton: some View {
    Button {
      isCommitHistoryPresented = true
    } label: {
      HStack(spacing: 3) {
        Image(systemName: "arrow.triangle.branch")
          .font(.caption2)
          .accessibilityHidden(true)
        Text(branchText)
          .lineLimit(1)
          .truncationMode(.middle)
          .contentTransition(.opacity)
      }
      .frame(maxWidth: 180, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .help("Show commit history for \(branchText)")
  }

  @ViewBuilder
  private var syncStatusView: some View {
    if isSyncing {
      ProgressView()
        .controlSize(.mini)
    } else if isDiverged {
      if allowsSyncActions {
        Button {
          isDivergeSheetPresented = true
        } label: {
          HStack(spacing: 2) {
            Text("↓\(behindCount ?? 0)")
              .contentTransition(.numericText())
            Text("↑\(aheadCount ?? 0)")
              .contentTransition(.numericText())
          }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.red)
        .help("Branch diverged from origin — click for resolution options")
      } else {
        HStack(spacing: 2) {
          Text("↓\(behindCount ?? 0)")
            .contentTransition(.numericText())
          Text("↑\(aheadCount ?? 0)")
            .contentTransition(.numericText())
        }
        .foregroundStyle(.red)
        .help("Branch diverged from base")
      }
    } else if let behindCount, behindCount > 0 {
      if allowsSyncActions {
        Button {
          Task { await pullFromOrigin() }
        } label: {
          Text("↓\(behindCount)")
            .contentTransition(.numericText())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.orange)
        .help(behindOnlyHelp)
      } else {
        Text("↓\(behindCount)")
          .contentTransition(.numericText())
          .foregroundStyle(.orange)
          .help("Behind base by \(behindCount) commit\(behindCount == 1 ? "" : "s")")
      }
    } else if let aheadCount, aheadCount > 0 {
      Text("↑\(aheadCount)")
        .contentTransition(.numericText())
        .foregroundStyle(.blue)
    } else if behindCount != nil {
      Text("↓0")
        .contentTransition(.numericText())
        .foregroundStyle(.secondary)
    } else if isLoading {
      ProgressView()
        .controlSize(.mini)
    } else {
      Text("↓—")
        .contentTransition(.numericText())
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var localChangesView: some View {
    if let localChangeCount {
      Text("Δ\(localChangeCount)")
        .contentTransition(.numericText())
        .foregroundStyle(localChangeCount > 0 ? .orange : .secondary)
    } else {
      Text("Δ—")
        .contentTransition(.numericText())
        .foregroundStyle(.secondary)
    }
  }

  private var branchText: String {
    let trimmed = currentBranch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !trimmed.isEmpty { return trimmed }
    return isLoading ? "…" : "HEAD"
  }

  private var isDirty: Bool {
    (localChangeCount ?? 0) > 0
  }

  private var behindOnlyHelp: String {
    var help = "Pull latest from origin (fast-forward only)"
    if let outcomeMessage = lastOutcomeMessage {
      help += "\nLast attempt: \(outcomeMessage)"
    }
    return help
  }

  /// Human-readable summary of the most recent sync outcome — `nil` if no
  /// attempt has been made or it succeeded cleanly. Surfaced via tooltip
  /// so a silent `--ff-only` failure stops being silent.
  private var lastOutcomeMessage: String? {
    guard let outcome = lastOutcome else { return nil }
    switch outcome {
    case .synced:
      return nil
    case .skippedDirtyTree:
      return "skipped — working tree dirty"
    case .skippedNotOnDefaultBranch(let cur, let def):
      return "skipped — on \(cur), not \(def)"
    case .skippedNoDefaultBranch:
      return "skipped — no origin/HEAD set"
    case .skippedFetchFailed(let msg):
      return "fetch failed: \(msg)"
    case .skippedFastForwardNotPossible:
      return "branch diverged — fast-forward not possible"
    case .failedUnknown(let msg):
      return "failed: \(msg)"
    }
  }

  private var helpText: String {
    let aheadText = aheadCount.map(String.init) ?? "—"
    let behindText = behindCount.map(String.init) ?? "—"
    let localText = localChangeCount.map(String.init) ?? "—"
    let actionHint: String
    if isDiverged {
      actionHint = allowsSyncActions ? " · Click ↓↑ to resolve divergence" : " · Diverged from base"
    } else if (behindCount ?? 0) > 0 {
      actionHint = allowsSyncActions ? " · Click ↓ to pull latest from origin" : " · Behind base"
    } else {
      actionHint = ""
    }
    let outcomeNote = lastOutcomeMessage.map { " · Last sync: \($0)" } ?? ""
    let core = "Branch: \(branchText) · ↑\(aheadText) ↓\(behindText)"
    return "\(core) · Local changes: \(localText) · Click branch for commit history\(actionHint)\(outcomeNote)"
  }

  private func refreshLoop() async {
    while !Task.isCancelled {
      await refreshNow()
      try? await Task.sleep(for: refreshInterval)
    }
  }

  private func refreshNow() async {
    isLoading = true
    defer { isLoading = false }

    async let branchName = gitClient.branchName(worktreeURL)

    let baseRef: String
    do {
      baseRef = try await worktreeInventory.defaultBranchRef(repositoryRootURL)
    } catch {
      // Same fallback as WorktreeJanitorFeature.
      baseRef = "origin/HEAD"
    }

    do {
      let metadata = try await worktreeInventory.gitMetadata(worktreeURL, baseRef)
      behindCount = metadata.aheadBehind?.behind
      aheadCount = metadata.aheadBehind?.ahead
      localChangeCount = metadata.uncommittedCount
    } catch {
      behindCount = nil
      aheadCount = nil
      localChangeCount = nil
    }

    currentBranch = await branchName
  }

  private func pullFromOrigin() async {
    guard !isSyncing, allowsSyncActions else { return }
    isSyncing = true
    defer { isSyncing = false }
    let outcome = await repoSync.syncIfSafe(repositoryRootURL)
    lastOutcome = outcome
    await refreshNow()
  }
}
