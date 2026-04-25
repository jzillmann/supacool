import ComposableArchitecture
import Foundation
import SwiftUI

/// Inspector + janitor for every worktree registered against a repo.
///
/// Columns: selection | name+branch | status | size | last commit |
/// ahead/behind vs the repo's default branch | dirty count | diff-stat
/// disclosure. Rows stream in progressively: identity appears first,
/// then size, then git metadata as the scan's fan-out progresses.
///
/// New in this PR:
/// - Ahead/behind column rendered from the resolved base ref
/// - Disclosure chevron per row → lazy diff-stat drawer
/// - Orphan-session banner above the table when prune reveals cards
///   whose backing dir is gone
struct WorktreeJanitorSheet: View {
  @Bindable var store: StoreOf<WorktreeJanitorFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      if store.showsOrphanBanner {
        orphanBanner
        Divider()
      }
      content
      Divider()
      footer
    }
    .frame(minWidth: 860, minHeight: 480)
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
      Button(
        "Delete \(confirmation.targets.count) worktree\(confirmation.targets.count == 1 ? "" : "s")",
        role: .destructive
      ) {
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
      Text(headerSubtitle)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 20)
    .padding(.vertical, 16)
  }

  private var headerSubtitle: String {
    let count = store.rows.count
    guard count > 0 else { return store.repositoryName }
    let suffix = count == 1 ? "1 worktree" : "\(count) worktrees"
    return "\(store.repositoryName) · \(suffix)"
  }

  // MARK: - Orphan banner

  private var orphanBanner: some View {
    HStack(spacing: 12) {
      Image(systemName: "person.crop.circle.badge.exclamationmark.fill")
        .font(.title3)
        .foregroundStyle(.orange)
      VStack(alignment: .leading, spacing: 2) {
        Text(orphanBannerTitle)
          .font(.callout.weight(.semibold))
        Text("Their backing worktrees no longer exist on disk.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button("Remove cards") {
        store.send(.removeOrphanCardsRequested)
      }
      .buttonStyle(.borderedProminent)
      .tint(.orange)
      Button {
        store.send(.dismissOrphanBanner)
      } label: {
        Image(systemName: "xmark")
          .font(.caption)
      }
      .buttonStyle(.plain)
      .help("Hide this banner")
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 10)
    .background(Color.orange.opacity(0.08))
  }

  private var orphanBannerTitle: String {
    let count = store.orphanSessionIDs.count
    return count == 1
      ? "1 session card references a missing worktree"
      : "\(count) session cards reference missing worktrees"
  }

  // MARK: - Content

  @ViewBuilder
  private var content: some View {
    if store.rows.isEmpty, store.isScanning {
      loadingPlaceholder
    } else if let error = store.scanError {
      errorPlaceholder(error)
    } else if store.rows.isEmpty {
      emptyPlaceholder
    } else {
      rowsList
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

  /// Custom list (not `Table`) so we can inline an expandable diff-stat
  /// drawer per row. `Table` lives in a grid layout that doesn't
  /// support variable-height rows.
  private var rowsList: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        rowHeader
        Divider()
        ForEach(store.sortedRows) { row in
          rowView(row)
          Divider()
        }
      }
    }
  }

  private var rowHeader: some View {
    HStack(spacing: 12) {
      Text("")
        .frame(width: 24)
      sortableHeader("Name", column: .name)
        .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
      sortableHeader("Status", column: .status)
        .frame(width: 120, alignment: .leading)
      sortableHeader("Size", column: .size, alignment: .trailing)
        .frame(width: 80, alignment: .trailing)
      sortableHeader("Last Commit", column: .lastCommit)
        .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
      sortableHeader("± base", column: .aheadBehind, alignment: .trailing)
        .frame(width: 80, alignment: .trailing)
      sortableHeader("Dirty", column: .dirty, alignment: .trailing)
        .frame(width: 64, alignment: .trailing)
      Text("")
        .frame(width: 24)
    }
    .font(.caption.weight(.semibold))
    .foregroundStyle(.secondary)
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .background(Color.secondary.opacity(0.06))
  }

  /// Column-header button that toggles sort direction on the same
  /// column or selects a new one. Shows an inline ↑/↓ chevron when its
  /// column is the active sort key.
  private func sortableHeader(
    _ title: String,
    column: WorktreeJanitorFeature.SortColumn,
    alignment: HorizontalAlignment = .leading
  ) -> some View {
    let isActive = store.sortColumn == column
    return Button {
      store.send(.sortColumnTapped(column))
    } label: {
      HStack(spacing: 4) {
        if alignment == .trailing { Spacer(minLength: 0) }
        Text(title)
        if isActive {
          Image(systemName: store.sortAscending ? "chevron.up" : "chevron.down")
            .font(.caption2.weight(.bold))
            .accessibilityHidden(true)
        }
        if alignment == .leading { Spacer(minLength: 0) }
      }
      .foregroundStyle(isActive ? Color.primary : Color.secondary)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(sortHelp(for: column, isActive: isActive))
  }

  private func sortHelp(
    for column: WorktreeJanitorFeature.SortColumn,
    isActive: Bool
  ) -> String {
    guard isActive else { return "Sort by \(column.displayName)" }
    return store.sortAscending
      ? "Sorted \(column.displayName) ascending — click for descending"
      : "Sorted \(column.displayName) descending — click for ascending"
  }

  private func rowView(_ row: WorktreeInventoryEntry) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 12) {
        SelectionToggle(
          row: row,
          isSelected: store.selectedIDs.contains(row.id),
          isDeleting: store.deletingIDs.contains(row.id),
          onToggle: { store.send(.toggleSelection(id: row.id)) }
        )
        .frame(width: 24)

        nameCell(row)
          .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)

        StatusBadge(status: row.status)
          .frame(width: 120, alignment: .leading)

        Text(formatSize(row.sizeBytes))
          .font(.callout.monospacedDigit())
          .foregroundStyle(row.sizeBytes == nil ? .secondary : .primary)
          .frame(width: 80, alignment: .trailing)

        lastCommitCell(row.lastCommit)
          .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)

        aheadBehindCell(row.aheadBehind)
          .frame(width: 80, alignment: .trailing)

        Text(formatDirty(row.uncommittedCount))
          .font(.callout.monospacedDigit())
          .foregroundStyle(dirtyColor(row.uncommittedCount))
          .frame(width: 64, alignment: .trailing)

        disclosureButton(row)
          .frame(width: 24)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .opacity(store.deletingIDs.contains(row.id) ? 0.4 : 1.0)
      .contentShape(Rectangle())

      if store.expandedRowID == row.id {
        diffStatDrawer(for: row)
      }
    }
  }

  private func nameCell(_ row: WorktreeInventoryEntry) -> some View {
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

  private func lastCommitCell(_ commit: WorktreeInventoryEntry.LastCommit?) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      if let commit {
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

  @ViewBuilder
  private func aheadBehindCell(_ value: WorktreeInventoryEntry.AheadBehind?) -> some View {
    if let value {
      HStack(spacing: 4) {
        if value.ahead > 0 {
          Label("\(value.ahead)", systemImage: "arrow.up")
            .labelStyle(.titleAndIcon)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.green)
        }
        if value.behind > 0 {
          Label("\(value.behind)", systemImage: "arrow.down")
            .labelStyle(.titleAndIcon)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.red)
        }
        if value.ahead == 0, value.behind == 0 {
          Text("in sync")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    } else {
      Text("—")
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private func disclosureButton(_ row: WorktreeInventoryEntry) -> some View {
    // Only worktrees with a sensible diff target (i.e. not the repo
    // root — its diff vs. the base branch is what a PR would look
    // like, not disk-reclaim context) get the chevron.
    if case .repoRoot = row.status {
      Spacer()
    } else {
      Button {
        store.send(.toggleRowExpansion(id: row.id))
      } label: {
        Image(systemName: store.expandedRowID == row.id ? "chevron.down" : "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .help(store.expandedRowID == row.id ? "Collapse" : "Show diff vs \(store.baseRef)")
    }
  }

  @ViewBuilder
  private func diffStatDrawer(for row: WorktreeInventoryEntry) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Text("git diff --stat")
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
        Text(store.baseRef + "...HEAD")
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
        Spacer()
      }
      if store.loadingDiffStatIDs.contains(row.id) {
        HStack(spacing: 6) {
          ProgressView().controlSize(.small)
          Text("Loading diff…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } else if let stat = row.diffStat {
        Text(stat)
          .font(.caption.monospaced())
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        Text("—")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 56)
    .padding(.bottom, 10)
    .padding(.top, 2)
    .background(Color.secondary.opacity(0.04))
  }

  // MARK: - Footer

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
    if !store.deletingIDs.isEmpty {
      deleteProgressLabel
    } else if !store.deleteErrors.isEmpty {
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

  private var deleteProgressLabel: some View {
    let total = store.deleteScheduledTotal
    let remaining = store.deletingIDs.count
    let completed = max(0, total - remaining)
    return HStack(spacing: 8) {
      ProgressView().controlSize(.small)
      Text("Deleting \(completed) of \(total)…")
        .font(.caption.weight(.medium))
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
    let prunedSuffix =
      store.prunedRefCount == 0
      ? ""
      : " · pruned \(store.prunedRefCount) stale record\(store.prunedRefCount == 1 ? "" : "s")"
    return
      "\(store.rows.count) worktrees · \(candidateCount) candidates · \(formatSize(totalBytes)) on disk\(prunedSuffix)"
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
        .lineLimit(1)
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
