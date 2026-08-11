import SwiftUI

/// Compact "the ball is in your court" annotation for a PR-backed session —
/// CI failed / Conflicts / Changes requested / Ready to merge / … Rendered on
/// both the board card and the full-screen terminal header off the same
/// `PRBallState` so the two surfaces never disagree about a session's PR state.
struct PRReasonChip: View {
  let ball: PRBallState
  /// The PR this reason belongs to, stamped on the pill when the session holds
  /// more than one PR. Without it a red "2 checks failed" on a multi-PR card
  /// reads as a verdict on whichever PR the reference chip happens to show —
  /// which is how a green "✓ 5/5" chip ended up sitting next to a red pill.
  /// Nil (the single-PR case) keeps the pill as short as it has always been.
  var pullRequestNumber: Int?

  var body: some View {
    HStack(spacing: 3) {
      Image(systemName: ball.systemImage)
        .font(.caption2)
        .accessibilityLabel(accessibilityLabel)
      if let pullRequestNumber {
        Text("#\(pullRequestNumber)")
          .font(.caption2.weight(.semibold))
          .monospacedDigit()
          .lineLimit(1)
          .opacity(0.75)
      }
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

  /// Always names the PR when we know it, even where the visible pill omits
  /// the number — the tooltip has room the 280pt card header doesn't.
  private var accessibilityLabel: String {
    let subject = pullRequestNumber.map { "Pull request #\($0)" } ?? "Pull request"
    return ball.reasonLabel.map { "\(subject): \($0)" } ?? "\(subject) status"
  }

  private var color: Color {
    switch ball.severity {
    case .attention: .red
    case .info: .secondary
    case .positive: .green
    }
  }
}
