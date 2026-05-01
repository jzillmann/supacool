import AppKit
import ComposableArchitecture
import SwiftUI

/// The Matrix Board — a single full-window view showing agent sessions as
/// cards, split into two sections: "Waiting on Me" (top) and "In Progress"
/// (bottom). The repo filter chip bar sits at the top. The `+ New Terminal`
/// button is in the toolbar (added by BoardRootView).
struct BoardView: View {
  @Bindable var store: StoreOf<BoardFeature>
  let repositories: IdentifiedArrayOf<Repository>
  let worktreeInfoByID: [Worktree.ID: WorktreeInfoEntry]
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
  @Binding var selectedSessionIDs: Set<AgentSession.ID>
  /// Must be true for `.onKeyPress` to receive anything. `.focusable()`
  /// alone makes the view focus-eligible but doesn't *grant* focus —
  /// without this FocusState binding, arrow keys just beep.
  @FocusState private var hasKeyboardFocus: Bool
  @Namespace private var cardTransitionNamespace

  /// Per-card frames in the board's shared coordinate space. Populated by
  /// each card via `BoardCardFramesKey`; read by Up/Down navigation so
  /// arrow keys jump to the card directly above/below (not the next one
  /// in index order — the grid is multi-column).
  @State private var cardFrames: [AgentSession.ID: CGRect] = [:]

  private let boardReorderAnimation = Animation.spring(response: 0.34, dampingFraction: 0.84)
  private static let boardGridCoordSpace = "BoardGrid"

  var body: some View {
    // The repo filter moved to a toolbar popover (RepoPickerButton) next
    // to the window title. What's left here is just the grid body.
    bodyContent
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .coordinateSpace(name: Self.boardGridCoordSpace)
      .onPreferenceChange(BoardCardFramesKey.self) { cardFrames = $0 }
      .focusable()
      .focusEffectDisabled()
      .focused($hasKeyboardFocus)
      .task {
        // Grant focus once the view is on screen. Without this, `.focusable()`
        // just marks the view focus-eligible — arrow keys still beep.
        hasKeyboardFocus = true
      }
      .onKeyPress(.leftArrow) { moveHighlight(by: -1); return .handled }
      .onKeyPress(.upArrow) { moveVertical(direction: -1); return .handled }
      .onKeyPress(.rightArrow) { moveHighlight(by: +1); return .handled }
      .onKeyPress(.downArrow) { moveVertical(direction: +1); return .handled }
      .onKeyPress(.return) {
        if let id = highlightedSessionID {
          selectedSessionIDs.removeAll()
          store.send(.focusSession(id: id))
          return .handled
        }
        return .ignored
      }
      .onKeyPress(.escape) {
        guard !selectedSessionIDs.isEmpty else { return .ignored }
        selectedSessionIDs.removeAll()
        return .handled
      }
      .onAppear { ensureHighlightValid() }
      .onChange(of: currentNavOrder) { _, _ in ensureHighlightValid() }
      .onChange(of: visibleSessionIDSet) { _, visibleIDs in
        selectedSessionIDs.formIntersection(visibleIDs)
      }
      // Symmetric to the full-screen terminal's ⌘. / ⌘B shortcut that
      // returns to the board: press ⌘. on the board to enter the
      // highlighted card's terminal.
      .background(
        Button("Enter Session") {
          if let id = highlightedSessionID {
            selectedSessionIDs.removeAll()
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

  private var visibleSessionIDSet: Set<AgentSession.ID> {
    Set(store.visibleSessions.map(\.id))
  }

  private var selectedDirectResumeSessionIDs: [AgentSession.ID] {
    guard selectedSessionIDs.count > 1 else { return [] }
    let selected = selectedSessionIDs
    return store.visibleSessions.compactMap { session in
      guard selected.contains(session.id),
        canDirectResume(session, status: classify(session), includingParked: true)
      else {
        return nil
      }
      return session.id
    }
  }

  private func hasCapturedNativeSessionID(_ session: AgentSession) -> Bool {
    guard let sessionID = session.agentNativeSessionID else { return false }
    return !sessionID.isEmpty
  }

  private func canDirectResume(
    _ session: AgentSession,
    status: BoardSessionStatus,
    includingParked: Bool = false
  ) -> Bool {
    guard session.agent != nil, hasCapturedNativeSessionID(session) else { return false }
    switch status {
    case .detached, .interrupted:
      return true
    case .parked:
      return includingParked && !sessionTabExists(session)
    default:
      return false
    }
  }

  private func canResumeWithPicker(_ session: AgentSession, status: BoardSessionStatus) -> Bool {
    guard session.agent != nil, !hasCapturedNativeSessionID(session) else { return false }
    switch status {
    case .detached, .interrupted:
      return true
    default:
      return false
    }
  }

  private func sessionTabExists(_ session: AgentSession) -> Bool {
    terminalManager.sessionTabExists(
      worktreeID: session.worktreeID,
      tabID: TerminalTabID(rawValue: session.id)
    )
  }

  private func handleCardTap(_ session: AgentSession) {
    let modifiers = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if modifiers.contains(.shift) || modifiers.contains(.command) {
      if selectedSessionIDs.contains(session.id) {
        selectedSessionIDs.remove(session.id)
      } else {
        selectedSessionIDs.insert(session.id)
      }
      highlightedSessionID = session.id
      return
    }

    selectedSessionIDs.removeAll()
    store.send(.focusSession(id: session.id))
  }

  private func resumeSelectedSessions(ids: [AgentSession.ID]) {
    guard !ids.isEmpty else { return }
    let availableRepositories = Array(repositories)
    selectedSessionIDs.removeAll()
    for id in ids {
      store.send(.resumeDetachedSession(id: id, repositories: availableRepositories))
    }
    store.send(.focusSession(id: nil))
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

  /// Spatial Up/Down — jumps to the card whose frame sits directly above
  /// or below the current one, using the per-card frames published via
  /// `BoardCardFramesKey`. Falls back to the sequential step if frames
  /// haven't been published yet (first frame after launch) or the
  /// current card has no neighbor in that direction.
  private func moveVertical(direction: Int) {
    let order = currentNavOrder
    guard !order.isEmpty else { return }
    guard let currentID = highlightedSessionID,
      let currentFrame = cardFrames[currentID]
    else {
      moveHighlight(by: direction)
      return
    }
    let eligible = Set(order)
    let candidates = cardFrames
      .filter { eligible.contains($0.key) && $0.key != currentID }
      .map { (id: $0.key, frame: $0.value) }
    // Half a card-height tolerance for "same row" — anything within
    // that band of the current card's midY is skipped so Up/Down only
    // ever crosses rows.
    let rowTolerance = currentFrame.height * 0.5
    let inDirection = candidates.filter {
      direction < 0
        ? $0.frame.midY < currentFrame.midY - rowTolerance
        : $0.frame.midY > currentFrame.midY + rowTolerance
    }
    guard !inDirection.isEmpty else { return }
    // Nearest row first (smallest |Δy|), then nearest column within that
    // row (smallest |Δx|).
    let target = inDirection.min { lhs, rhs in
      let lhsRow = abs(lhs.frame.midY - currentFrame.midY)
      let rhsRow = abs(rhs.frame.midY - currentFrame.midY)
      if abs(lhsRow - rhsRow) > rowTolerance {
        return lhsRow < rhsRow
      }
      return abs(lhs.frame.midX - currentFrame.midX)
        < abs(rhs.frame.midX - currentFrame.midX)
    }
    if let target {
      highlightedSessionID = target.id
    }
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
      if store.gettingStarted.isPresented && !store.gettingStarted.tasks.isEmpty {
        GettingStartedCarouselView(store: store)
      } else {
        emptyState
      }
    } else {
      let live = visible.filter { classify($0) != .parked }
      let waiting = live.filter { isWaitingStatus(classify($0)) }
      let inProgress = live.filter { !isWaitingStatus(classify($0)) }
      let parked = visible.filter { classify($0) == .parked }
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          // Drafts row sits ABOVE bookmarks. Always rendered when there's
          // at least one draft, regardless of the repo filter — drafts
          // are user inbox-state, not project-scoped artefacts; hiding
          // them on a filter switch would be the most reliable way to
          // forget about them.
          let visibleDrafts = store.drafts
          if !visibleDrafts.isEmpty {
            DraftPillRow(
              drafts: visibleDrafts,
              repoLabelByID: draftRepoLabels,
              onTap: { draft in
                store.send(
                  .draftTapped(
                    id: draft.id,
                    repositories: Array(repositories)
                  )
                )
              },
              onDelete: { draft in
                store.send(.draftDeleteRequested(id: draft.id))
              }
            )
          }
          // Bookmark pills render above "Waiting on Me" when a specific
          // repo is selected (not "All repos") and that repo has at
          // least one saved bookmark. Off-filter → hidden entirely so
          // the attention-zone stays tight.
          let relevantBookmarks = visibleBookmarks
          let unavailableBookmarkIDs = store.unavailableBookmarkIDs
          if !relevantBookmarks.isEmpty {
            BookmarkPillRow(
              bookmarks: relevantBookmarks,
              unavailableBookmarkIDs: unavailableBookmarkIDs,
              onTap: { bookmark in
                store.send(
                  .bookmarkTapped(
                    id: bookmark.id,
                    repositories: Array(repositories)
                  )
                )
              },
              onEdit: { bookmark in
                store.send(
                  .bookmarkEditRequested(
                    id: bookmark.id,
                    repositories: Array(repositories)
                  )
                )
              },
              onDelete: { bookmark in
                store.send(.bookmarkDeleteRequested(id: bookmark.id))
              }
            )
          }
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

  /// Bookmarks to render above "Waiting on Me". Honors the repo filter
  /// (so a single-repo selection scopes pills to that repo) and skips
  /// orphaned bookmarks whose owning repo is no longer registered.
  private var visibleBookmarks: [Bookmark] {
    store.bookmarks.filter {
      repositories[id: $0.repositoryID] != nil
        && store.filters.includes(repositoryID: $0.repositoryID)
    }
  }

  /// Repository name lookup for the draft pill's trailing repo hint.
  /// Skips drafts whose repo was unregistered after save (the pill
  /// renders without a label rather than showing a stale name).
  private var draftRepoLabels: [String: String] {
    var result: [String: String] = [:]
    for repository in repositories {
      result[repository.id] = repository.name
    }
    return result
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

        if sessions.isEmpty, emptyMessage != nil {
          WaitingEmptyPlaceholder()
            .padding(.vertical, 4)
        }

        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 14)],
          spacing: 14
        ) {
          let bulkResumeIDs = selectedDirectResumeSessionIDs
          ForEach(sessions, id: \.id) { session in
            let sessionStatus = classify(session)
            let sessionHasTab = sessionTabExists(session)
            let activeParked = session.parked && sessionHasTab
            let debugLink = debugLinkDescriptor(for: session)
            let onDebugLinkTap: (() -> Void)? = {
              guard let targetID = debugLink?.targetID else { return nil }
              return { store.send(.focusSession(id: targetID)) }
            }()
            SessionCardContainer(
              session: session,
              repositoryName: repositories[id: session.repositoryID]?.name,
              pullRequest: matchedPullRequest(for: session),
              status: sessionStatus,
              debugLinkTitle: debugLink?.title,
              onDebugLinkTap: onDebugLinkTap,
              dimmed: dimmed,
              isHighlighted: highlightedSessionID == session.id,
              isActiveParked: activeParked,
              isSelected: selectedSessionIDs.contains(session.id),
              selectedResumeCount: bulkResumeIDs.count,
              onTap: { handleCardTap(session) },
              onRemove: { store.send(.removeSession(id: session.id)) },
              onRename: { onRenameSession(session) },
              onTogglePriority: { store.send(.togglePriority(id: session.id)) },
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
              onResume: canDirectResume(session, status: sessionStatus)
                ? {
                  store.send(
                    .resumeDetachedSession(
                      id: session.id,
                      repositories: Array(repositories)
                    )
                  )
                }
                : nil,
              onResumePicker: canResumeWithPicker(session, status: sessionStatus)
                ? {
                  store.send(
                    .resumeDetachedSessionWithPicker(
                      id: session.id,
                      repositories: Array(repositories)
                    )
                  )
                }
                : nil,
              onResumeSelected: (selectedSessionIDs.contains(session.id) && bulkResumeIDs.count > 1)
                ? { resumeSelectedSessions(ids: bulkResumeIDs) }
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
              onParkActive: (sessionStatus != .parked && sessionHasTab)
                ? {
                  store.send(.parkActiveSession(id: session.id))
                }
                : nil,
              // Unpark routing:
              //   • Still has a live tab (Park as Active) → just clear
              //     the parked bit; the running terminal stays untouched.
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
                  if sessionHasTab {
                    store.send(.unparkSession(id: session.id))
                  } else if session.agent != nil && hasCapturedNativeSessionID(session) {
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
              onAutoObserverRunNow: {
                store.send(.autoObserverTriggered(id: session.id))
              },
              onDebug: {
                store.send(
                  .debugSessionRequested(
                    id: session.id,
                    repositories: Array(repositories)
                  )
                )
              },
              onAppear: { store.send(.cardAppeared(id: session.id)) }
            )
            .matchedGeometryEffect(id: session.id, in: cardTransitionNamespace)
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
            .background(
              // Publishes this card's frame in the board's shared
              // coordinate space so Up/Down can jump spatially — see
              // `moveVertical`.
              GeometryReader { geo in
                Color.clear.preference(
                  key: BoardCardFramesKey.self,
                  value: [session.id: geo.frame(in: .named(Self.boardGridCoordSpace))]
                )
              }
            )
          }
        }
      }
    }
  }

  private func matchedPullRequest(for session: AgentSession) -> GithubPullRequest? {
    guard let repo = repositories[id: session.repositoryID] else { return nil }
    let rootPath = repo.rootURL.standardizedFileURL.path(percentEncoded: false)
    let workspacePath = session.currentWorkspacePath
    guard workspacePath != rootPath else { return nil }
    guard let worktree = repo.worktrees.first(where: { $0.id == workspacePath }) else {
      return nil
    }
    guard let pullRequest = worktreeInfoByID[workspacePath]?.pullRequest else { return nil }
    guard pullRequest.headRefName == nil || pullRequest.headRefName == worktree.name else {
      return nil
    }
    return pullRequest
  }

  private struct SessionDebugLinkDescriptor {
    let title: String
    let targetID: AgentSession.ID
  }

  private func debugLinkDescriptor(for session: AgentSession) -> SessionDebugLinkDescriptor? {
    if let sourceID = session.debugSourceSessionID,
      let source = store.sessions.first(where: { $0.id == sourceID })
    {
      return SessionDebugLinkDescriptor(
        title: "Debug of: \(source.displayName)",
        targetID: source.id
      )
    }

    let latestChild = store.sessions
      .filter { $0.debugSourceSessionID == session.id }
      .sorted { $0.createdAt > $1.createdAt }
      .first
    guard let latestChild else { return nil }
    return SessionDebugLinkDescriptor(
      title: "Debug session: \(latestChild.displayName)",
      targetID: latestChild.id
    )
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

/// Per-card frame reporter. Each card publishes its frame in the board's
/// shared coordinate space so `BoardView.moveVertical` can pick the card
/// directly above/below the current one instead of stepping through the
/// flat nav order (which gives the wrong result on a multi-column grid).
private struct BoardCardFramesKey: PreferenceKey {
  static let defaultValue: [AgentSession.ID: CGRect] = [:]
  static func reduce(
    value: inout [AgentSession.ID: CGRect],
    nextValue: () -> [AgentSession.ID: CGRect]
  ) {
    value.merge(nextValue(), uniquingKeysWith: { _, new in new })
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
  let pullRequest: GithubPullRequest?
  let status: BoardSessionStatus
  let debugLinkTitle: String?
  let onDebugLinkTap: (() -> Void)?
  let dimmed: Bool
  let isHighlighted: Bool
  let isActiveParked: Bool
  let isSelected: Bool
  let selectedResumeCount: Int
  let onTap: () -> Void
  let onRemove: () -> Void
  let onRename: () -> Void
  let onTogglePriority: () -> Void
  let onRerun: (() -> Void)?
  let onResume: (() -> Void)?
  let onResumePicker: (() -> Void)?
  let onResumeSelected: (() -> Void)?
  let onPark: (() -> Void)?
  let onParkActive: (() -> Void)?
  let onUnpark: (() -> Void)?
  let onAutoObserverToggle: () -> Void
  let onAutoObserverPromptChanged: (String) -> Void
  let onAutoObserverRunNow: () -> Void
  let onDebug: () -> Void
  let onAppear: (() -> Void)?

  @State private var isHovered: Bool = false

  var body: some View {
    SessionCardView(
      session: session,
      repositoryName: repositoryName,
      pullRequest: pullRequest,
      status: status,
      isActiveParked: isActiveParked,
      debugLinkTitle: debugLinkTitle,
      onDebugLinkTap: onDebugLinkTap,
      onTap: onTap,
      onRemove: onRemove,
      onRename: onRename,
      onTogglePriority: onTogglePriority,
      onRerun: onRerun,
      onResume: onResume,
      onResumePicker: onResumePicker,
      onResumeSelected: onResumeSelected,
      selectedResumeCount: selectedResumeCount,
      onPark: onPark,
      onParkActive: onParkActive,
      onUnpark: onUnpark,
      onAutoObserverToggle: onAutoObserverToggle,
      onAutoObserverPromptChanged: onAutoObserverPromptChanged,
      onAutoObserverRunNow: onAutoObserverRunNow,
      onDebug: onDebug,
      onAppear: onAppear
    )
    .opacity(dimmed && !isHovered && !isHighlighted && !isSelected ? 0.55 : 1.0)
    .overlay {
      if isSelected {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(Color.accentColor.opacity(0.08))
          .allowsHitTesting(false)
      }
    }
    .overlay(
      // Keyboard-nav / multi-selection ring. Uses the accent color so it's
      // visibly distinct from the per-status border colors on the card.
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(Color.accentColor, lineWidth: (isHighlighted || isSelected) ? 2 : 0)
        .allowsHitTesting(false)
    )
    .overlay(alignment: .topTrailing) {
      if isSelected {
        Image(systemName: "checkmark.circle.fill")
          .font(.caption)
          .foregroundStyle(Color.accentColor)
          .background(Circle().fill(.background))
          .padding(6)
          .allowsHitTesting(false)
      }
    }
    .animation(.easeOut(duration: 0.12), value: isHovered)
    .animation(.easeOut(duration: 0.08), value: isHighlighted)
    .animation(.easeOut(duration: 0.08), value: isSelected)
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
