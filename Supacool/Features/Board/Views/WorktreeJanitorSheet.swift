import ComposableArchitecture
import Foundation
import SwiftUI

/// Read-only inspector for every worktree registered against a repo.
///
/// Renders one row per worktree with classification badge, disk size,
/// last-commit summary, and dirty-file count. Rows fill in progressively
/// as the reducer's scan streams size + git metadata per row — the
/// sheet is immediately interactive even on a 47-worktree repo where a
/// full `du -sk` sweep takes 30+ seconds.
///
/// PR2 of the janitor ladder: no multi-select, no delete, no diff
/// expansion. PR3 adds those on top of this same sheet.
struct WorktreeJanitorSheet: View {
  @Bindable var store: StoreOf<WorktreeJanitorFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      content
      Divider()
      footer
    }
    .frame(minWidth: 720, minHeight: 420)
    .task {
      store.send(.scanRequested)
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Manage Worktrees")
        .font(.title2.weight(.semibold))
      Text(store.repositoryName)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 20)
    .padding(.vertical, 16)
  }

  @ViewBuilder
  private var content: some View {
    if store.rows.isEmpty, store.isScanning {
      loadingPlaceholder
    } else if let error = store.scanError {
      errorPlaceholder(error)
    } else if store.rows.isEmpty {
      emptyPlaceholder
    } else {
      table
    }
  }

  private var loadingPlaceholder: some View {
    VStack(spacing: 8) {
      ProgressView()
      Text("Scanning worktrees…")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func errorPlaceholder(_ message: String) -> some View {
    VStack(spacing: 6) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.title)
        .foregroundStyle(.orange)
      Text("Scan failed")
        .font(.headline)
      Text(message)
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .textSelection(.enabled)
        .padding(.horizontal, 40)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var emptyPlaceholder: some View {
    Text("No worktrees registered.")
      .font(.callout)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var table: some View {
    Table(Array(store.rows)) {
      TableColumn("Name") { row in
        VStack(alignment: .leading, spacing: 2) {
          Text(row.name)
            .font(.callout.weight(.medium))
          if let branch = row.branch {
            Text(branch)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      .width(min: 140, ideal: 200)

      TableColumn("Status") { row in
        StatusBadge(status: row.status)
      }
      .width(min: 110, ideal: 140)

      TableColumn("Size") { row in
        Text(formatSize(row.sizeBytes))
          .font(.callout.monospacedDigit())
          .foregroundStyle(row.sizeBytes == nil ? .secondary : .primary)
      }
      .width(min: 70, ideal: 90)

      TableColumn("Last Commit") { row in
        VStack(alignment: .leading, spacing: 2) {
          if let commit = row.lastCommit {
            Text(commit.subject)
              .font(.callout)
              .lineLimit(1)
            Text(relativeDate(commit.date))
              .font(.caption)
              .foregroundStyle(.secondary)
          } else {
            Text("—")
              .foregroundStyle(.secondary)
          }
        }
      }
      .width(min: 180, ideal: 260)

      TableColumn("Dirty") { row in
        Text(formatDirty(row.uncommittedCount))
          .font(.callout.monospacedDigit())
          .foregroundStyle(dirtyColor(row.uncommittedCount))
      }
      .width(min: 50, ideal: 70)
    }
    .tableStyle(.inset)
  }

  private var footer: some View {
    HStack {
      if store.isScanning {
        ProgressView()
          .controlSize(.small)
        Text("Measuring \(store.rows.count) worktrees…")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else if !store.rows.isEmpty {
        Text(summaryLine)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button("Done") {
        store.send(.closeRequested)
      }
      .keyboardShortcut(.defaultAction)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
  }

  private var summaryLine: String {
    let orphanCount = store.rows.filter { $0.isDeletionCandidate }.count
    let totalBytes = store.rows.reduce(UInt64(0)) { acc, row in
      acc + (row.sizeBytes ?? 0)
    }
    return "\(store.rows.count) worktrees · \(orphanCount) candidates · \(formatSize(totalBytes)) on disk"
  }

  // MARK: - Formatting

  private func formatSize(_ bytes: UInt64?) -> String {
    guard let bytes else { return "—" }
    return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
  }

  private func formatDirty(_ count: Int?) -> String {
    guard let count else { return "—" }
    return count == 0 ? "clean" : "\(count)"
  }

  private func dirtyColor(_ count: Int?) -> Color {
    guard let count, count > 0 else { return .secondary }
    return .orange
  }

  private func relativeDate(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
  }
}

// MARK: - Status badge

private struct StatusBadge: View {
  let status: WorktreeInventoryEntry.Status

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: icon)
        .foregroundStyle(tint)
      Text(label)
        .font(.caption.weight(.medium))
    }
  }

  private var icon: String {
    switch status {
    case .owned:
      return "person.fill"
    case .orphan:
      return "circle.dashed"
    case .orphanDirty:
      return "exclamationmark.circle.fill"
    case .repoRoot:
      return "folder.fill"
    }
  }

  private var tint: Color {
    switch status {
    case .owned:
      return .green
    case .orphan:
      return .gray
    case .orphanDirty:
      return .orange
    case .repoRoot:
      return .blue
    }
  }

  private var label: String {
    switch status {
    case .owned(_, let displayName):
      return displayName
    case .orphan:
      return "Orphan"
    case .orphanDirty:
      return "Orphan · dirty"
    case .repoRoot:
      return "Repo root"
    }
  }
}
