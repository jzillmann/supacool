import ComposableArchitecture
import SwiftUI

/// Toolbar search box that narrows the board's cards by free text. ⌘F
/// jumps into it, Esc clears it and hands focus back to the board so the
/// arrow keys work again. Only rendered on the board — the full-screen
/// terminal owns ⌘F for the shell.
struct BoardSearchField: View {
  @Bindable var store: StoreOf<BoardFeature>
  @FocusState private var isFocused: Bool

  private var query: Binding<String> {
    Binding(
      get: { store.searchQuery },
      set: { store.send(.searchQueryChanged($0)) }
    )
  }

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      TextField("Search cards", text: query)
        .textFieldStyle(.plain)
        .focused($isFocused)
        .onExitCommand { clear() }
      if !store.searchQuery.isEmpty {
        Button {
          clear()
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
            .accessibilityLabel("Clear search")
        }
        .buttonStyle(.plain)
        .help("Clear search (Esc)")
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    .frame(width: 180)
    .help("Search cards by name, prompt, repo, worktree, agent, or model (⌘F)")
    .background(
      Button("Search Cards") { isFocused = true }
        .keyboardShortcut("f", modifiers: .command)
        .hidden()
    )
  }

  private func clear() {
    store.send(.searchQueryChanged(""))
    isFocused = false
  }
}
