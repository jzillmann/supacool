import ComposableArchitecture
import SwiftUI

/// Compact toolbar status for one repository:
/// - commits behind origin/<default>
/// - local uncommitted change count
/// - one-click Quick Diff opener
struct RepoStatusChip: View {
  let repository: Repository

  @State private var behindCount: Int?
  @State private var localChangeCount: Int?
  @State private var currentBranch: String?
  @State private var isLoading: Bool = false
  @State private var isQuickDiffPresented: Bool = false

  @Dependency(WorktreeInventoryClient.self) private var worktreeInventory
  @Dependency(GitClientDependency.self) private var gitClient

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
      behindView
      localChangesView
      if isDirty {
        Button {
          isQuickDiffPresented = true
        } label: {
          Image(systemName: "plus.forwardslash.minus")
            .font(.caption2.weight(.semibold))
        }
        .buttonStyle(.plain)
        .help("Open diff viewer")
      }
    }
    .font(.caption2.monospacedDigit())
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
  }

  @ViewBuilder
  private var behindView: some View {
    if let behindCount {
      Text("↓\(behindCount)")
        .foregroundStyle(behindCount > 0 ? .orange : .secondary)
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

  private var helpText: String {
    let branchText = currentBranch ?? "—"
    let behindText = behindCount.map(String.init) ?? "—"
    let localText = localChangeCount.map(String.init) ?? "—"
    return "Branch: \(branchText) · Behind origin: \(behindText) · Local changes: \(localText)"
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
      localChangeCount = metadata.uncommittedCount
    } catch {
      behindCount = nil
      localChangeCount = nil
    }

    currentBranch = await branchName
  }
}
