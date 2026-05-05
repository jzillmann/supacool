import AppKit
import ComposableArchitecture
import SwiftUI

/// Resolution dialog shown when the repo root has diverged from origin
/// (commits ahead AND commits behind, so `--ff-only` can't help).
/// Three explicit choices: rebase, merge, or pop a terminal at the repo
/// root and let the user sort it out by hand.
///
/// Pure SwiftUI sheet — mirrors `QuickDiffSheet`'s pattern, no TCA
/// reducer. The actual git work goes through `RepoSyncClient`.
struct RepoDivergeSheet: View {
  let repoURL: URL
  let defaultBranch: String
  let ahead: Int
  let behind: Int
  let onClose: () -> Void
  /// Called when the diverge is resolved (rebase or merge succeeded) so
  /// the parent can dismiss + refresh its chip.
  let onResolved: () -> Void

  @State private var inFlightStrategy: PullStrategy?
  @State private var lastOutcome: RepoSyncOutcome?
  @State private var didResolve: Bool = false

  @Dependency(RepoSyncClient.self) private var repoSync

  /// Origin ref used in copy. We don't have a canonical "remote default"
  /// at construction time (the parent passes the local branch name), so
  /// fall back to `main` when the parent's branch name isn't useful.
  private var originRef: String {
    let trimmed = defaultBranch.trimmingCharacters(in: .whitespacesAndNewlines)
    let usable = trimmed.isEmpty || trimmed == "HEAD" ? "main" : trimmed
    return "origin/\(usable)"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      VStack(alignment: .leading, spacing: 14) {
        summary
        actionsList
        if let outcome = lastOutcome {
          outcomeBanner(outcome)
        }
      }
      .padding(20)
      Divider()
      footer
    }
    .frame(minWidth: 460, idealWidth: 520)
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: "arrow.triangle.branch")
        .font(.title3)
        .foregroundStyle(.red)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text("Branch diverged")
          .font(.headline)
        Text(repoURL.lastPathComponent)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(14)
  }

  private var summary: some View {
    let localPart = "\(ahead) local commit" + (ahead == 1 ? "" : "s")
    let remotePart = "\(behind) remote commit" + (behind == 1 ? "" : "s")
    let body = "\(localPart) and \(remotePart) need reconciling."
    let tail = "Pick how to combine them, or open a terminal to resolve manually."
    return Text("\(body) \(tail)")
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  private var actionsList: some View {
    VStack(spacing: 10) {
      actionRow(
        title: "Rebase onto \(originRef)",
        subtitle: "Replay your \(ahead) local commit\(ahead == 1 ? "" : "s") on top of origin. Linear history.",
        systemImage: "arrow.uturn.up",
        strategy: .rebase
      )
      actionRow(
        title: "Merge \(originRef)",
        subtitle: "Create a merge commit combining both sides. Preserves history as-is.",
        systemImage: "arrow.triangle.merge",
        strategy: .merge
      )
      Button {
        openTerminalAtRepoRoot()
      } label: {
        actionRowLabel(
          title: "Open terminal at repo root",
          subtitle: "Investigate manually. Useful when conflicts are likely.",
          systemImage: "terminal"
        )
      }
      .buttonStyle(.plain)
      .disabled(inFlightStrategy != nil)
    }
  }

  @ViewBuilder
  private func actionRow(
    title: String,
    subtitle: String,
    systemImage: String,
    strategy: PullStrategy
  ) -> some View {
    Button {
      Task { await runStrategy(strategy) }
    } label: {
      actionRowLabel(
        title: title,
        subtitle: subtitle,
        systemImage: systemImage,
        trailing: { trailingIndicator(for: strategy) }
      )
    }
    .buttonStyle(.plain)
    .disabled(inFlightStrategy != nil || didResolve)
  }

  @ViewBuilder
  private func actionRowLabel<Trailing: View>(
    title: String,
    subtitle: String,
    systemImage: String,
    @ViewBuilder trailing: () -> Trailing = { EmptyView() }
  ) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: systemImage)
        .font(.title3)
        .foregroundStyle(.secondary)
        .frame(width: 24)
        .padding(.top, 2)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.callout.weight(.medium))
          .foregroundStyle(.primary)
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
      trailing()
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(Color.secondary.opacity(0.08))
    )
    .contentShape(Rectangle())
  }

  @ViewBuilder
  private func trailingIndicator(for strategy: PullStrategy) -> some View {
    if inFlightStrategy == strategy {
      ProgressView()
        .controlSize(.small)
    } else {
      Image(systemName: "chevron.right")
        .font(.caption)
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
    }
  }

  @ViewBuilder
  private func outcomeBanner(_ outcome: RepoSyncOutcome) -> some View {
    let isSuccess = outcome.isSuccess
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        .foregroundStyle(isSuccess ? .green : .orange)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(headline(for: outcome))
          .font(.callout.weight(.medium))
        if let detail = detail(for: outcome), !detail.isEmpty {
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill((isSuccess ? Color.green : Color.orange).opacity(0.12))
    )
  }

  private var footer: some View {
    HStack {
      Spacer()
      Button("Close", action: onClose)
        .keyboardShortcut(.cancelAction)
    }
    .padding(14)
  }

  private func headline(for outcome: RepoSyncOutcome) -> String {
    switch outcome {
    case .synced(let advancedBy):
      return advancedBy > 0
        ? "Resolved — \(advancedBy) commit\(advancedBy == 1 ? "" : "s") applied"
        : "Already up to date"
    case .skippedDirtyTree:
      return "Working tree is dirty"
    case .skippedNotOnDefaultBranch(let cur, let def):
      return "Not on default branch (on \(cur), expected \(def))"
    case .skippedNoDefaultBranch:
      return "No origin/HEAD set"
    case .skippedFetchFailed:
      return "Fetch from origin failed"
    case .skippedFastForwardNotPossible:
      return "Fast-forward not possible"
    case .failedUnknown:
      return "Operation failed"
    }
  }

  private func detail(for outcome: RepoSyncOutcome) -> String? {
    switch outcome {
    case .synced, .skippedNoDefaultBranch, .skippedNotOnDefaultBranch:
      return nil
    case .skippedDirtyTree:
      return "Commit or stash your local changes, then try again."
    case .skippedFetchFailed(let msg), .skippedFastForwardNotPossible(let msg), .failedUnknown(let msg):
      return msg
    }
  }

  // MARK: - Actions

  private func runStrategy(_ strategy: PullStrategy) async {
    guard inFlightStrategy == nil else { return }
    inFlightStrategy = strategy
    defer { inFlightStrategy = nil }
    let outcome = await repoSync.pullWithStrategy(repoURL, strategy)
    lastOutcome = outcome
    if outcome.isSuccess {
      didResolve = true
      // Brief pause so the success banner is visible before we dismiss.
      try? await Task.sleep(for: .milliseconds(450))
      onResolved()
    }
  }

  private func openTerminalAtRepoRoot() {
    let path = repoURL.path(percentEncoded: false)
    let terminalAppURL = NSWorkspace.shared.urlForApplication(
      withBundleIdentifier: "com.apple.Terminal"
    )
    if let terminalAppURL {
      let configuration = NSWorkspace.OpenConfiguration()
      NSWorkspace.shared.open(
        [URL(fileURLWithPath: path)],
        withApplicationAt: terminalAppURL,
        configuration: configuration
      ) { _, _ in }
    } else {
      // Terminal.app missing (rare but possible on stripped systems) —
      // fall back to revealing the directory in Finder so the user has
      // *some* way to take it from here.
      NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
  }
}
