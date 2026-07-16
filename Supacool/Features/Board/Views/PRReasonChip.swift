import SwiftUI

/// Compact "the ball is in your court" annotation for a PR-backed session —
/// CI failed / Conflicts / Changes requested / Ready to merge / … Rendered on
/// both the board card and the full-screen terminal header off the same
/// `PRBallState` so the two surfaces never disagree about a session's PR state.
struct PRReasonChip: View {
  let ball: PRBallState

  var body: some View {
    HStack(spacing: 3) {
      Image(systemName: ball.systemImage)
        .font(.caption2)
        .accessibilityLabel(accessibilityLabel)
      if let label = ball.reasonLabel {
        Text(label)
          .font(.caption2.weight(.semibold))
          .lineLimit(1)
      }
    }
    .foregroundStyle(color)
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(color.opacity(0.12))
    .clipShape(Capsule())
    // Truncatable so a long reason ("Ready to merge") can't push a fixed-width
    // card past its column; the full text stays available on hover.
    .fixedSize(horizontal: false, vertical: true)
    .help(accessibilityLabel)
  }

  private var accessibilityLabel: String {
    ball.reasonLabel.map { "Pull request: \($0)" } ?? "Pull request status"
  }

  private var color: Color {
    switch ball.severity {
    case .attention: .red
    case .info: .secondary
    case .positive: .green
    }
  }
}
