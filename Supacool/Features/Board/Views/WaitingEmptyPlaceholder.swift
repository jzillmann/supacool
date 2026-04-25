import SwiftUI

/// Fancy "all clear" empty state for the **Waiting on Me** section.
///
/// Without this, the bucket collapses to a single line of secondary text
/// and the In Progress row directly underneath gets misread as "the first
/// row" — which is exactly what Comandante Joe asked us to fix. A tall,
/// visually distinct placeholder keeps the section anchored even at zero
/// items.
///
/// The Matrix-rain backdrop is a wink at the board's name. It runs at
/// 24 FPS via a single `TimelineView`/`Canvas` pair — no per-column
/// state, no timers; the whole rain is recomputed each frame from
/// elapsed time, so suspending the view costs nothing.
struct WaitingEmptyPlaceholder: View {
  var body: some View {
    ZStack {
      MatrixRainCanvas()
        .opacity(0.32)
        .allowsHitTesting(false)

      VStack(spacing: 6) {
        Image(systemName: "checkmark.seal.fill")
          .font(.system(size: 38, weight: .semibold))
          .foregroundStyle(.green)
          .symbolEffect(.pulse, options: .repeating)
        Text("You're all caught up")
          .font(.title3.weight(.semibold))
          .foregroundStyle(.primary)
        Text("Nothing is waiting on your input.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity)
    .frame(height: 200)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color.green.opacity(0.06)),
    )
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(Color.green.opacity(0.18), lineWidth: 1),
    )
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .accessibilityElement(children: .combine)
    .accessibilityLabel("You're all caught up. Nothing is waiting on your input.")
  }
}

/// Self-contained Matrix-style character rain. Stateless: each frame the
/// glyph positions are derived from `time + per-column phase`, glyph
/// values from `time` rounded to the cycle rate. No `@State`, no timers,
/// nothing to leak.
private struct MatrixRainCanvas: View {
  private let columnSpacing: CGFloat = 16
  private let glyphHeight: CGFloat = 18
  private let glyphFontSize: CGFloat = 13
  private let glyphTickRate: Double = 4.0  // glyph cycles per second

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
      Canvas { ctx, size in
        let time = context.date.timeIntervalSinceReferenceDate
        draw(into: ctx, size: size, time: time)
      }
    }
  }

  private func draw(into ctx: GraphicsContext, size: CGSize, time: TimeInterval) {
    let columnCount = max(1, Int(size.width / columnSpacing))
    let glyphTick = floor(time * glyphTickRate)
    for col in 0..<columnCount {
      drawColumn(ctx: ctx, size: size, col: col, time: time, glyphTick: glyphTick)
    }
  }

  private func drawColumn(
    ctx: GraphicsContext,
    size: CGSize,
    col: Int,
    time: TimeInterval,
    glyphTick: Double,
  ) {
    let seed = Double(col) * 12.9898
    let speed = 35.0 + abs(sin(seed)) * 50.0  // 35–85 px/s
    let phase = abs(cos(seed)) * 6.0  // 0–6s offset
    let trailLength = 8 + Int(abs(sin(seed * 1.7)) * 6.0)  // 8–14 glyphs
    let cycle = Double(size.height) + Double(trailLength) * Double(glyphHeight)
    let raw = (time + phase) * speed
    let topY = CGFloat(raw.truncatingRemainder(dividingBy: cycle))
      - CGFloat(trailLength) * glyphHeight
    let x = CGFloat(col) * columnSpacing + columnSpacing / 2

    for i in 0..<trailLength {
      let y = topY + CGFloat(i) * glyphHeight
      guard y > -glyphHeight, y < size.height else { continue }
      let glyph = Self.glyph(seed: seed + Double(i) + glyphTick)
      let isHead = i == trailLength - 1
      // i = trailLength - 1 is the head (brightest, leading edge),
      // i = 0 is the back of the tail (dimmest).
      let progress = Double(i + 1) / Double(trailLength)
      let alpha = isHead ? min(1.0, progress + 0.15) : progress * 0.85
      let text = Text(String(glyph))
        .font(.system(size: glyphFontSize, design: .monospaced))
        .foregroundStyle(Color.green.opacity(alpha))
      ctx.draw(text, at: CGPoint(x: x, y: y))
    }
  }

  private static let glyphs: [Character] = Array(
    "01ｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎ:;.=*+-<>",
  )

  /// Cheap GLSL-style hash → glyph index. Deterministic in `seed`, so the
  /// same column at the same `glyphTick` always picks the same glyph
  /// across frames within a tick window.
  private static func glyph(seed: Double) -> Character {
    let frac = (sin(seed * 12345.6789) + 1.0) / 2.0  // 0…1
    let idx = Int(frac * Double(glyphs.count)) % glyphs.count
    return glyphs[idx]
  }
}

#Preview {
  WaitingEmptyPlaceholder()
    .padding()
    .frame(width: 720)
}
