import ComposableArchitecture
import Foundation
import SwiftUI

/// Unified cleanup dialog with two lanes:
/// - Trash: restore or permanently delete removed session cards.
/// - Worktrees: run janitor cleanup for repository worktrees.
struct TrashSheet: View {
  @Bindable var store: StoreOf<BoardFeature>
  let repositories: IdentifiedArrayOf<Repository>

  @State private var section: CleanupSection = .trash
  @State private var selectedRepositoryID: Repository.ID?

  nonisolated enum CleanupSection: String, CaseIterable, Identifiable {
    case trash
    case worktrees

    var id: String { rawValue }

    var title: String {
      switch self {
      case .trash: "Trash"
      case .worktrees: "Worktrees"
      }
    }

    var subtitle: String {
      switch self {
      case .trash:
        "Removed cards stay here for 3 days, then are permanently deleted."
      case .worktrees:
        "Inspect and clean stale worktrees for a repository."
      }
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      content
    }
    .frame(
      minWidth: section == .trash ? 460 : 900,
      minHeight: section == .trash ? 360 : 560
    )
    .onAppear {
      prepareRepositorySelectionIfNeeded()
      activateWorktreeJanitorIfNeeded()
    }
    .onChange(of: section) { _, _ in
      prepareRepositorySelectionIfNeeded()
      activateWorktreeJanitorIfNeeded()
    }
    .onChange(of: selectedRepositoryID) { _, _ in
      activateWorktreeJanitorIfNeeded()
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 2) {
          Text(section.title)
            .font(.title2.weight(.semibold))
          Text(section.subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if section == .trash, !store.trashedSessions.isEmpty {
          Button("Empty Trash", role: .destructive) {
            store.send(.emptyTrash)
          }
          .help("Permanently delete every card in the trash now.")
        }
        Button("Done") { store.send(.dismissTrashSheet) }
          .keyboardShortcut(.cancelAction)
      }

      Picker("Cleanup Section", selection: $section) {
        ForEach(CleanupSection.allCases) { section in
          Text(section.title).tag(section)
        }
      }
      .pickerStyle(.segmented)

      if section == .worktrees, !repositories.isEmpty {
        Picker("Repository", selection: selectedRepositoryBinding) {
          ForEach(repositories) { repository in
            Text(repository.name).tag(repository.id)
          }
        }
        .pickerStyle(.menu)
      }
    }
    .padding(.horizontal)
    .padding(.vertical, 12)
  }

  @ViewBuilder
  private var content: some View {
    switch section {
    case .trash:
      trashContent
    case .worktrees:
      worktreesContent
    }
  }

  @ViewBuilder
  private var trashContent: some View {
    if store.trashedSessions.isEmpty {
      VStack(spacing: 8) {
        Image(systemName: "trash")
          .font(.largeTitle)
          .foregroundStyle(.tertiary)
        Text("Trash is empty.")
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 8) {
          ForEach(sortedEntries, id: \.id) { entry in
            TrashRow(entry: entry, store: store)
          }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
      }
    }
  }

  @ViewBuilder
  private var worktreesContent: some View {
    if repositories.isEmpty {
      VStack(spacing: 8) {
        Image(systemName: "folder.badge.questionmark")
          .font(.largeTitle)
          .foregroundStyle(.tertiary)
        Text("Add a repository first to manage worktrees.")
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if store.worktreeJanitor == nil {
      VStack(spacing: 8) {
        ProgressView()
        Text("Loading worktrees…")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      IfLetStore(
        store.scope(state: \.$worktreeJanitor, action: \.worktreeJanitor)
      ) { janitorStore in
        WorktreeJanitorSheet(store: janitorStore, showsDoneButton: false)
      }
    }
  }

  private var sortedEntries: [TrashedSession] {
    store.trashedSessions.sorted { $0.trashedAt > $1.trashedAt }
  }

  private var selectedRepositoryBinding: Binding<Repository.ID> {
    Binding(
      get: {
        selectedRepository?.id
          ?? repositories.first?.id
          ?? ""
      },
      set: { selectedRepositoryID = $0 }
    )
  }

  private var selectedRepository: Repository? {
    if let selectedRepositoryID,
      let repository = repositories[id: selectedRepositoryID]
    {
      return repository
    }
    return repositories.first
  }

  private func prepareRepositorySelectionIfNeeded() {
    guard selectedRepositoryID == nil else { return }
    selectedRepositoryID = repositories.first?.id
  }

  private func activateWorktreeJanitorIfNeeded() {
    guard section == .worktrees,
      let repository = selectedRepository
    else {
      return
    }
    store.send(
      .openWorktreeJanitor(
        repositoryID: repository.id,
        repositoryName: repository.name
      )
    )
  }
}

private struct TrashRow: View {
  let entry: TrashedSession
  @Bindable var store: StoreOf<BoardFeature>

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      AgentIconView(agent: entry.session.agent, size: 18)
        .frame(width: 22, alignment: .center)
        .padding(.top, 2)

      VStack(alignment: .leading, spacing: 4) {
        Text(entry.session.displayName)
          .font(.headline)
          .lineLimit(1)
        if !entry.session.initialPrompt.isEmpty {
          Text(entry.session.initialPrompt)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        HStack(spacing: 6) {
          Text(expiryText)
            .font(.caption.monospacedDigit())
            .foregroundStyle(expiryColor)
          if entry.deleteBackingWorktree {
            Text("· will delete worktree")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }

      Spacer()

      VStack(spacing: 6) {
        Button("Restore") { store.send(.restoreFromTrash(id: entry.id)) }
        Button("Delete", role: .destructive) {
          store.send(.deleteFromTrash(id: entry.id))
        }
      }
      .controlSize(.small)
    }
    .padding(10)
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  private var expiryText: String {
    let remaining = entry.expiresAt().timeIntervalSinceNow
    if remaining <= 0 {
      return "Pending sweep"
    }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return "Nukes " + formatter.localizedString(for: entry.expiresAt(), relativeTo: Date())
  }

  private var expiryColor: Color {
    let remaining = entry.expiresAt().timeIntervalSinceNow
    if remaining < 24 * 60 * 60 {
      return .orange
    }
    return .secondary
  }
}
