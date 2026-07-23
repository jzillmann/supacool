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

  /// Per-card frames in the board's shared coordinate space. Populated by
  /// each card via `BoardCardFramesKey`; read by Up/Down navigation so
  /// arrow keys jump to the card directly above/below (not just the next
  /// one in flat index order).
  @State private var cardFrames: [AgentSession.ID: CGRect] = [:]

  /// Whether the Standby / Parked pill-row buckets are expanded. Sticky
  /// within a board session (e.g. across scroll / nav into a full-screen
  /// terminal and back); resets to collapsed on app relaunch so the
  /// dormant sections stay out of the way by default.
  @State private var standbyBucketExpanded: Bool = false
  @State private var parkedBucketExpanded: Bool = false

  /// Whether the frozen deck is fanned out into individual cards. Deliberately
  /// view-local and non-persisted: the deck exists to absorb the post-relaunch
  /// flood of detached cards, so every launch should start it collapsed.
  @State private var frozenDeckExpanded: Bool = false

  /// Visible width of each bucket's carousel rail, keyed by section title.
  /// Populated via `onScrollGeometryChange`. Used to suppress the
  /// reveal-highlighted-card scroll when every card already fits — that
  /// scroll otherwise nudges the rail off its zero rest position and clips
  /// the leftmost card's left edge.
  @State private var carouselViewportWidth: [String: CGFloat] = [:]

  /// Bucket layout mode, shared with the toolbar toggle in BoardRootView
  /// via the same UserDefaults key (⇧⌘M). Carousel (default) renders each
  /// bucket as one horizontally scrolling rail; matrix wraps the cards
  /// into a grid so every session is visible at once.
  @AppStorage("supacool.boardMatrixLayout") private var matrixLayoutEnabled: Bool = false

  private let boardReorderAnimation = Animation.spring(response: 0.34, dampingFraction: 0.84)
  private let boardCardWidth: CGFloat = 280
  private let boardCarouselSpacing: CGFloat = 14
  private static let boardGridCoordSpace = "BoardGrid"
  /// Scroll identity for the frozen deck. Distinct from the `AgentSession.ID`
  /// keys the other cards use, so the rail can pin to it by name.
  private static let frozenDeckScrollID = "board.frozenDeck"

  var body: some View {
    // The repo filter moved to a toolbar popover (RepoPickerButton) next
    // to the window title. What's left here is just the board body.
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
      // ⌘/ is the "in/out" toggle: press it on the board to enter the
      // highlighted card's terminal; the full-screen view binds the same
      // ⌘/ to return here. (⌘. is reserved for next-session stepping.)
      .background(
        Button("Enter Session") {
          if let id = highlightedSessionID {
            selectedSessionIDs.removeAll()
            store.send(.focusSession(id: id))
          }
        }
        .keyboardShortcut("/", modifiers: .command)
        .hidden()
        .disabled(highlightedSessionID == nil)
      )
  }

  /// Flat visit order for arrow keys: waiting cards first, then
  /// in-progress. Recomputed on every read — cheap; the grid is small.
  /// Sessions folded into the collapsed frozen deck drop out — arrow keys
  /// must not highlight a card nobody can see.
  private var currentNavOrder: [AgentSession.ID] {
    let collapsed = Set(frozenDeckSessions.map(\.id))
    let order = BoardNavOrder.order(visibleSessions: store.visibleSessions, classify: classify)
    guard !collapsed.isEmpty else { return order }
    return order.filter { !collapsed.contains($0) }
  }

  /// The idle sessions currently folded into the deck. Empty when the deck is
  /// expanded, or when too few idle cards exist to be worth stacking.
  private var frozenDeckSessions: [AgentSession] {
    BoardFrozenDeck.members(
      visibleSessions: store.visibleSessions,
      isExpanded: frozenDeckExpanded,
      classify: classify
    )
  }

  private var visibleSessionIDSet: Set<AgentSession.ID> {
    Set(store.visibleSessions.map(\.id))
  }

  private var selectedResumeRoutes: [BoardSelectedResumeRoute] {
    BoardResumeEligibility.selectedResumeRoutes(
      sessions: store.visibleSessions,
      selectedIDs: selectedSessionIDs,
      classify: classify,
      tabExists: sessionTabExists
    )
  }

  private func hasCapturedNativeSessionID(_ session: AgentSession) -> Bool {
    BoardResumeEligibility.hasCapturedNativeSessionID(session)
  }

  private func canDirectResume(
    _ session: AgentSession,
    status: BoardSessionStatus,
    includingParked: Bool = false
  ) -> Bool {
    BoardResumeEligibility.canDirectResume(
      session,
      status: status,
      tabExists: sessionTabExists(session),
      includingParked: includingParked
    )
  }

  private func canResumeWithPicker(_ session: AgentSession, status: BoardSessionStatus) -> Bool {
    BoardResumeEligibility.canResumeWithPicker(
      session,
      status: status,
      tabExists: sessionTabExists(session)
    )
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

  private func resumeSelectedSessions(routes: [BoardSelectedResumeRoute]) {
    guard !routes.isEmpty else { return }
    let availableRepositories = Array(repositories)
    selectedSessionIDs.removeAll()
    for route in routes {
      switch route {
      case .direct(let id):
        store.send(.resumeDetachedSession(id: id, repositories: availableRepositories))
      case .picker(let id):
        store.send(.resumeDetachedSessionWithPicker(id: id, repositories: availableRepositories))
      }
    }
    store.send(.focusSession(id: nil))
  }

  /// Resume every session in the deck that can be revived automatically. The
  /// rest stay put; the user reaches them by ungrouping.
  private func resumeFrozenDeck(_ sessions: [AgentSession]) {
    resumeSelectedSessions(routes: frozenDeckResumeRoutes(sessions))
  }

  private func frozenDeckResumeRoutes(_ sessions: [AgentSession]) -> [BoardSelectedResumeRoute] {
    BoardResumeEligibility.resumeRoutes(
      sessions: sessions,
      classify: classify,
      tabExists: sessionTabExists
    )
  }

  private func setFrozenDeckExpanded(_ expanded: Bool) {
    if !expanded {
      // Cards about to disappear behind the deck must not stay selected —
      // otherwise a hidden selection quietly drives the bulk-resume routes.
      selectedSessionIDs.subtract(
        BoardFrozenDeck.members(
          visibleSessions: store.visibleSessions,
          isExpanded: false,
          classify: classify
        )
        .map(\.id)
      )
    }
    withAnimation(.easeInOut(duration: 0.2)) {
      frozenDeckExpanded = expanded
    }
    ensureHighlightValid()
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
    // Cards are top-aligned in every layout (carousel rails and matrix
    // grid rows), so cards in the same row share their top edge. Keying
    // rows off minY — not midY — keeps Up/Down from mistaking a much
    // taller same-row neighbor for the row below.
    let rowEpsilon: CGFloat = 8
    let inDirection = candidates.filter {
      direction < 0
        ? $0.frame.minY < currentFrame.minY - rowEpsilon
        : $0.frame.minY > currentFrame.minY + rowEpsilon
    }
    guard !inDirection.isEmpty else { return }
    // Nearest row first (smallest |Δy| between top edges), then nearest
    // column within that row (smallest |Δx|).
    let target = inDirection.min { lhs, rhs in
      let lhsRow = abs(lhs.frame.minY - currentFrame.minY)
      let rhsRow = abs(rhs.frame.minY - currentFrame.minY)
      if abs(lhsRow - rhsRow) > rowEpsilon {
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

  /// Tapping a bookmark whose session is already running shouldn't spawn a
  /// duplicate — instead reveal the owning card by highlighting it and
  /// scrolling it into view. Returns `true` when an existing session was
  /// found and revealed, `false` when the caller should fall through to the
  /// normal spawn path. The scroll mirrors the keyboard-highlight scroll
  /// (`onChange(of: highlightedSessionID)`), so repeated taps re-center even
  /// when the highlight id doesn't change.
  private func revealRunningBookmarkSession(_ bookmarkID: Bookmark.ID, proxy: ScrollViewProxy) -> Bool {
    guard let session = store.sessions.first(where: { $0.sourceBookmarkID == bookmarkID }) else {
      return false
    }
    highlightedSessionID = session.id
    withAnimation(.easeOut(duration: 0.18)) {
      proxy.scrollTo(session.id)
    }
    return true
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
      // The deck swallows the idle cards, but "Waiting on Me (n)" keeps
      // counting them — a collapsed pile is hidden, not gone.
      let deck = frozenDeckSessions
      let deckIDs = Set(deck.map(\.id))
      let allWaiting = BoardNavOrder.priorityFirst(live.filter { isWaitingStatus(classify($0)) })
      let waiting = deckIDs.isEmpty ? allWaiting : allWaiting.filter { !deckIDs.contains($0.id) }
      let waitingCount = allWaiting.count
      // Once expanded, the header offers the way back — otherwise a fanned-out
      // pile could only be restacked by relaunching the app.
      let canRestack = frozenDeckExpanded
        && live.filter { classify($0) == .detached && !$0.isPriority }.count >= BoardFrozenDeck.minimumCount
      let checksPending = BoardNavOrder.priorityFirst(
        live.filter { BoardNavOrder.isChecksPendingStatus(classify($0)) }
      )
      let inProgress = BoardNavOrder.priorityFirst(
        live.filter {
          let status = classify($0)
          return !isWaitingStatus(status) && !BoardNavOrder.isChecksPendingStatus(status)
        }
      )
      let parked = BoardNavOrder.priorityFirst(visible.filter { classify($0) == .parked })
      let standby = parked.filter(\.parkedActive)
      let coldParked = parked.filter { !$0.parkedActive }
      // Only show the repo caption above each card when the visible set
      // actually spans multiple repos. With a single-repo filter (or only
      // one repo on disk) the caption is implied, so we keep the cards
      // clean.
      let showsRepoLabelAbove = Set(visible.map(\.repositoryID)).count >= 2
      ScrollViewReader { boardProxy in
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
                  // Already-running bookmark → reveal its card instead of
                  // spawning a duplicate. Falls through to spawn when no
                  // session owns the bookmark yet.
                  if revealRunningBookmarkSession(bookmark.id, proxy: boardProxy) {
                    return
                  }
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
              emptyMessage: "Nothing waiting on you.",
              showsRepoLabelAbove: showsRepoLabelAbove,
              headerCount: waitingCount,
              frozenDeck: deck,
              onRestackFrozenDeck: canRestack ? { setFrozenDeckExpanded(false) } : nil
            )
            if !checksPending.isEmpty {
              Divider()
                .padding(.vertical, 4)
              section(
                title: BoardSessionStatus.waitingForChecks.label,
                systemImage: BoardSessionStatus.waitingForChecks.systemImage,
                color: BoardSessionStatus.waitingForChecks.color,
                sessions: checksPending,
                dimmed: true,
                emptyMessage: nil,
                showsRepoLabelAbove: showsRepoLabelAbove
              )
            }
            if !inProgress.isEmpty {
              Divider()
                .padding(.vertical, 4)
              section(
                title: "In Progress",
                systemImage: "circle.fill",
                color: .green,
                sessions: inProgress,
                dimmed: true,
                emptyMessage: nil,
                showsRepoLabelAbove: showsRepoLabelAbove
              )
            }
            if !standby.isEmpty || !coldParked.isEmpty {
              Divider()
                .padding(.vertical, 4)
              HStack(spacing: 8) {
                if !standby.isEmpty {
                  DormantBucketPill(
                    title: "Standby",
                    count: standby.count,
                    systemImage: "bolt.circle",
                    color: .yellow,
                    isExpanded: standbyBucketExpanded,
                    action: {
                      withAnimation(.easeInOut(duration: 0.18)) {
                        standbyBucketExpanded.toggle()
                      }
                    }
                  )
                }
                if !coldParked.isEmpty {
                  DormantBucketPill(
                    title: "Parked",
                    count: coldParked.count,
                    systemImage: "parkingsign",
                    color: .secondary,
                    isExpanded: parkedBucketExpanded,
                    action: {
                      withAnimation(.easeInOut(duration: 0.18)) {
                        parkedBucketExpanded.toggle()
                      }
                    }
                  )
                }
                Spacer()
              }
              if standbyBucketExpanded && !standby.isEmpty {
                section(
                  title: "Standby",
                  systemImage: "bolt.circle",
                  color: .yellow,
                  sessions: standby,
                  dimmed: false,
                  emptyMessage: nil,
                  hidesHeader: true,
                  showsRepoLabelAbove: showsRepoLabelAbove
                )
              }
              if parkedBucketExpanded && !coldParked.isEmpty {
                section(
                  title: "Parked",
                  systemImage: "parkingsign",
                  color: .secondary,
                  sessions: coldParked,
                  dimmed: true,
                  emptyMessage: nil,
                  hidesHeader: true,
                  showsRepoLabelAbove: showsRepoLabelAbove
                )
              }
            }
          }
          .padding(20)
        }
        .animation(boardReorderAnimation, value: boardLayoutSignature(visible: visible))
        // In matrix mode the per-bucket carousels (and their scroll
        // proxies) don't exist, so keep the keyboard-highlighted card
        // in view by scrolling the whole board instead.
        .onChange(of: highlightedSessionID) { _, newValue in
          guard matrixLayoutEnabled, let newValue else { return }
          withAnimation(.easeOut(duration: 0.18)) {
            boardProxy.scrollTo(newValue)
          }
        }
      }
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
        .accessibilityHidden(true)
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
    emptyMessage: String?,
    hidesHeader: Bool = false,
    showsRepoLabelAbove: Bool = false,
    headerCount: Int? = nil,
    frozenDeck: [AgentSession] = [],
    onRestackFrozenDeck: (() -> Void)? = nil
  ) -> some View {
    if sessions.isEmpty && frozenDeck.isEmpty && emptyMessage == nil {
      EmptyView()
    } else {
      VStack(alignment: .leading, spacing: 12) {
        if !hidesHeader {
          sectionHeader(
            title: title,
            systemImage: systemImage,
            color: color,
            count: headerCount ?? sessions.count,
            onRestackFrozenDeck: onRestackFrozenDeck
          )
        }

        if sessions.isEmpty, frozenDeck.isEmpty, emptyMessage != nil {
          WaitingEmptyPlaceholder()
            .padding(.vertical, 4)
        }

        if !sessions.isEmpty || !frozenDeck.isEmpty {
          if matrixLayoutEnabled {
            // Full matrix: wrap the bucket's cards into as many rows as
            // needed so every session is visible without horizontal
            // scrolling. Column width is pinned to the card width so the
            // grid packs exactly as many columns as fit the window.
            LazyVGrid(
              columns: [
                GridItem(
                  .adaptive(minimum: boardCardWidth, maximum: boardCardWidth),
                  spacing: boardCarouselSpacing,
                  alignment: .top
                ),
              ],
              alignment: .leading,
              spacing: boardCarouselSpacing
            ) {
              sectionCards(
                sessions: sessions,
                dimmed: dimmed,
                showsRepoLabelAbove: showsRepoLabelAbove,
                frozenDeck: frozenDeck
              )
            }
            .padding(.vertical, 2)
          } else {
            ScrollViewReader { proxy in
              ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(alignment: .top, spacing: boardCarouselSpacing) {
                  sectionCards(
                    sessions: sessions,
                    dimmed: dimmed,
                    showsRepoLabelAbove: showsRepoLabelAbove,
                    frozenDeck: frozenDeck
                  )
                }
                .scrollTargetLayout()
                .padding(.vertical, 2)
                .padding(.bottom, 14)
                // The board-wide reorder spring (`.animation(boardReorderAnimation, …)`
                // further down) must not reach this carousel's LazyHStack: SwiftUI
                // mis-reconciles lazy child frames under an inherited implicit
                // animation and paints cards stacked on top of one another — the
                // overlap originally fixed in 95075a2 (matchedGeometryEffect) that
                // creeps back via any reorder that shifts a rail's cards. Clearing
                // the transaction here keeps the rail's reflow instantaneous and
                // overlap-free; the matrix LazyVGrid reflows fine and keeps the
                // spring. Per-card hover/highlight uses scoped `.animation(_:value:)`
                // and is unaffected.
                .transaction { $0.animation = nil }
              }
              .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
              .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
              .contentMargins(.trailing, boardCardWidth / 2, for: .scrollContent)
              .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.width } action: { _, width in
                carouselViewportWidth[title] = width
                // Once we know the rail fits every card, pin it to the
                // first card so it rests at zero — this heals a rail that
                // an earlier reveal scroll already nudged off-screen. The
                // frozen deck, when present, is that first card.
                let railCount = sessions.count + (frozenDeck.isEmpty ? 0 : 1)
                guard carouselCardsWidth(count: railCount) <= width else { return }
                if !frozenDeck.isEmpty {
                  proxy.scrollTo(Self.frozenDeckScrollID, anchor: .leading)
                } else if let first = sessions.first {
                  proxy.scrollTo(first.id, anchor: .leading)
                }
              }
              .onAppear {
                scrollHighlightedCard(
                  in: sessions,
                  proxy: proxy,
                  viewportWidth: carouselViewportWidth[title],
                  extraCards: frozenDeck.isEmpty ? 0 : 1,
                  animated: false
                )
              }
              .onChange(of: highlightedSessionID) { _, _ in
                scrollHighlightedCard(
                  in: sessions,
                  proxy: proxy,
                  viewportWidth: carouselViewportWidth[title],
                  extraCards: frozenDeck.isEmpty ? 0 : 1
                )
              }
            }
          }
        }
      }
    }
  }

  /// The bucket header row: icon + title + count, the optional restack
  /// button, and the trailing spacer. Split out of `section` purely to
  /// keep that function under the length limit.
  @ViewBuilder
  private func sectionHeader(
    title: String,
    systemImage: String,
    color: Color,
    count: Int,
    onRestackFrozenDeck: (() -> Void)?
  ) -> some View {
    HStack(spacing: 10) {
      Label {
        Text(title)
          .font(.headline)
          .foregroundStyle(.secondary)
        Text("(\(count))")
          .font(.subheadline)
          .foregroundStyle(.tertiary)
          .monospacedDigit()
      } icon: {
        Image(systemName: systemImage)
          .foregroundStyle(color)
          .accessibilityHidden(true)
      }
      if let onRestackFrozenDeck {
        RestackFrozenDeckButton(action: onRestackFrozenDeck)
      }
      Spacer(minLength: 0)
    }
  }

  /// Per-card wiring shared by both bucket layouts (carousel rail and
  /// matrix grid) so the two can't drift apart.
  @ViewBuilder
  private func sectionCards(
    sessions: [AgentSession],
    dimmed: Bool,
    showsRepoLabelAbove: Bool,
    frozenDeck: [AgentSession] = []
  ) -> some View {
    let bulkResumeRoutes = selectedResumeRoutes
    if !frozenDeck.isEmpty {
      FrozenDeckCardView(
        sessions: frozenDeck,
        resumableCount: frozenDeckResumeRoutes(frozenDeck).count,
        onResumeAll: { resumeFrozenDeck(frozenDeck) },
        onExpand: { setFrozenDeckExpanded(true) }
      )
      .frame(width: boardCardWidth)
      .fixedSize(horizontal: false, vertical: true)
      .id(Self.frozenDeckScrollID)
      .transition(.opacity.combined(with: .scale(scale: 0.98)))
      // The deck stands in for cards that carry a repo caption above them.
      // Without the matching top inset it sits proud of its neighbours.
      .padding(.top, showsRepoLabelAbove ? 20 : 0)
    }
    ForEach(sessions, id: \.id) { session in
      sessionCard(
        session: session,
        dimmed: dimmed,
        showsRepoLabelAbove: showsRepoLabelAbove,
        bulkResumeRoutes: bulkResumeRoutes
      )
      .frame(width: boardCardWidth)
      // Both bucket layouts are lazy containers that propose a *concrete*
      // height to their cells (the rail's LazyHStack forwards the ScrollView
      // viewport height; the matrix LazyVGrid its computed row height). A
      // card that grows after first layout — reference chips arrive async
      // from the transcript scanner — can then never report its larger ideal
      // height back (frame(minHeight:) just echoes the proposal), so the
      // container keeps the stale height and the card's clipShape cuts off
      // the footer. fixedSize(vertical:) sizes the card to its ideal height
      // so the growth propagates and the rail/row grows with it.
      .fixedSize(horizontal: false, vertical: true)
      .id(session.id)
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

  /// One fully wired board card: status classification, debug-link
  /// routing, and every reducer hand-off for a single session.
  private func sessionCard(
    session: AgentSession,
    dimmed: Bool,
    showsRepoLabelAbove: Bool,
    bulkResumeRoutes: [BoardSelectedResumeRoute]
  ) -> some View {
    let sessionStatus = classify(session)
    let debugLink = debugLinkDescriptor(for: session)
    let onDebugLinkTap: (() -> Void)? = {
      guard let targetID = debugLink?.targetID else { return nil }
      return { store.send(.focusSession(id: targetID)) }
    }()
    let flow = flowActions(for: session, status: sessionStatus)
    let selectedResumeCount = bulkResumeRoutes.count
    return SessionCardContainer(
      session: session,
      repositoryName: repositories[id: session.repositoryID]?.name,
      pullRequest: matchedPullRequest(for: session),
      status: sessionStatus,
      serverLifecycle: store.serverLifecycleByWorkspace[session.currentWorkspacePath],
      debugLinkTitle: debugLink?.title,
      onDebugLinkTap: onDebugLinkTap,
      dimmed: dimmed,
      isHighlighted: highlightedSessionID == session.id,
      isActiveParked: session.parkedActive,
      isSelected: selectedSessionIDs.contains(session.id),
      selectedResumeCount: selectedResumeCount,
      selectedPickerResumeCount: bulkResumeRoutes.filter(\.usesPicker).count,
      onTap: { handleCardTap(session) },
      onRemove: { store.send(.requestRemoveSession(id: session.id)) },
      onRename: { onRenameSession(session) },
      onTogglePriority: { store.send(.togglePriority(id: session.id)) },
      onSetStatusOverride: { status in
        store.send(.setManualStatusOverride(id: session.id, status: status))
      },
      onRerun: flow.onRerun,
      onResume: flow.onResume,
      onResumeInPlace: flow.onResumeInPlace,
      onResumePicker: flow.onResumePicker,
      onResumeSelected: (selectedSessionIDs.contains(session.id) && selectedResumeCount > 1)
        ? { resumeSelectedSessions(routes: bulkResumeRoutes) }
        : nil,
      onPark: flow.onPark,
      onParkActive: flow.onParkActive,
      onUnpark: flow.onUnpark,
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
      onServerLifecycleRefresh: {
        store.send(.serverLifecycleStatusRequested(sessionID: session.id, force: true))
      },
      onServerLifecycleStart: {
        store.send(.serverLifecycleStartTapped(sessionID: session.id))
      },
      onServerLifecycleStop: {
        store.send(.serverLifecycleStopTapped(sessionID: session.id))
      },
      onAppear: {
        store.send(.cardAppeared(id: session.id))
        store.send(.serverLifecycleStatusRequested(sessionID: session.id, force: false))
      },
      onReferencesPopoverOpened: {
        store.send(.refreshPRReferences(id: session.id))
      },
      onRemoveReference: { reference in
        store.send(.removeReference(id: session.id, dedupeKey: reference.dedupeKey))
      },
      onAddReference: { rawText in
        store.send(.addReferences(id: session.id, rawText: rawText))
      },
      prReferenceSnapshots: store.state.prReferenceSnapshots.forReferences(
        of: session,
        pulseFallback: store.state.prPulseSnapshots
      ),
      showsRepoLabelAbove: showsRepoLabelAbove
    )
  }

  /// Optional rerun/resume/park hand-offs for one board card, derived
  /// from its classification. A `nil` closure hides the matching action.
  private struct SessionCardFlowActions {
    var onRerun: (() -> Void)?
    var onResume: (() -> Void)?
    var onResumeInPlace: (() -> Void)?
    var onResumePicker: (() -> Void)?
    var onPark: (() -> Void)?
    var onParkActive: (() -> Void)?
    var onUnpark: (() -> Void)?
  }

  private func flowActions(
    for session: AgentSession,
    status sessionStatus: BoardSessionStatus
  ) -> SessionCardFlowActions {
    let sessionHasTab = sessionTabExists(session)
    return SessionCardFlowActions(
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
      onResumeInPlace: BoardResumeEligibility.canDirectResume(
        session,
        status: sessionStatus,
        tabExists: sessionHasTab,
        includingParked: true
      )
        ? {
          store.send(
            .resumeDetachedSession(
              id: session.id,
              repositories: Array(repositories),
              focusOnComplete: false
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
        : nil
    )
  }

  /// Total width the bucket's cards occupy on the rail, ignoring the
  /// trailing content-margin slack. Used to decide whether a carousel
  /// actually overflows its viewport.
  private func carouselCardsWidth(count: Int) -> CGFloat {
    guard count > 0 else { return 0 }
    return CGFloat(count) * boardCardWidth + CGFloat(count - 1) * boardCarouselSpacing
  }

  private func scrollHighlightedCard(
    in sessions: [AgentSession],
    proxy: ScrollViewProxy,
    viewportWidth: CGFloat?,
    extraCards: Int = 0,
    animated: Bool = true
  ) {
    guard let highlightedSessionID,
      sessions.contains(where: { $0.id == highlightedSessionID })
    else { return }

    // When every card already fits the rail there is nothing to reveal.
    // Scrolling here would only nudge the rail off its zero rest position
    // and clip the leftmost card's left edge, so leave it alone — the
    // `onScrollGeometryChange` pin keeps it anchored to the first card.
    if let viewportWidth, carouselCardsWidth(count: sessions.count + extraCards) <= viewportWidth {
      return
    }

    // When the highlight IS the leading card (no frozen deck ahead of it),
    // pin it flush to `.leading` so the rail rests at zero. An *overflowing*
    // rail never fires the `onScrollGeometryChange` leading-pin, so without
    // this a nil-anchor `scrollTo` on the first card nudges it a few points
    // right — `.viewAligned` doesn't re-snap programmatic scrolls — clipping
    // its left edge/ring at the window edge. This is the common on-appear
    // case (highlight defaults to the first waiting card).
    let anchor: UnitPoint? = (extraCards == 0 && sessions.first?.id == highlightedSessionID)
      ? .leading
      : nil

    // Nil anchor scrolls the *minimal* amount needed to make the card
    // visible — so an already-visible highlight (e.g. card 2 on appear)
    // doesn't scroll at all. A `.center` anchor here re-centered the
    // highlighted card unconditionally, which pushed the leftmost card
    // half off the rail's left edge whenever a non-first card was
    // highlighted.
    if animated {
      withAnimation(.easeOut(duration: 0.18)) {
        proxy.scrollTo(highlightedSessionID, anchor: anchor)
      }
    } else {
      proxy.scrollTo(highlightedSessionID, anchor: anchor)
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
      "\(session.id.uuidString):\(classify(session).label):\(session.isPriority)"
    }
  }
}

/// Per-card frame reporter. Each card publishes its frame in the board's
/// shared coordinate space so `BoardView.moveVertical` can pick the card
/// directly above/below the current one instead of stepping through the
/// flat nav order.
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
  private enum Bucket: Equatable {
    case waiting
    case checksPending
    case inProgress
    case parked
  }

  static func isWaitingStatus(_ status: BoardSessionStatus) -> Bool {
    switch status {
    case .waitingOnMe, .awaitingInput, .detached, .interrupted, .disconnected: true
    case .inProgress, .waitingForChecks, .fresh, .parked: false
    }
  }

  /// Cards parked in the "Checks Pending" row are idle because external
  /// CI is still running, not because they need the user or the agent.
  static func isChecksPendingStatus(_ status: BoardSessionStatus) -> Bool {
    status == .waitingForChecks
  }

  /// Stable in-row ordering: all priority cards first, preserving the
  /// user's existing order within priority and regular groups.
  static func priorityFirst(_ sessions: [AgentSession]) -> [AgentSession] {
    var priority: [AgentSession] = []
    var regular: [AgentSession] = []
    for session in sessions {
      if session.isPriority {
        priority.append(session)
      } else {
        regular.append(session)
      }
    }
    return priority + regular
  }

  static func order(
    visibleSessions: [AgentSession],
    classify: (AgentSession) -> BoardSessionStatus
  ) -> [AgentSession.ID] {
    // Parked sessions are explicitly excluded from the keyboard-nav cycle
    // and the switcher's wrap-around — they live in the bottom bucket
    // and only come back into rotation after an unpark.
    let live = visibleSessions.filter { classify($0) != .parked }
    let waiting = priorityFirst(live.filter { isWaitingStatus(classify($0)) })
    let checksPending = priorityFirst(live.filter { isChecksPendingStatus(classify($0)) })
    let inProgress = priorityFirst(
      live.filter {
        let status = classify($0)
        return !isWaitingStatus(status) && !isChecksPendingStatus(status)
      }
    )
    return waiting.map(\.id) + checksPending.map(\.id) + inProgress.map(\.id)
  }

  static func nextInSameState(
    after currentID: AgentSession.ID,
    visibleSessions: [AgentSession],
    currentStatusOverride: BoardSessionStatus? = nil,
    classify: (AgentSession) -> BoardSessionStatus
  ) -> AgentSession.ID? {
    let matchingIDs = sameStateIDs(
      currentID: currentID,
      visibleSessions: visibleSessions,
      currentStatusOverride: currentStatusOverride,
      classify: classify
    )
    guard let currentIndex = matchingIDs.firstIndex(of: currentID) else { return nil }
    let nextIndex = matchingIDs.index(after: currentIndex)
    guard nextIndex < matchingIDs.endIndex else { return nil }
    return matchingIDs[nextIndex]
  }

  static func previousInSameState(
    before currentID: AgentSession.ID,
    visibleSessions: [AgentSession],
    currentStatusOverride: BoardSessionStatus? = nil,
    classify: (AgentSession) -> BoardSessionStatus
  ) -> AgentSession.ID? {
    let matchingIDs = sameStateIDs(
      currentID: currentID,
      visibleSessions: visibleSessions,
      currentStatusOverride: currentStatusOverride,
      classify: classify
    )
    guard let currentIndex = matchingIDs.firstIndex(of: currentID), currentIndex > matchingIDs.startIndex else {
      return nil
    }
    return matchingIDs[matchingIDs.index(before: currentIndex)]
  }

  private static func sameStateIDs(
    currentID: AgentSession.ID,
    visibleSessions: [AgentSession],
    currentStatusOverride: BoardSessionStatus?,
    classify: (AgentSession) -> BoardSessionStatus
  ) -> [AgentSession.ID] {
    guard let current = visibleSessions.first(where: { $0.id == currentID }) else { return [] }
    let currentStatus = currentStatusOverride ?? classify(current)
    let currentBucket = bucket(for: currentStatus)
    return priorityFirst(
      visibleSessions.filter { session in
        let status = session.id == currentID ? currentStatus : classify(session)
        return bucket(for: status) == currentBucket
      }
    )
      .map(\.id)
  }

  private static func bucket(for status: BoardSessionStatus) -> Bucket {
    if status == .parked { return .parked }
    if isChecksPendingStatus(status) { return .checksPending }
    return isWaitingStatus(status) ? .waiting : .inProgress
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
  let serverLifecycle: BoardFeature.ServerLifecycleViewState?
  let debugLinkTitle: String?
  let onDebugLinkTap: (() -> Void)?
  let dimmed: Bool
  let isHighlighted: Bool
  let isActiveParked: Bool
  let isSelected: Bool
  let selectedResumeCount: Int
  let selectedPickerResumeCount: Int
  let onTap: () -> Void
  let onRemove: () -> Void
  let onRename: () -> Void
  let onTogglePriority: () -> Void
  let onSetStatusOverride: (BoardSessionStatus?) -> Void
  let onRerun: (() -> Void)?
  let onResume: (() -> Void)?
  let onResumeInPlace: (() -> Void)?
  let onResumePicker: (() -> Void)?
  let onResumeSelected: (() -> Void)?
  let onPark: (() -> Void)?
  let onParkActive: (() -> Void)?
  let onUnpark: (() -> Void)?
  let onAutoObserverToggle: () -> Void
  let onAutoObserverPromptChanged: (String) -> Void
  let onAutoObserverRunNow: () -> Void
  let onDebug: () -> Void
  let onServerLifecycleRefresh: () -> Void
  let onServerLifecycleStart: () -> Void
  let onServerLifecycleStop: () -> Void
  let onAppear: (() -> Void)?
  let onReferencesPopoverOpened: (() -> Void)?
  let onRemoveReference: ((SessionReference) -> Void)?
  let onAddReference: ((String) -> Void)?
  /// Latest checks/Greptile snapshot per PR reference of this session.
  let prReferenceSnapshots: [String: PullRequestSnapshot]
  /// When true, render a small repo caption above the card (outside the
  /// card border, top-left). The board flips this on for every card when
  /// it sees ≥2 distinct repos in the currently visible session set,
  /// so a single-repo filter keeps the card clean.
  let showsRepoLabelAbove: Bool

  @State private var isHovered: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if showsRepoLabelAbove {
        HStack(spacing: 4) {
          Image(systemName: "folder.fill")
            .font(.caption2)
          Text(repositoryName ?? "")
            .font(.caption2)
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .foregroundStyle(.secondary)
        // Anchor the label to the card's internal content padding (14pt)
        // so its icon sits in the same column as the card's agent-icon
        // row beneath it.
        .padding(.leading, 14)
        .frame(minHeight: 14, alignment: .leading)
        .opacity(repositoryName == nil ? 0 : 0.85)
        .accessibilityLabel(repositoryName.map { "Repository: \($0)" } ?? "")
      }
      cardWithOverlays
    }
  }

  private var cardWithOverlays: some View {
    SessionCardView(
      session: session,
      repositoryName: repositoryName,
      pullRequest: pullRequest,
      status: status,
      serverLifecycle: serverLifecycle,
      onServerLifecycleRefresh: onServerLifecycleRefresh,
      onServerLifecycleStart: onServerLifecycleStart,
      onServerLifecycleStop: onServerLifecycleStop,
      isActiveParked: isActiveParked,
      debugLinkTitle: debugLinkTitle,
      onDebugLinkTap: onDebugLinkTap,
      onTap: onTap,
      onRemove: onRemove,
      onRename: onRename,
      onTogglePriority: onTogglePriority,
      onSetStatusOverride: onSetStatusOverride,
      onRerun: onRerun,
      onResume: onResume,
      onResumeInPlace: onResumeInPlace,
      onResumePicker: onResumePicker,
      onResumeSelected: onResumeSelected,
      selectedResumeCount: selectedResumeCount,
      selectedPickerResumeCount: selectedPickerResumeCount,
      onPark: onPark,
      onParkActive: onParkActive,
      onUnpark: onUnpark,
      onAutoObserverToggle: onAutoObserverToggle,
      onAutoObserverPromptChanged: onAutoObserverPromptChanged,
      onAutoObserverRunNow: onAutoObserverRunNow,
      onDebug: onDebug,
      onAppear: onAppear,
      onReferencesPopoverOpened: onReferencesPopoverOpened,
      onRemoveReference: onRemoveReference,
      onAddReference: onAddReference,
      prReferenceSnapshots: prReferenceSnapshots
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
          .accessibilityLabel("Selected")
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

/// The way back from an ungrouped frozen deck. Sits in the "Waiting on Me"
/// header only while the pile is fanned out.
private struct RestackFrozenDeckButton: View {
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label("Restack", systemImage: "rectangle.stack.fill")
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
          Capsule(style: .continuous)
            .fill(.thinMaterial)
        )
    }
    .buttonStyle(.plain)
    .help("Fold the idle sessions back into one stack")
  }
}

/// Pill-style chip used by BoardView's dormant footer. Two of these live
/// side-by-side ("Standby (n)" / "Parked (n)"); clicking one toggles the
/// matching collapsible carousel below.
private struct DormantBucketPill: View {
  let title: String
  let count: Int
  let systemImage: String
  let color: Color
  let isExpanded: Bool
  let action: () -> Void

  @State private var isHovered: Bool = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: "chevron.right")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(.tertiary)
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
          .accessibilityLabel(isExpanded ? "Expanded" : "Collapsed")
        Image(systemName: systemImage)
          .font(.system(size: 12))
          .foregroundStyle(color)
          .accessibilityHidden(true)
        Text(title)
          .font(.subheadline.weight(.medium))
          .foregroundStyle(.secondary)
        Text("(\(count))")
          .font(.subheadline)
          .foregroundStyle(.tertiary)
          .monospacedDigit()
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(
        Capsule(style: .continuous)
          .fill(.thinMaterial)
      )
      .overlay(
        Capsule(style: .continuous)
          .strokeBorder(
            Color.secondary.opacity(isHovered ? 0.35 : 0.15),
            lineWidth: 0.5
          )
      )
    }
    .buttonStyle(.plain)
    .help("\(isExpanded ? "Collapse" : "Expand") \(title.lowercased()) sessions")
    .onHover { isHovered = $0 }
  }
}
