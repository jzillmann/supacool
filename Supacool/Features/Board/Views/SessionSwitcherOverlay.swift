import AppKit
import ComposableArchitecture
import SwiftUI

/// Translucent ⌘-Tab-style session switcher. Opened from
/// `FullScreenTerminalView` via `⌘←/→/↑/↓`; lets the user cycle the cursor
/// through sessions while `⌘` is held, then commits on `⌘` release or
/// Enter. Esc cancels.
///
/// Presented as a sibling to `FullScreenTerminalView` inside `BoardRootView`
/// so the underlying terminal surface keeps running uninterrupted while
/// the overlay is up.
struct SessionSwitcherOverlay: View {
  let sessions: [AgentSession]
  let repositories: IdentifiedArrayOf<Repository>
  let classify: (AgentSession) -> BoardSessionStatus
  @Binding var highlightedSessionID: AgentSession.ID?
  let onCommit: () -> Void
  let onCancel: () -> Void

  @State private var flagsMonitor: Any?
  @FocusState private var hasFocus: Bool

  private let cardWidth: CGFloat = 220
  private let cardSpacing: CGFloat = 12

  var body: some View {
    ZStack {
      // Click-outside to cancel.
      Color.black.opacity(0.25)
        .contentShape(.rect)
        .onTapGesture { onCancel() }

      panel
        .frame(maxWidth: 720)
        .padding(40)
    }
    .ignoresSafeArea()
    .focusable()
    .focusEffectDisabled()
    .focused($hasFocus)
    .task { hasFocus = true }
    .onKeyPress(.leftArrow) { moveCursor(by: -1); return .handled }
    .onKeyPress(.upArrow) { moveCursorAcrossRows(by: -1); return .handled }
    .onKeyPress(.rightArrow) { moveCursor(by: +1); return .handled }
    .onKeyPress(.downArrow) { moveCursorAcrossRows(by: +1); return .handled }
    .onKeyPress(.return) { onCommit(); return .handled }
    .onExitCommand { onCancel() }
    .onAppear { installFlagsMonitor() }
    .onDisappear { removeFlagsMonitor() }
  }

  private var panel: some View {
    let waiting = sessions.filter { BoardNavOrder.isWaitingStatus(classify($0)) }
    let working = sessions.filter { !BoardNavOrder.isWaitingStatus(classify($0)) }
    return VStack(alignment: .leading, spacing: 14) {
      header
      if !waiting.isEmpty {
        sessionSection(
          title: "Waiting",
          systemImage: "hand.raised.fill",
          tint: .orange,
          sessions: waiting,
        )
      }
      if !working.isEmpty {
        sessionSection(
          title: "Working",
          systemImage: "circle.fill",
          tint: .green,
          sessions: working,
        )
      }
    }
    .padding(18)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(.ultraThinMaterial)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
    .compositingGroup()
  }

  private func sessionSection(
    title: String,
    systemImage: String,
    tint: Color,
    sessions: [AgentSession]
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Image(systemName: systemImage)
          .font(.caption2)
          .foregroundStyle(tint)
        Text(title)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Text("\(sessions.count)")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.tertiary)
      }
      ScrollViewReader { proxy in
        ScrollView(.horizontal, showsIndicators: true) {
          LazyHStack(alignment: .top, spacing: cardSpacing) {
            ForEach(sessions) { session in
              cardView(for: session)
                .frame(width: cardWidth)
                // The full-screen overlay can offer the whole window height; keep cards at their intrinsic height.
                .fixedSize(horizontal: false, vertical: true)
                .id(session.id)
            }
          }
          .scrollTargetLayout()
          .padding(.vertical, 2)
        }
        .fixedSize(horizontal: false, vertical: true)
        .scrollTargetBehavior(.viewAligned)
        .onAppear {
          scrollHighlightedCard(in: sessions, proxy: proxy, animated: false)
        }
        .onChange(of: highlightedSessionID) { _, _ in
          scrollHighlightedCard(in: sessions, proxy: proxy)
        }
      }
    }
  }

  private func scrollHighlightedCard(
    in sessions: [AgentSession],
    proxy: ScrollViewProxy,
    animated: Bool = true
  ) {
    guard let highlightedSessionID,
      sessions.contains(where: { $0.id == highlightedSessionID })
    else { return }

    if animated {
      withAnimation(.easeOut(duration: 0.12)) {
        proxy.scrollTo(highlightedSessionID, anchor: .center)
      }
    } else {
      proxy.scrollTo(highlightedSessionID, anchor: .center)
    }
  }

  private func cardView(for session: AgentSession) -> some View {
    SessionCardView(
      session: session,
      repositoryName: repositories[id: session.repositoryID]?.name,
      status: classify(session),
      onTap: {
        highlightedSessionID = session.id
        onCommit()
      },
      onRemove: {},
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(
          Color.accentColor,
          lineWidth: highlightedSessionID == session.id ? 2 : 0,
        )
    )
    .animation(.easeOut(duration: 0.08), value: highlightedSessionID)
  }

  private var header: some View {
    HStack(spacing: 8) {
      Image(systemName: "rectangle.stack")
        .font(.headline)
        .foregroundStyle(.secondary)
      Text("Switch session")
        .font(.headline)
        .foregroundStyle(.primary)
      Spacer()
      Text("Release ⌘ to switch · Esc to cancel")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
  }

  // MARK: - Cursor

  private func moveCursor(by delta: Int) {
    let ids = sessions.map(\.id)
    guard !ids.isEmpty else { return }
    let currentIndex = highlightedSessionID.flatMap { ids.firstIndex(of: $0) } ?? -1
    let next: Int
    if currentIndex < 0 {
      next = delta < 0 ? ids.count - 1 : 0
    } else {
      next = (currentIndex + delta + ids.count) % ids.count
    }
    highlightedSessionID = ids[next]
  }

  /// Up/Down jump between the Waiting and Working rows, landing on the
  /// same column position (clamped to the shorter row) instead of
  /// stepping through the flat order. With only one row on screen they
  /// fall back to plain prev/next so the keys never go dead.
  private func moveCursorAcrossRows(by delta: Int) {
    let waiting = sessions.filter { BoardNavOrder.isWaitingStatus(classify($0)) }
    let working = sessions.filter { !BoardNavOrder.isWaitingStatus(classify($0)) }
    guard !waiting.isEmpty, !working.isEmpty else {
      moveCursor(by: delta)
      return
    }
    let targetRow: [AgentSession]
    let column: Int
    if let index = waiting.firstIndex(where: { $0.id == highlightedSessionID }) {
      targetRow = working
      column = index
    } else if let index = working.firstIndex(where: { $0.id == highlightedSessionID }) {
      targetRow = waiting
      column = index
    } else {
      targetRow = delta < 0 ? working : waiting
      column = 0
    }
    highlightedSessionID = targetRow[min(column, targetRow.count - 1)].id
  }

  // MARK: - ⌘⌥-release detection

  /// Watches `flagsChanged` events locally while the overlay is on screen
  /// and commits the moment the user releases `⌥` (the option half of
  /// the ⌘⌥+arrow combo). Option is the cleaner "done switching"
  /// signal because ⌘ stays held for many adjacent shortcuts and users
  /// often keep it pressed between actions. Scoped to the overlay's
  /// lifecycle so there's no lingering monitor once we're dismissed.
  private func installFlagsMonitor() {
    flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
      if !event.modifierFlags.contains(.option) {
        onCommit()
      }
      return event
    }
  }

  private func removeFlagsMonitor() {
    if let monitor = flagsMonitor {
      NSEvent.removeMonitor(monitor)
      flagsMonitor = nil
    }
  }
}
