import ComposableArchitecture
import SwiftUI

/// First-launch onboarding carousel. Replaces the board's empty state
/// while there are incomplete, non-skipped Getting Started tasks. One
/// card is shown at a time, horizontally paged: users swipe, use arrow
/// keys, or tap the page dots to move. Each card's Setup button goes
/// through `BoardFeature.gettingStartedSetupTapped`; Skip parks the
/// card via a persisted flag.
///
/// See `GettingStartedState` for the session-level state and
/// `GettingStartedEvaluator` for the launch-time predicate check.
struct GettingStartedCarouselView: View {
  @Bindable var store: StoreOf<BoardFeature>

  var body: some View {
    VStack(spacing: 18) {
      header
      carousel
      if store.gettingStarted.tasks.count > 1 {
        pageIndicator
      }
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(keyboardShortcuts)
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Get started")
          .font(.title3.weight(.semibold))
        Text("A few quick things to unlock the rest of Supacool.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button {
        store.send(.gettingStartedDismiss, animation: .easeOut(duration: 0.18))
      } label: {
        Image(systemName: "xmark.circle.fill")
          .font(.title3)
          .foregroundStyle(.tertiary)
      }
      .buttonStyle(.plain)
      .help("Hide Getting Started for this session. Bring it back from Settings → General.")
    }
    .padding(.horizontal, 8)
  }

  private var carousel: some View {
    let tasks = store.gettingStarted.tasks
    let selection = Binding<GettingStartedTask?>(
      get: {
        guard tasks.indices.contains(store.gettingStarted.currentIndex) else {
          return tasks.first
        }
        return tasks[store.gettingStarted.currentIndex]
      },
      set: { newValue in
        guard let newValue, let idx = tasks.firstIndex(of: newValue) else { return }
        store.send(.gettingStartedSetCurrentIndex(idx))
      }
    )
    return ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 24) {
        ForEach(tasks, id: \.self) { task in
          GettingStartedCardView(
            task: task,
            onSetup: { store.send(.gettingStartedSetupTapped(task)) },
            onSkip: {
              store.send(
                .gettingStartedSkipTapped(task),
                animation: .spring(response: 0.35, dampingFraction: 0.85)
              )
            }
          )
          .containerRelativeFrame(.horizontal)
          .id(task)
        }
      }
      .scrollTargetLayout()
    }
    .scrollTargetBehavior(.viewAligned)
    .scrollPosition(id: selection, anchor: .center)
    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: tasks)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var pageIndicator: some View {
    let tasks = store.gettingStarted.tasks
    return HStack(spacing: 8) {
      ForEach(tasks, id: \.self) { task in
        let isCurrent = tasks.firstIndex(of: task) == store.gettingStarted.currentIndex
        Circle()
          .fill(isCurrent ? Color.accentColor : Color.secondary.opacity(0.4))
          .frame(width: 7, height: 7)
          .onTapGesture {
            guard let idx = tasks.firstIndex(of: task) else { return }
            store.send(
              .gettingStartedSetCurrentIndex(idx),
              animation: .easeInOut(duration: 0.2)
            )
          }
      }
    }
    .padding(.top, 4)
  }

  /// Left/right arrows scoped to the carousel (not the whole app).
  /// Implemented as hidden keyboard-shortcut buttons — the same idiom
  /// used by BoardRootView's ⌘N trigger.
  private var keyboardShortcuts: some View {
    ZStack {
      Button("Previous", action: { advance(by: -1) })
        .keyboardShortcut(.leftArrow, modifiers: [])
        .hidden()
      Button("Next", action: { advance(by: 1) })
        .keyboardShortcut(.rightArrow, modifiers: [])
        .hidden()
    }
    .disabled(store.gettingStarted.tasks.count <= 1)
  }

  private func advance(by delta: Int) {
    let tasks = store.gettingStarted.tasks
    guard !tasks.isEmpty else { return }
    let next = (store.gettingStarted.currentIndex + delta + tasks.count) % tasks.count
    store.send(
      .gettingStartedSetCurrentIndex(next),
      animation: .easeInOut(duration: 0.2)
    )
  }
}
