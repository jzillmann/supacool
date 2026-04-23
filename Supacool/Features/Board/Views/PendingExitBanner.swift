import SwiftUI

/// Small pill shown at the bottom of the full-screen terminal when an
/// auto-zoom-back is queued after a prompt submission. Renders the
/// destination name and a progress bar that drains over the grace
/// period; Esc cancels via the parent's keyboard shortcut wiring and
/// the pill is also tappable for mouse-first users.
struct PendingExitBanner: View {
  let destination: String
  let startedAt: Date
  let duration: Duration
  let onCancel: () -> Void

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: false)) { context in
      let elapsed = context.date.timeIntervalSince(startedAt)
      let total =
        Double(duration.components.seconds)
        + Double(duration.components.attoseconds) / 1e18
      let progress = min(max(elapsed / max(total, 0.001), 0), 1)
      Button(action: onCancel) {
        HStack(spacing: 10) {
          Image(systemName: "arrow.right.circle")
            .font(.callout)
            .foregroundStyle(.secondary)
          Text(destination)
            .font(.callout.weight(.medium))
            .foregroundStyle(.primary)
          Text("· Esc to stay")
            .font(.caption)
            .foregroundStyle(.tertiary)
          ProgressView(value: progress)
            .progressViewStyle(.linear)
            .frame(width: 60)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .clipShape(Capsule())
        .overlay(
          Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
      }
      .buttonStyle(.plain)
      .help("Cancel and stay on this terminal (Esc)")
    }
  }
}
