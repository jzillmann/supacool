import AppKit
import SwiftUI

/// Read-only summary of a session's initial config. Reached via the small
/// info (ⓘ) button that lives on each board card and in the full-screen
/// header — both surfaces reuse this view so the content stays consistent.
struct SessionInfoPopover: View {
  let session: AgentSession
  let repositoryName: String?
  let worktreeLabel: String?
  var onRerun: (() -> Void)?

  @Environment(\.dismiss) private var dismiss
  @State private var didCopyPrompt: Bool = false

  @AppStorage("supacool.references.linearOrg") private var linearOrgSlug: String = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      Divider()
      promptBlock
      if !session.references.isEmpty {
        Divider()
        referencesBlock
      }
      Divider()
      metadata
    }
    .padding(16)
    .frame(minWidth: 320, idealWidth: 380, maxWidth: 480)
  }

  @ViewBuilder
  private var referencesBlock: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label("References", systemImage: "link")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      FlowingChips(
        references: session.references,
        linearOrgSlug: linearOrgSlug
      )
    }
  }

  private var header: some View {
    HStack(spacing: 6) {
      Image(systemName: "info.circle")
        .foregroundStyle(.secondary)
      Text(session.displayName)
        .font(.headline)
        .lineLimit(2)
    }
  }

  private var promptBlock: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .center, spacing: 8) {
        Label("Initial prompt", systemImage: "quote.opening")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        if !session.initialPrompt.isEmpty {
          Button {
            copyPrompt()
          } label: {
            Image(systemName: didCopyPrompt ? "checkmark" : "doc.on.doc")
          }
          .buttonStyle(.plain)
          .controlSize(.small)
          .help(didCopyPrompt ? "Prompt copied" : "Copy prompt")
        }
        if let onRerun {
          Button {
            onRerun()
            dismiss()
          } label: {
            Label("Rerun", systemImage: "arrow.clockwise")
              .labelStyle(.iconOnly)
          }
          .buttonStyle(.plain)
          .controlSize(.small)
          .help("Rerun with the same prompt")
        }
      }
      if session.initialPrompt.isEmpty {
        Text("(no prompt — raw terminal)")
          .font(.callout)
          .foregroundStyle(.tertiary)
      } else {
        ScrollView {
          Text(session.initialPrompt)
            .font(.callout.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 200)
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
      }
    }
  }

  @ViewBuilder
  private var metadata: some View {
    VStack(alignment: .leading, spacing: 6) {
      row(label: "Agent", value: AgentType.displayName(for: session.agent))
      if let repositoryName {
        row(label: "Repository", value: repositoryName)
      }
      if let worktreeLabel {
        row(label: "Worktree", value: worktreeLabel)
      } else {
        row(label: "Worktree", value: "— (repo root)")
      }
      row(label: "Created", value: Self.dateFormatter.string(from: session.createdAt))
      if let id = session.agentNativeSessionID, !id.isEmpty {
        row(label: "Resume id", value: id, monospaced: true)
      }
    }
  }

  private func row(label: String, value: String, monospaced: Bool = false) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(width: 90, alignment: .leading)
      Text(value)
        .font(monospaced ? .caption.monospaced() : .callout)
        .foregroundStyle(.primary)
        .textSelection(.enabled)
        .lineLimit(2)
      Spacer()
    }
  }

  private func copyPrompt() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(session.initialPrompt, forType: .string)
    didCopyPrompt = true
    Task {
      try? await Task.sleep(for: .seconds(1.2))
      await MainActor.run { didCopyPrompt = false }
    }
  }

  private static let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    return f
  }()
}

/// Wrapping row of ReferenceChips for the info popover (no overflow cap —
/// shows everything). Uses iOS-16+ SwiftUI Layout via `WrappingHStack`
/// isn't available; we fall back to a LazyVStack of rows with HStack
/// wrapping isn't trivial, so use a simple HStack that wraps via
/// `.layoutPriority` and modest width.
private struct FlowingChips: View {
  let references: [SessionReference]
  let linearOrgSlug: String

  var body: some View {
    WrapView(references, id: \.dedupeKey) { ref in
      ReferenceChip(reference: ref, linearOrgSlug: linearOrgSlug)
    }
  }
}

/// Minimal wrapping container for chips. Uses WidthReader + a simple
/// two-pass packing to avoid pulling in an extra dependency.
private struct WrapView<Data: RandomAccessCollection, ID: Hashable, Content: View>: View
where Data.Element: Equatable {
  let data: Data
  let id: KeyPath<Data.Element, ID>
  let content: (Data.Element) -> Content

  init(
    _ data: Data,
    id: KeyPath<Data.Element, ID>,
    @ViewBuilder content: @escaping (Data.Element) -> Content
  ) {
    self.data = data
    self.id = id
    self.content = content
  }

  var body: some View {
    // SwiftUI's new layout protocol handles this elegantly.
    FlowLayout(spacing: 4) {
      ForEach(Array(data), id: id) { item in
        content(item)
      }
    }
  }
}

/// Simple flowing (wrap) layout for chips.
private struct FlowLayout: Layout {
  var spacing: CGFloat = 4

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) -> CGSize {
    let width = proposal.width ?? .infinity
    var currentX: CGFloat = 0
    var currentY: CGFloat = 0
    var rowHeight: CGFloat = 0
    var totalHeight: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if currentX + size.width > width, currentX > 0 {
        totalHeight = currentY + rowHeight
        currentY += rowHeight + spacing
        currentX = 0
        rowHeight = 0
      }
      currentX += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
    totalHeight = currentY + rowHeight
    return CGSize(width: width == .infinity ? currentX : width, height: totalHeight)
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {
    let width = bounds.width
    var currentX: CGFloat = bounds.minX
    var currentY: CGFloat = bounds.minY
    var rowHeight: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if currentX + size.width > bounds.minX + width, currentX > bounds.minX {
        currentX = bounds.minX
        currentY += rowHeight + spacing
        rowHeight = 0
      }
      subview.place(
        at: CGPoint(x: currentX, y: currentY),
        proposal: ProposedViewSize(width: size.width, height: size.height)
      )
      currentX += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
  }
}
