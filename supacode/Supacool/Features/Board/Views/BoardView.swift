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
  let classify: (AgentSession) -> BoardSessionStatus
  let onAddRepository: () -> Void
  let onRenameSession: (AgentSession) -> Void

  /// Keyboard-nav cursor. Tracks the currently highlighted card; arrow
  /// keys move it, Return focuses the card (same path as a tap). Bound
  /// from BoardRootView so the selection survives the
  /// board → full-screen → board round-trip (BoardView itself is torn
  /// down and re-created during that cycle).
  @Binding var highlightedSessionID: AgentSession.ID?
  /// Must be true for `.onKeyPress` to receive anything. `.focusable()`
  /// alone makes the view focus-eligible but doesn't *grant* focus —
  /// without this FocusState binding, arrow keys just beep.
  @FocusState private var hasKeyboardFocus: Bool
  @Namespace private var cardTransitionNamespace

  private let boardReorderAnimation = Animation.spring(response: 0.34, dampingFraction: 0.84)

  var body: some View {
    // The repo filter moved to a toolbar popover (RepoPickerButton) next
    // to the window title. What's left here is just the grid body.
    bodyContent
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .focusable()
      .focusEffectDisabled()
      .focused($hasKeyboardFocus)
      .task {
        // Grant focus once the view is on screen. Without this, `.focusable()`
        // just marks the view focus-eligible — arrow keys still beep.
        hasKeyboardFocus = true
      }
      .onKeyPress(.leftArrow) { moveHighlight(by: -1); return .handled }
      .onKeyPress(.upArrow) { moveHighlight(by: -1); return .handled }
      .onKeyPress(.rightArrow) { moveHighlight(by: +1); return .handled }
      .onKeyPress(.downArrow) { moveHighlight(by: +1); return .handled }
      .onKeyPress(.return) {
        if let id = highlightedSessionID {
          store.send(.focusSession(id: id))
          return .handled
        }
        return .ignored
      }
      .onAppear { ensureHighlightValid() }
      .onChange(of: currentNavOrder) { _, _ in ensureHighlightValid() }
      // Symmetric to the full-screen terminal's ⌘. / ⌘B shortcut that
      // returns to the board: press ⌘. on the board to enter the
      // highlighted card's terminal.
      .background(
        Button("Enter Session") {
          if let id = highlightedSessionID {
            store.send(.focusSession(id: id))
          }
        }
        .keyboardShortcut(".", modifiers: .command)
        .hidden()
        .disabled(highlightedSessionID == nil)
      )
  }

  /// Flat visit order for arrow keys: waiting cards first, then
  /// in-progress. Recomputed on every read — cheap; the grid is small.
  private var currentNavOrder: [AgentSession.ID] {
    BoardNavOrder.order(visibleSessions: store.visibleSessions, classify: classify)
  }

  private func moveHighlight(by delta: Int) {
    let order = currentNavOrder
    guard !order.isEmpty else { return }
    let currentIndex = highlightedSessionID.flatMap { order.firstIndex(of: $0) } ?? -1
    let nextIndex: Int
    if currentIndex < 0 {
      // Nothing highlighted yet — step from one end of the list based on
      // travel direction so ↑/← jumps to the last card and ↓/→ to the first.
      nextIndex = delta < 0 ? order.count - 1 : 0
    } else {
      nextIndex = (currentIndex + delta + order.count) % order.count
    }
    highlightedSessionID = order[nextIndex]
  }

  private func ensureHighlightValid() {
    let order = currentNavOrder
    if let current = highlightedSessionID, order.contains(current) { return }
    highlightedSessionID = order.first
  }

  @ViewBuilder
  private var bodyContent: some View {
    let visible = store.visibleSessions
    if visible.isEmpty {
      emptyState
    } else {
      let live = visible.filter { classify($0) != .parked }
      let waiting = live.filter { isWaitingStatus(classify($0)) }
      let inProgress = live.filter { !isWaitingStatus(classify($0)) }
      let parked = visible.filter { classify($0) == .parked }
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
          if !parked.isEmpty {
            Divider()
              .padding(.vertical, 4)
            section(
              title: "Parked",
              systemImage: "parkingsign",
              color: .secondary,
              sessions: parked,
              dimmed: true,
              emptyMessage: nil
            )
          }
        }
        .padding(20)
      }
      .animation(boardReorderAnimation, value: boardLayoutSignature(visible: visible))
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
              isHighlighted: highlightedSessionID == session.id,
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
              onPark: (sessionStatus != .parked)
                ? {
                  store.send(
                    .parkSession(
                      id: session.id,
                      repositories: Array(repositories)
                    )
                  )
                }
                : nil,
              // Unpark routing:
              //   • Captured session id → one-click resume, same as
              //     detached cards with the same state.
              //   • No captured id (shell session, or agent whose id we
              //     never learned) → focus the card. The full-screen
              //     detached UI takes over with explicit Rerun / Resume
              //     via Picker / Remove buttons, matching the behavior
              //     of a non-parked detached card. This gives the user
              //     a choice rather than picking for them.
              onUnpark: (sessionStatus == .parked)
                ? {
                  if session.agent != nil && session.agentNativeSessionID != nil {
                    store.send(
                      .resumeDetachedSession(
                        id: session.id,
                        repositories: Array(repositories)
                      )
                    )
                  } else {
                    store.send(.focusSession(id: session.id))
                  }
                }
                : nil,
              onAutoObserverToggle: {
                store.send(.toggleAutoObserver(id: session.id))
              },
              onAutoObserverPromptChanged: { prompt in
                store.send(.setAutoObserverPrompt(id: session.id, prompt: prompt))
              },
              onAppear: { store.send(.cardAppeared(id: session.id)) }
            )
            .matchedGeometryEffect(id: session.id, in: cardTransitionNamespace)
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
          }
        }
      }
    }
  }

  private func isWaitingStatus(_ status: BoardSessionStatus) -> Bool {
    BoardNavOrder.isWaitingStatus(status)
  }

  private func boardLayoutSignature(visible: [AgentSession]) -> [String] {
    visible.map { session in
      "\(session.id.uuidString):\(classify(session).label)"
    }
  }
}

/// Shared nav-order helpers used by both the board's arrow-key nav and the
/// full-screen `⌘⌥`-arrow session switcher so the two stay in muscle-memory
/// sync. Cursor order is waiting-on-me first, then in-progress — matches
/// the on-screen section layout.
enum BoardNavOrder {
  static func isWaitingStatus(_ status: BoardSessionStatus) -> Bool {
    switch status {
    case .waitingOnMe, .awaitingInput, .detached, .interrupted, .disconnected: true
    case .inProgress, .fresh, .parked: false
    }
  }

  static func order(
    visibleSessions: [AgentSession],
    classify: (AgentSession) -> BoardSessionStatus
  ) -> [AgentSession.ID] {
    // Parked sessions are explicitly excluded from the keyboard-nav cycle
    // and the switcher's wrap-around — they live in the bottom bucket
    // and only come back into rotation after an unpark.
    let live = visibleSessions.filter { classify($0) != .parked }
    let waiting = live.filter { isWaitingStatus(classify($0)) }
    let inProgress = live.filter { !isWaitingStatus(classify($0)) }
    return waiting.map(\.id) + inProgress.map(\.id)
  }
}

/// Thin wrapper around SessionCardView that adds the keyboard-highlight
/// ring and hover affordances. Busy/status edge detection lives at the
/// BoardRootView level (see `SessionStateWatcher`) so it keeps firing
/// while the user is inside a full-screen terminal.
private struct SessionCardContainer: View {
  let session: AgentSession
  let repositoryName: String?
  let status: BoardSessionStatus
  let dimmed: Bool
  let isHighlighted: Bool
  let onTap: () -> Void
  let onRemove: () -> Void
  let onRename: () -> Void
  let onRerun: (() -> Void)?
  let onResume: (() -> Void)?
  let onResumePicker: (() -> Void)?
  let onPark: (() -> Void)?
  let onUnpark: (() -> Void)?
  let onAutoObserverToggle: () -> Void
  let onAutoObserverPromptChanged: (String) -> Void
  let onAppear: (() -> Void)?

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
      onResumePicker: onResumePicker,
      onPark: onPark,
      onUnpark: onUnpark,
      onAutoObserverToggle: onAutoObserverToggle,
      onAutoObserverPromptChanged: onAutoObserverPromptChanged,
      onAppear: onAppear
    )
    .opacity(dimmed && !isHovered && !isHighlighted ? 0.55 : 1.0)
    .overlay(
      // Keyboard-nav highlight ring. Uses the accent color so it's
      // visibly distinct from the per-status border colors on the card.
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(Color.accentColor, lineWidth: isHighlighted ? 2 : 0)
        .allowsHitTesting(false)
    )
    .animation(.easeOut(duration: 0.12), value: isHovered)
    .animation(.easeOut(duration: 0.08), value: isHighlighted)
    .onHover { hovering in
      isHovered = hovering
      if hovering {
        NSCursor.pointingHand.push()
      } else {
        NSCursor.pop()
      }
    }
  }
}
