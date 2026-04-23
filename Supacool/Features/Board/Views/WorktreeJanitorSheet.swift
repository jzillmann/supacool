import ComposableArchitecture
import Foundation
import SwiftUI

/// Inspector + janitor for every worktree registered against a repo.
///
/// Renders one row per worktree with classification badge, disk size,
/// last-commit summary, and dirty-file count. Rows fill in progressively
/// as the reducer's scan streams size + git metadata per row — the
/// sheet is immediately interactive even on a 47-worktree repo where a
/// full `du -sk` sweep takes 30+ seconds.
///
/// PR3 adds a leading checkbox column on candidate rows (orphan /
/// orphan-dirty). Selecting rows lights up a destructive Delete action
/// in the footer that surfaces a confirmation dialog before firing.
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
    .frame(minWidth: 780, minHeight: 460)
    .task {
      store.send(.scanRequested)
    }
    .confirmationDialog(
      confirmationTitle,
      isPresented: Binding(
        get: { store.deleteConfirmation != nil },
        set: { if !$0 { store.send(.deleteConfirmationCancelled) } }
      ),
      presenting: store.deleteConfirmation
    ) { confirmation in
      Button("Delete \(confirmation.targets.count) worktree\(confirmation.targets.count == 1 ? "" : "s")", role: .destructive) {
        store.send(.deleteConfirmed)
      }
      Button("Cancel", role: .cancel) {
        store.send(.deleteConfirmationCancelled)
      }
    } message: { confirmation in
      Text(confirmationMessage(confirmation))
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
      TableColumn("") { row in
        SelectionToggle(
          row: row,
          isSelected: store.selectedIDs.contains(row.id),
          isDeleting: store.deletingIDs.contains(row.id),
          onToggle: { store.send(.toggleSelection(id: row.id)) }
        )
      }
      .width(24)

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
        .opacity(store.deletingIDs.contains(row.id) ? 0.4 : 1.0)
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

  @ViewBuilder
  private var footer: some View {
    HStack(alignment: .center, spacing: 12) {
      footerLeading
      Spacer()
      footerTrailing
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
  }

  @ViewBuilder
  private var footerLeading: some View {
    if !store.deleteErrors.isEmpty {
      deleteErrorLabel
    } else if store.isScanning {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Measuring \(store.rows.count) worktrees…")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    } else if !store.selectedIDs.isEmpty {
      selectionSummary
    } else if !store.rows.isEmpty {
      Text(idleSummary)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var deleteErrorLabel: some View {
    HStack(alignment: .top, spacing: 6) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
      VStack(alignment: .leading, spacing: 2) {
        Text("\(store.deleteErrors.count) delete\(store.deleteErrors.count == 1 ? "" : "s") failed")
          .font(.caption.weight(.semibold))
        // Show the first failure message inline; the rest are logged.
        if let first = store.deleteErrors.first {
          Text(first)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .textSelection(.enabled)
        }
      }
    }
  }

  private var selectionSummary: some View {
    Text(
      "\(store.selectedIDs.count) selected · reclaim ~\(formatSize(store.selectedReclaimBytes))"
    )
    .font(.caption.weight(.medium))
    .foregroundStyle(.primary)
  }

  @ViewBuilder
  private var footerTrailing: some View {
    if !store.selectedIDs.isEmpty {
      Button("Clear") {
        store.send(.clearSelection)
      }
      .buttonStyle(.bordered)
      Button(role: .destructive) {
        store.send(.deleteSelectedRequested)
      } label: {
        Text("Delete \(store.selectedIDs.count)…")
      }
      .buttonStyle(.borderedProminent)
      .tint(.red)
      .disabled(!store.deletingIDs.isEmpty)
    }
    Button("Done") {
      store.send(.closeRequested)
    }
    .keyboardShortcut(.defaultAction)
  }

  private var idleSummary: String {
    let candidateCount = store.rows.filter(\.isDeletionCandidate).count
    let totalBytes = store.rows.reduce(UInt64(0)) { acc, row in
      acc + (row.sizeBytes ?? 0)
    }
    return "\(store.rows.count) worktrees · \(candidateCount) candidates · \(formatSize(totalBytes)) on disk"
  }

  // MARK: - Confirmation dialog

  private var confirmationTitle: String {
    guard let confirmation = store.deleteConfirmation else {
      return "Delete worktrees?"
    }
    let count = confirmation.targets.count
    return count == 1
      ? "Delete \"\(confirmation.targets[0].name)\"?"
      : "Delete \(count) worktrees?"
  }

  private func confirmationMessage(
    _ confirmation: WorktreeJanitorFeature.DeleteConfirmation
  ) -> String {
    var lines: [String] = []
    lines.append(
      "Removing \(confirmation.targets.count) worktree\(confirmation.targets.count == 1 ? "" : "s") will reclaim about \(formatSize(confirmation.totalBytes))."
    )
    if confirmation.hasDirty {
      lines.append("⚠️ One or more selected worktrees have uncommitted changes.")
    }
    lines.append("Branches are kept — only the worktree directories are removed.")
    return lines.joined(separator: "\n\n")
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

// MARK: - Selection toggle

/// Leading checkbox. Renders nothing for non-candidate rows so the repo
/// root + owned sessions visually can't be picked. Dimmed spinner
/// replaces the checkbox for rows currently mid-delete.
private struct SelectionToggle: View {
  let row: WorktreeInventoryEntry
  let isSelected: Bool
  let isDeleting: Bool
  let onToggle: () -> Void

  var body: some View {
    if isDeleting {
      ProgressView()
        .controlSize(.small)
        .help("Deleting…")
    } else if row.isDeletionCandidate {
      Button {
        onToggle()
      } label: {
        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
          .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(isSelected ? "Deselect" : "Select for deletion")
    } else {
      // Non-candidate rows (owned / repo root) render a disabled
      // placeholder so the column width stays stable.
      Image(systemName: "square")
        .foregroundStyle(.tertiary)
        .opacity(0.35)
    }
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
