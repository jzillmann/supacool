import SwiftUI

/// A single Getting Started carousel card. Vertical layout: icon, title,
/// summary, primary Setup button, secondary Skip. Sized to fill the
/// width of the carousel's paged container; the carousel itself handles
/// paging, spacing, and page indicators.
struct GettingStartedCardView: View {
  let task: GettingStartedTask
  let onSetup: () -> Void
  let onSkip: () -> Void

  var body: some View {
    VStack(spacing: 20) {
      Image(systemName: task.iconName)
        .font(.system(size: 52, weight: .regular))
        .foregroundStyle(.tint)
        .symbolRenderingMode(.hierarchical)
        .accessibilityHidden(true)

      VStack(spacing: 10) {
        Text(task.title)
          .font(.title2.weight(.semibold))
          .multilineTextAlignment(.center)
        Text(task.summary)
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: 420)
      }

      VStack(spacing: 8) {
        Button(action: onSetup) {
          Text(task.ctaLabel)
            .frame(minWidth: 160)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .help("Set this up now.")

        Button("Skip", action: onSkip)
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .help("Park this task. You can bring it back later from Settings → General.")
      }
    }
    .padding(.horizontal, 32)
    .padding(.vertical, 36)
    .frame(maxWidth: 520, maxHeight: .infinity)
    .background(
      .regularMaterial,
      in: RoundedRectangle(cornerRadius: 14, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
  }
}
