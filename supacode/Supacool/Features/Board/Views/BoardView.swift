import ComposableArchitecture
import SwiftUI

/// The Matrix Board — a single full-window view showing agent sessions as
/// cards, split into two sections: "Waiting on Me" (top) and "In Progress"
/// (bottom). The repo filter chip bar sits at the top. The `+ New Terminal`
/// button is in the toolbar (added by BoardRootView).
struct BoardView: View {
  @Bindable var store: StoreOf<BoardFeature>
  let repositories: IdentifiedArrayOf<Repository>

  /// Callback to classify a session. Injected by BoardRootView which has
  /// access to WorktreeTerminalManager and can check agent-busy state.
  /// Phase 4b uses a static classifier (everything .fresh); Phase 4d wires
  /// the live classifier.
  let classify: (AgentSession) -> SessionCardView.Status

  var body: some View {
    VStack(spacing: 0) {
      RepoFilterHeaderView(
        repositories: repositories,
        filters: store.filters,
        onToggleRepository: { store.send(.toggleRepository(id: $0)) },
        onShowAll: { store.send(.showAllRepositories) }
      )
      Divider()
      bodyContent
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder
  private var bodyContent: some View {
    let visible = store.visibleSessions
    if visible.isEmpty {
      emptyState
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          section(
            title: "Waiting on Me",
            systemImage: "exclamationmark.circle.fill",
            color: .orange,
            sessions: visible.filter { isWaitingStatus(classify($0)) }
          )
          section(
            title: "In Progress",
            systemImage: "circle.fill",
            color: .green,
            sessions: visible.filter { !isWaitingStatus(classify($0)) }
          )
        }
        .padding(20)
      }
    }
  }

  private var emptyState: some View {
    VStack(spacing: 14) {
      Image(systemName: "square.grid.3x3")
        .font(.system(size: 42))
        .foregroundStyle(.tertiary)
      Text("No terminals yet")
        .font(.title3.weight(.medium))
        .foregroundStyle(.secondary)
      Text("Press ⌘N to create a new terminal.")
        .font(.callout)
        .foregroundStyle(.tertiary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }

  @ViewBuilder
  private func section(
    title: String,
    systemImage: String,
    color: Color,
    sessions: [AgentSession]
  ) -> some View {
    if sessions.isEmpty {
      EmptyView()
    } else {
      VStack(alignment: .leading, spacing: 12) {
        Label {
          Text(title)
            .font(.headline)
            .foregroundStyle(.secondary)
          Text("(\(sessions.count))")
            .font(.subheadline)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
        } icon: {
          Image(systemName: systemImage)
            .foregroundStyle(color)
        }

        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 14)],
          spacing: 14
        ) {
          ForEach(sessions) { session in
            SessionCardView(
              session: session,
              repositoryName: repositories[id: session.repositoryID]?.name,
              status: classify(session),
              onTap: { store.send(.focusSession(id: session.id)) },
              onRemove: { store.send(.removeSession(id: session.id)) }
            )
          }
        }
      }
    }
  }

  private func isWaitingStatus(_ status: SessionCardView.Status) -> Bool {
    switch status {
    case .waitingOnMe, .detached: true
    case .inProgress, .fresh: false
    }
  }
}
