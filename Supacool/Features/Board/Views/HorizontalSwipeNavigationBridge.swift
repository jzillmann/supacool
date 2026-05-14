import AppKit
import SwiftUI

/// Physical horizontal swipe direction used for browser-style board navigation.
/// Positive AppKit swipe deltas map to `.left` per `NSEvent.deltaX` docs.
nonisolated enum HorizontalNavigationSwipe: Equatable, Sendable {
  case left
  case right
}

/// Accumulates precise trackpad scroll deltas into a single horizontal navigation swipe.
///
/// Trackpad page swipes often arrive as `scrollWheel` events before the embedded terminal sees them,
/// not as SwiftUI gestures. Keeping the thresholding in a tiny value type makes the noisy AppKit
/// event stream testable and avoids firing on ordinary vertical terminal scrollback.
nonisolated struct HorizontalSwipeDetector: Equatable, Sendable {
  var threshold: Double
  var dominanceRatio: Double

  private var accumulatedX: Double = 0
  private var accumulatedY: Double = 0
  private var didTrigger: Bool = false

  init(threshold: Double = 80, dominanceRatio: Double = 1.35) {
    self.threshold = threshold
    self.dominanceRatio = dominanceRatio
  }

  mutating func reset() {
    accumulatedX = 0
    accumulatedY = 0
    didTrigger = false
  }

  mutating func ingest(
    deltaX: Double,
    deltaY: Double,
    isBeginning: Bool,
    isEnding: Bool,
    isMomentum: Bool
  ) -> HorizontalNavigationSwipe? {
    if isMomentum {
      if isEnding { reset() }
      return nil
    }

    if isBeginning { reset() }

    accumulatedX += deltaX
    accumulatedY += deltaY

    defer {
      if isEnding { reset() }
    }

    guard !didTrigger else { return nil }

    let horizontal = abs(accumulatedX)
    let vertical = abs(accumulatedY)
    guard horizontal >= threshold,
      horizontal >= vertical * dominanceRatio
    else { return nil }

    didTrigger = true
    return accumulatedX > 0 ? .left : .right
  }
}

/// Installs a window-scoped local AppKit event monitor that converts two-finger horizontal swipes
/// into browser-style navigation. A local monitor is intentional: live Ghostty terminal panes consume
/// scroll events before SwiftUI gestures can see them.
struct HorizontalSwipeNavigationBridge: NSViewRepresentable {
  var isEnabled = true
  let onSwipe: (HorizontalNavigationSwipe) -> Bool

  func makeNSView(context: Context) -> HorizontalSwipeNavigationView {
    let view = HorizontalSwipeNavigationView()
    view.isSwipeNavigationEnabled = isEnabled
    view.onSwipe = onSwipe
    return view
  }

  func updateNSView(_ nsView: HorizontalSwipeNavigationView, context: Context) {
    nsView.isSwipeNavigationEnabled = isEnabled
    nsView.onSwipe = onSwipe
  }

  static func dismantleNSView(_ nsView: HorizontalSwipeNavigationView, coordinator: ()) {
    nsView.uninstallMonitor()
  }
}

@MainActor
final class HorizontalSwipeNavigationView: NSView {
  var isSwipeNavigationEnabled = true {
    didSet {
      if !isSwipeNavigationEnabled { detector.reset() }
    }
  }
  var onSwipe: ((HorizontalNavigationSwipe) -> Bool)?

  private var monitor: Any?
  private var detector = HorizontalSwipeDetector()

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil {
      uninstallMonitor()
    } else {
      installMonitorIfNeeded()
    }
  }

  func uninstallMonitor() {
    guard let monitor else { return }
    NSEvent.removeMonitor(monitor)
    self.monitor = nil
    detector.reset()
  }

  private func installMonitorIfNeeded() {
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .swipe]) { [weak self] event in
      self?.handle(event) ?? event
    }
  }

  private func handle(_ event: NSEvent) -> NSEvent? {
    guard let window, event.window === window, window.isKeyWindow else { return event }
    guard isSwipeNavigationEnabled else {
      detector.reset()
      return event
    }
    guard event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift]) else {
      detector.reset()
      return event
    }

    guard let swipe = navigationSwipe(from: event) else { return event }
    guard onSwipe?(swipe) == true else { return event }
    return nil
  }

  private func navigationSwipe(from event: NSEvent) -> HorizontalNavigationSwipe? {
    switch event.type {
    case .swipe:
      if event.deltaX > 0 { return .left }
      if event.deltaX < 0 { return .right }
      return nil

    case .scrollWheel:
      guard event.hasPreciseScrollingDeltas else {
        detector.reset()
        return nil
      }
      guard !event.phase.isEmpty else { return nil }

      let phase = event.phase
      let momentumPhase = event.momentumPhase
      return detector.ingest(
        deltaX: Double(event.scrollingDeltaX),
        deltaY: Double(event.scrollingDeltaY),
        isBeginning: phase.contains(.began) || phase.contains(.mayBegin),
        isEnding: phase.contains(.ended) || phase.contains(.cancelled),
        isMomentum: !momentumPhase.isEmpty
      )

    default:
      return nil
    }
  }
}
