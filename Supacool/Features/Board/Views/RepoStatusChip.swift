import ComposableArchitecture
import SwiftUI

/// Compact toolbar status for one repository:
/// - commits ahead/behind origin/<default>
/// - local uncommitted change count
/// - one-click Quick Diff opener
/// - diverged-branch resolution sheet on click
struct RepoStatusChip: View {
  let repository: Repository

  @State private var behindCount: Int?
  @State private var aheadCount: Int?
  @State private var localChangeCount: Int?
  @State private var currentBranch: String?
  @State private var isLoading: Bool = false
  @State private var isSyncing: Bool = false
  @State private var lastOutcome: RepoSyncOutcome?
  @State private var isQuickDiffPresented: Bool = false
  @State private var isDivergeSheetPresented: Bool = false

  @Dependency(WorktreeInventoryClient.self) private var worktreeInventory
  @Dependency(GitClientDependency.self) private var gitClient
  @Dependency(RepoSyncClient.self) private var repoSync

  /// Keep the chip fresh while the board is open.
  private let refreshInterval: Duration = .seconds(8)

  var body: some View {
    HStack(spacing: 6) {
      if let displayBranch {
        Text(displayBranch)
          .lineLimit(1)
          .truncationMode(.middle)
          .foregroundStyle(.secondary)
        Text("·")
          .foregroundStyle(.tertiary)
      }
      syncStatusView
      localChangesView
      if isDirty {
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
    .task(id: repository.id) {
      await refreshLoop()
    }
    .sheet(isPresented: $isQuickDiffPresented) {
      QuickDiffSheet(
        worktreeURL: repository.rootURL,
        onDismiss: { isQuickDiffPresented = false }
      )
    }
    .sheet(isPresented: $isDivergeSheetPresented) {
      RepoDivergeSheet(
        repoURL: repository.rootURL,
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
  }

  /// True when the local branch has both unpushed work AND unmerged
  /// upstream commits. Distinct visual + action affordance because
  /// fast-forward is not possible — the user has to choose rebase, merge,
  /// or open a terminal.
  private var isDiverged: Bool {
    (aheadCount ?? 0) > 0 && (behindCount ?? 0) > 0
  }

  @ViewBuilder
  private var syncStatusView: some View {
    if isSyncing {
      ProgressView()
        .controlSize(.mini)
    } else if isDiverged {
      Button {
        isDivergeSheetPresented = true
      } label: {
        HStack(spacing: 2) {
          Text("↓\(behindCount ?? 0)")
          Text("↑\(aheadCount ?? 0)")
        }
      }
      .buttonStyle(.plain)
      .foregroundStyle(.red)
      .help("Branch diverged from origin — click for resolution options")
    } else if let behindCount, behindCount > 0 {
      Button {
        Task { await pullFromOrigin() }
      } label: {
        Text("↓\(behindCount)")
      }
      .buttonStyle(.plain)
      .foregroundStyle(.orange)
      .help(behindOnlyHelp)
    } else if let aheadCount, aheadCount > 0 {
      Text("↑\(aheadCount)")
        .foregroundStyle(.blue)
    } else if behindCount != nil {
      Text("↓0")
        .foregroundStyle(.secondary)
    } else if isLoading {
      ProgressView()
        .controlSize(.mini)
    } else {
      Text("↓—")
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var localChangesView: some View {
    if let localChangeCount {
      Text("Δ\(localChangeCount)")
        .foregroundStyle(localChangeCount > 0 ? .orange : .secondary)
    } else {
      Text("Δ—")
        .foregroundStyle(.secondary)
    }
  }

  private var displayBranch: String? {
    guard let currentBranch else { return nil }
    guard !currentBranch.isEmpty, currentBranch != "HEAD", currentBranch != "main" else { return nil }
    return currentBranch
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
    let branchText = currentBranch ?? "—"
    let aheadText = aheadCount.map(String.init) ?? "—"
    let behindText = behindCount.map(String.init) ?? "—"
    let localText = localChangeCount.map(String.init) ?? "—"
    let actionHint: String
    if isDiverged {
      actionHint = " · Click for resolution options"
    } else if (behindCount ?? 0) > 0 {
      actionHint = " · Click ↓ to pull latest from origin"
    } else {
      actionHint = ""
    }
    let outcomeNote = lastOutcomeMessage.map { " · Last sync: \($0)" } ?? ""
    let core = "Branch: \(branchText) · ↑\(aheadText) ↓\(behindText)"
    return "\(core) · Local changes: \(localText)\(actionHint)\(outcomeNote)"
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

    async let branchName = gitClient.branchName(repository.rootURL)

    let baseRef: String
    do {
      baseRef = try await worktreeInventory.defaultBranchRef(repository.rootURL)
    } catch {
      // Same fallback as WorktreeJanitorFeature.
      baseRef = "origin/HEAD"
    }

    do {
      let metadata = try await worktreeInventory.gitMetadata(repository.rootURL, baseRef)
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
    guard !isSyncing else { return }
    isSyncing = true
    defer { isSyncing = false }
    let outcome = await repoSync.syncIfSafe(repository.rootURL)
    lastOutcome = outcome
    await refreshNow()
  }
}
