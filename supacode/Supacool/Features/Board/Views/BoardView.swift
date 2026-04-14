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
  let onAddRepository: () -> Void
  let onRenameSession: (AgentSession) -> Void

  var body: some View {
    // The repo filter moved to a toolbar popover (RepoPickerButton) next
    // to the window title. What's left here is just the grid body.
    bodyContent
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder
  private var bodyContent: some View {
    let visible = store.visibleSessions
    if visible.isEmpty {
      emptyState
    } else {
      let waiting = visible.filter { isWaitingStatus(classify($0)) }
      let inProgress = visible.filter { !isWaitingStatus(classify($0)) }
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          // "Waiting on Me" always renders — when empty it shows a subtle
          // "Nothing waiting on you" message so the bucket stays visible and
          // the board never looks like the attention-zone just vanished.
          section(
            title: "Waiting on Me",
            systemImage: "exclamationmark.circle.fill",
            color: .orange,
            sessions: waiting,
            dimmed: false,
            emptyMessage: "Nothing waiting on you."
          )
          if !inProgress.isEmpty {
            Divider()
              .padding(.vertical, 4)
          }
          section(
            title: "In Progress",
            systemImage: "circle.fill",
            color: .green,
            sessions: inProgress,
            dimmed: true,
            emptyMessage: nil
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
      if repositories.isEmpty {
        Text("No repositories yet")
          .font(.title3.weight(.medium))
          .foregroundStyle(.secondary)
        Text("Register a repository to start spawning terminals.")
          .font(.callout)
          .foregroundStyle(.tertiary)
        Button {
          onAddRepository()
        } label: {
          Label("Add Repository", systemImage: "folder.badge.plus")
        }
        .keyboardShortcut("o", modifiers: .command)
        .help("Add Repository (⌘O)")
      } else {
        Text("No terminals yet")
          .font(.title3.weight(.medium))
          .foregroundStyle(.secondary)
        Text("Press ⌘N to create a new terminal.")
          .font(.callout)
          .foregroundStyle(.tertiary)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }

  @ViewBuilder
  private func section(
    title: String,
    systemImage: String,
    color: Color,
    sessions: [AgentSession],
    dimmed: Bool,
    emptyMessage: String?
  ) -> some View {
    if sessions.isEmpty && emptyMessage == nil {
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

        if sessions.isEmpty, let emptyMessage {
          Text(emptyMessage)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .padding(.vertical, 6)
        }

        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 14)],
          spacing: 14
        ) {
          ForEach(sessions) { session in
            let sessionStatus = classify(session)
            SessionCardContainer(
              session: session,
              repositoryName: repositories[id: session.repositoryID]?.name,
              status: sessionStatus,
              dimmed: dimmed,
              isBusyNow: terminalManager.isAgentBusy(
                worktreeID: session.worktreeID,
                tabID: TerminalTabID(rawValue: session.id)
              ),
              onTap: { store.send(.focusSession(id: session.id)) },
              onRemove: { store.send(.removeSession(id: session.id)) },
              onRename: { onRenameSession(session) },
              onRerun: (sessionStatus == .detached || sessionStatus == .interrupted)
                ? {
                  store.send(
                    .rerunDetachedSession(
                      id: session.id,
                      repositories: Array(repositories)
                    )
                  )
                }
                : nil,
              onResume: ((sessionStatus == .detached || sessionStatus == .interrupted)
                && session.agent != nil
                && session.agentNativeSessionID != nil)
                ? {
                  store.send(
                    .resumeDetachedSession(
                      id: session.id,
                      repositories: Array(repositories)
                    )
                  )
                }
                : nil,
              onResumePicker: ((sessionStatus == .detached || sessionStatus == .interrupted)
                && session.agent != nil
                && session.agentNativeSessionID == nil)
                ? {
                  store.send(
                    .resumeDetachedSessionWithPicker(
                      id: session.id,
                      repositories: Array(repositories)
                    )
                  )
                }
                : nil,
              onBusyStateChange: { newBusy in
                store.send(.updateSessionBusyState(id: session.id, busy: newBusy))
              },
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
    case .waitingOnMe, .awaitingInput, .detached, .interrupted: true
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
  let dimmed: Bool
  let isBusyNow: Bool
  let onTap: () -> Void
  let onRemove: () -> Void
  let onRename: () -> Void
  let onRerun: (() -> Void)?
  let onResume: (() -> Void)?
  let onResumePicker: (() -> Void)?
  let onBusyStateChange: (Bool) -> Void
  let onBusyToIdleTransition: () -> Void

  @State private var isHovered: Bool = false

  var body: some View {
    SessionCardView(
      session: session,
      repositoryName: repositoryName,
      status: status,
      onTap: onTap,
      onRemove: onRemove,
      onRename: onRename,
      onRerun: onRerun,
      onResume: onResume,
      onResumePicker: onResumePicker
    )
    .opacity(dimmed && !isHovered ? 0.55 : 1.0)
    .animation(.easeOut(duration: 0.12), value: isHovered)
    .onHover { hovering in
      isHovered = hovering
      if hovering {
        NSCursor.pointingHand.push()
      } else {
        NSCursor.pop()
      }
    }
    .onChange(of: isBusyNow) { oldValue, newValue in
      // Persist the new busy state so relaunches can tell .detached
      // (was idle) from .interrupted (was working).
      onBusyStateChange(newValue)
      if oldValue && !newValue {
        onBusyToIdleTransition()
      }
    }
    .onAppear {
      // Reconcile: if our stored busy flag doesn't match reality at mount
      // time (e.g. freshly loaded), sync it once.
      if session.lastKnownBusy != isBusyNow {
        onBusyStateChange(isBusyNow)
      }
    }
  }
}
