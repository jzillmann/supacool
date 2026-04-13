import ComposableArchitecture
import SwiftUI

/// The Matrix Board — a single full-window view showing agent sessions as
/// cards, split into two sections: "Waiting on Me" (top) and "In Progress"
/// (bottom). The repo filter chip bar sits at the top. The `+ New Terminal`
/// button is in the toolbar (added by BoardRootView).
struct BoardView: View {
  @Bindable var store: StoreOf<BoardFeature>
  let repositories: IdentifiedArrayOf<Repository>
  let terminalManager: WorktreeTerminalManager
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
            SessionCardContainer(
              session: session,
              repositoryName: repositories[id: session.repositoryID]?.name,
              status: classify(session),
              isBusyNow: terminalManager.isAgentBusy(
                worktreeID: session.worktreeID,
                tabID: TerminalTabID(rawValue: session.id)
              ),
              onTap: { store.send(.focusSession(id: session.id)) },
              onRemove: { store.send(.removeSession(id: session.id)) },
              onBusyToIdleTransition: {
                if !session.hasCompletedAtLeastOnce {
                  store.send(.markSessionCompletedOnce(id: session.id))
                }
              }
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

/// Thin wrapper around SessionCardView that watches the underlying agent
/// busy state per session so we can detect the busy→idle transition and
/// mark `hasCompletedAtLeastOnce`. Without this, a session never leaves
/// the "fresh" grace period bucket.
private struct SessionCardContainer: View {
  let session: AgentSession
  let repositoryName: String?
  let status: SessionCardView.Status
  let isBusyNow: Bool
  let onTap: () -> Void
  let onRemove: () -> Void
  let onBusyToIdleTransition: () -> Void

  var body: some View {
    SessionCardView(
      session: session,
      repositoryName: repositoryName,
      status: status,
      onTap: onTap,
      onRemove: onRemove
    )
    .onChange(of: isBusyNow) { oldValue, newValue in
      if oldValue && !newValue {
        onBusyToIdleTransition()
      }
    }
  }
}
