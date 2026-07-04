import SwiftUI

/// Compact toolbar readout of the fleet's live state — how many sessions
/// are waiting on me, working, blocked externally, and dormant. Mirrors
/// `BoardView`'s section buckets so the numbers match what's on the board.
/// Visible in both board and full-screen-terminal chrome so you can keep
/// an eye on the queue while heads-down in a session.
struct BoardVitalsChip: View {
  let vitals: BoardVitals

  var body: some View {
    HStack(spacing: 8) {
      // Always show waiting + working, even at zero — "0 waiting" is a
      // useful all-clear signal while crunching the queue.
      segment(
        count: vitals.waiting,
        systemImage: "exclamationmark.circle.fill",
        color: .orange
      )
      segment(
        count: vitals.working,
        systemImage: "circle.fill",
        color: .green
      )
      // The rest only earn a slot when non-empty, keeping the chip tight.
      if vitals.external > 0 {
        segment(
          count: vitals.external,
          systemImage: "hourglass.circle.fill",
          color: .blue
        )
      }
      if dormant > 0 {
        segment(
          count: dormant,
          systemImage: "moon.zzz.fill",
          color: .secondary
        )
      }
    }
    .padding(.horizontal, 2)
    .help(helpText)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(helpText)
  }

  private var dormant: Int { vitals.standby + vitals.parked }

  private func segment(count: Int, systemImage: String, color: Color) -> some View {
    HStack(spacing: 3) {
      Image(systemName: systemImage)
        .font(.caption2)
      Text("\(count)")
        .font(.caption.monospacedDigit())
    }
    .foregroundStyle(count == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(color))
  }

  private var helpText: String {
    var parts: [String] = [
      "\(vitals.waiting) waiting on you",
      "\(vitals.working) working",
    ]
    if vitals.external > 0 {
      parts.append("\(vitals.external) waiting on external")
    }
    if vitals.standby > 0 {
      parts.append("\(vitals.standby) on standby")
    }
    if vitals.parked > 0 {
      parts.append("\(vitals.parked) parked")
    }
    return "Sessions — " + parts.joined(separator: ", ") + "."
  }
}
