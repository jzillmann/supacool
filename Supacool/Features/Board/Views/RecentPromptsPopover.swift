import SwiftUI

/// Lists reconstructed user prompts for a session, newest first. Selecting
/// one invokes `onJump(promptText)` — callers wire that to
/// `performBindingAction("search:<text>")` on the focused surface, which
/// opens Ghostty's search overlay pre-populated with the needle.
///
/// Loads asynchronously off the main thread so a large transcript (tens of
/// MB) doesn't stall the popover presentation.
struct RecentPromptsPopover: View {
  let tabID: TerminalTabID
  let onJump: (String) -> Void

  @State private var prompts: [TranscriptReader.Prompt] = []
  @State private var isLoaded: Bool = false

  /// Keep the needle short — Ghostty's matcher does literal-substring
  /// matching, and a long paste-as-prompt will never match the rendered
  /// terminal output character-for-character anyway (wrapping, prompt
  /// prefix, agent's own echo, etc.).
  private let searchNeedleCap: Int = 40

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      content
    }
    .frame(minWidth: 320, idealWidth: 380, maxWidth: 480, minHeight: 80, idealHeight: 320, maxHeight: 480)
    .task(id: tabID) {
      await load()
    }
  }

  private var header: some View {
    HStack {
      Image(systemName: "text.line.first.and.arrowtriangle.forward")
        .foregroundStyle(.secondary)
      Text("Recent prompts")
        .font(.headline)
      Spacer()
      Text("\(prompts.count)")
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  @ViewBuilder
  private var content: some View {
    if !isLoaded {
      HStack {
        ProgressView().controlSize(.small)
        Text("Loading…").foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, minHeight: 60)
    } else if prompts.isEmpty {
      Text("No prompts captured yet.")
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 60)
        .padding(.horizontal, 12)
    } else {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(prompts) { prompt in
            row(for: prompt)
            Divider()
          }
        }
      }
    }
  }

  private func row(for prompt: TranscriptReader.Prompt) -> some View {
    Button {
      let needle = String(prompt.text.prefix(searchNeedleCap))
      onJump(needle)
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Text(prompt.text)
          .font(.callout)
          .lineLimit(2)
          .multilineTextAlignment(.leading)
          .foregroundStyle(.primary)
        Text(prompt.startedAt.formatted(.relative(presentation: .named)))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func load() async {
    let captured = tabID
    let loaded = await Task.detached(priority: .userInitiated) {
      let entries = TranscriptReader.loadEntries(tabID: captured)
      return TranscriptReader.aggregatePrompts(from: entries)
    }.value
    prompts = loaded
    isLoaded = true
  }
}
