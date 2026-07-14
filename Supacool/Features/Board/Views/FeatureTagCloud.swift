import SwiftUI

/// A wrapping flow layout: lays subviews left-to-right, wrapping to a new
/// line when the next subview would overflow the proposed width. Backs the
/// New Terminal "launch options" tag cloud. A custom `Layout` (rather than
/// `GeometryReader` + manual math) per the project's UI guidelines.
/// Named distinctly from the chip-only `FlowLayout` in `SessionInfoPopover`.
struct TagFlowLayout: Layout {
  var spacing: CGFloat = 8
  var lineSpacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let maxWidth = proposal.width ?? .infinity
    var rowWidth: CGFloat = 0
    var rowHeight: CGFloat = 0
    var totalHeight: CGFloat = 0
    var widestRow: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
        totalHeight += rowHeight + lineSpacing
        widestRow = max(widestRow, rowWidth)
        rowWidth = size.width
        rowHeight = size.height
      } else {
        rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
        rowHeight = max(rowHeight, size.height)
      }
    }
    totalHeight += rowHeight
    widestRow = max(widestRow, rowWidth)
    return CGSize(width: proposal.width ?? widestRow, height: totalHeight)
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {
    var x = bounds.minX
    var y = bounds.minY
    var rowHeight: CGFloat = 0
    var isFirstInRow = true

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if !isFirstInRow, x + spacing + size.width > bounds.maxX {
        x = bounds.minX
        y += rowHeight + lineSpacing
        rowHeight = 0
        isFirstInRow = true
      }
      if !isFirstInRow { x += spacing }
      subview.place(
        at: CGPoint(x: x, y: y),
        anchor: .topLeading,
        proposal: ProposedViewSize(size)
      )
      x += size.width
      rowHeight = max(rowHeight, size.height)
      isFirstInRow = false
    }
  }
}

/// One toggleable pill in a feature tag cloud. Filled + accent-tinted when
/// on, outlined + secondary when off. Tapping flips the bound flag.
/// Carries its explanation in a `.help()` tooltip (per the project's UX
/// rule that controls describe their action + state).
struct FeatureTag: View {
  @Binding var isOn: Bool
  let title: String
  let systemImage: String
  let help: String
  /// When false the pill is dimmed and inert — used for mutually-exclusive
  /// options (e.g. Skip permissions while Plan mode is on).
  var isEnabled: Bool = true

  var body: some View {
    Button {
      isOn.toggle()
    } label: {
      HStack(spacing: 5) {
        Image(systemName: systemImage)
          .font(.caption.weight(.medium))
          .symbolVariant(isOn ? .fill : .none)
          .accessibilityHidden(true)
        Text(title)
          .font(.callout)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background {
        Capsule(style: .continuous)
          .fill(isOn ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.10))
      }
      .overlay {
        Capsule(style: .continuous)
          .strokeBorder(
            isOn ? Color.accentColor : Color.secondary.opacity(0.3),
            lineWidth: 1
          )
      }
      .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
      .contentShape(Capsule(style: .continuous))
    }
    .buttonStyle(.plain)
    .disabled(!isEnabled)
    .opacity(isEnabled ? 1 : 0.4)
    .help(help)
  }
}
