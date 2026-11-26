import SwiftUI

/// Gives the main window a fixed minimum size, so AppKit never measures the
/// board to find one.
///
/// A SwiftUI `Window` sets its minimum size from its content: on every
/// constraint pass, `NSHostingView` asks the whole view tree for its smallest
/// size. With a busy board (dozens of cards, hidden per-session watchers)
/// that walk was about 15% of the main thread while the user scrolled or
/// typed. This layout answers the size question itself and only places its
/// content, which is the layout pass that has to happen anyway.
struct FixedMinimumSizeLayout: Layout {
  var minimumSize: CGSize

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    CGSize(
      width: max(proposal.width ?? minimumSize.width, minimumSize.width),
      height: max(proposal.height ?? minimumSize.height, minimumSize.height)
    )
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    for subview in subviews {
      subview.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
  }
}
