import ComposableArchitecture
import Foundation
import SwiftUI

/// Browse / restore / permanent-delete sessions the user removed from
/// the board within the last 3 days. Cards expire automatically after
/// `TrashedSession.retentionWindow` — the sweeper at app launch nukes
/// anything past the window.
struct TrashSheet: View {
  @Bindable var store: StoreOf<BoardFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      content
    }
    .frame(minWidth: 460, minHeight: 360)
    .frame(maxWidth: 560, maxHeight: 600)
  }

  private var header: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text("Trash")
          .font(.title2.weight(.semibold))
        Text("Removed cards stay here for 3 days, then are permanently deleted.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if !store.trashedSessions.isEmpty {
        Button("Empty Trash", role: .destructive) {
          store.send(.emptyTrash)
        }
        .help("Permanently delete every card in the trash now.")
      }
      Button("Done") { store.send(.dismissTrashSheet) }
        .keyboardShortcut(.cancelAction)
    }
    .padding(.horizontal)
    .padding(.vertical, 12)
  }

  @ViewBuilder
  private var content: some View {
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

  private var sortedEntries: [TrashedSession] {
    store.trashedSessions.sorted { $0.trashedAt > $1.trashedAt }
  }
}

private struct TrashRow: View {
  let entry: TrashedSession
  @Bindable var store: StoreOf<BoardFeature>

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: agentIcon)
        .font(.title3)
        .foregroundStyle(.secondary)
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

  private var agentIcon: String {
    switch entry.session.agent {
    case .claude: return "sparkles"
    case .codex: return "chevron.left.forwardslash.chevron.right"
    case .none: return "terminal"
    }
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
