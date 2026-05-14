import ComposableArchitecture
import SwiftUI

/// Lightweight modal opened from the branch/status chip. Shows recent
/// commits for the exact worktree behind the chip (repo root on the
/// board, current workspace in a focused terminal).
struct CommitHistorySheet: View {
  let repositoryName: String
  let worktreeURL: URL
  let branchName: String?
  let ahead: Int?
  let behind: Int?
  let localChanges: Int?
  let onClose: () -> Void

  @State private var commits: [GitCommitHistoryEntry] = []
  @State private var isLoading: Bool = false
  @State private var errorMessage: String?

  @Dependency(GitClientDependency.self) private var gitClient

  private let limit = 80

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      content
      Divider()
      footer
    }
    .frame(minWidth: 560, idealWidth: 680, minHeight: 420, idealHeight: 560)
    .task(id: worktreeURL.path(percentEncoded: false)) {
      await loadCommits()
    }
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: "clock.arrow.circlepath")
        .font(.title3)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text("Commit history")
          .font(.headline)
        HStack(spacing: 8) {
          branchBadge
          Text(repositoryName)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
          if let summary = statusSummary {
            Text(summary)
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
        }
      }
      Spacer(minLength: 8)
    }
    .padding(14)
  }

  private var branchBadge: some View {
    HStack(spacing: 4) {
      Image(systemName: "arrow.triangle.branch")
        .font(.caption2)
        .accessibilityHidden(true)
      Text(displayBranch)
        .font(.caption.weight(.semibold))
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .foregroundStyle(Color.accentColor)
    .padding(.horizontal, 7)
    .padding(.vertical, 3)
    .background(Color.accentColor.opacity(0.12))
    .clipShape(Capsule())
  }

  @ViewBuilder
  private var content: some View {
    if isLoading && commits.isEmpty {
      VStack(spacing: 10) {
        ProgressView()
        Text("Loading commits…")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(24)
    } else if let errorMessage {
      VStack(spacing: 10) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.largeTitle)
          .foregroundStyle(.orange)
        Text("Could not load commits")
          .font(.headline)
        Text(errorMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .textSelection(.enabled)
          .frame(maxWidth: 460)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(24)
    } else if commits.isEmpty {
      VStack(spacing: 10) {
        Image(systemName: "tray")
          .font(.largeTitle)
          .foregroundStyle(.secondary)
        Text("No commits found")
          .font(.headline)
        Text("This worktree does not have any commits yet.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(24)
    } else {
      List(commits) { commit in
        commitRow(commit)
      }
      .listStyle(.inset)
    }
  }

  private func commitRow(_ commit: GitCommitHistoryEntry) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Text(commit.shortHash)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .frame(width: 64, alignment: .leading)
      VStack(alignment: .leading, spacing: 4) {
        Text(commit.subject.isEmpty ? "(no subject)" : commit.subject)
          .font(.callout.weight(.medium))
          .lineLimit(2)
          .textSelection(.enabled)
        HStack(spacing: 6) {
          Text(commit.author.isEmpty ? "Unknown author" : commit.author)
          Text("·")
            .foregroundStyle(.tertiary)
          Text(relativeDate(commit.date))
            .monospacedDigit()
            .help(commit.date.formatted(date: .abbreviated, time: .shortened))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 4)
  }

  private var footer: some View {
    HStack(spacing: 10) {
      Text("Showing latest \(limit) commits")
        .font(.caption)
        .foregroundStyle(.tertiary)
      Spacer()
      Button("Refresh") {
        Task { await loadCommits() }
      }
      .disabled(isLoading)
      .help("Reload commit history")
      Button("Close", action: onClose)
        .keyboardShortcut(.cancelAction)
    }
    .padding(14)
  }

  private var displayBranch: String {
    let trimmed = branchName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? "HEAD" : trimmed
  }

  private var statusSummary: String? {
    var parts: [String] = []
    if let ahead { parts.append("↑\(ahead)") }
    if let behind { parts.append("↓\(behind)") }
    if let localChanges { parts.append("Δ\(localChanges)") }
    guard !parts.isEmpty else { return nil }
    return parts.joined(separator: " ")
  }

  private func loadCommits() async {
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
      let loaded = try await gitClient.commitHistory(worktreeURL, limit)
      guard !Task.isCancelled else { return }
      commits = loaded
    } catch {
      guard !Task.isCancelled else { return }
      commits = []
      errorMessage = error.localizedDescription
    }
  }

  private func relativeDate(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
  }
}
