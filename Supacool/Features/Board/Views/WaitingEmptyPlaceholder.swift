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
      // Static glow backdrop. The previous `MatrixRainCanvas`
      // implementation was a `Canvas` + `TimelineView` running at
      // 12 fps with per-frame Core Text typesetting. Even with the
      // resolved-text cache, two live `sample` captures during 1.2 s
      // main-thread freezes (system load avg ~128) caught it as the
      // dominant frame — and pinned to it was 258 samples of
      // `CAContext.waitForCommitId → mach_msg` (Supacool blocking
      // on the WindowServer round-trip every commit). Under any
      // sustained system load, an ambient animation that drives a
      // commit per frame is a beachball machine. Replaced with a
      // static radial gradient that costs zero per frame.
      RadialGradient(
        colors: [
          Color.green.opacity(0.22),
          Color.green.opacity(0.04),
          Color.clear,
        ],
        center: .center,
        startRadius: 0,
        endRadius: 180,
      )
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
///
/// Performance: a live `sample` capture during a 1.4 s main-thread
/// freeze showed `MatrixRainCanvas.drawColumn → ctx.draw → Core Text
/// typesetting` as 55 % of the stall — every `ctx.draw(Text(...))` ran
/// the full attributed-string → `CTLineCreateWithAttributedString`
/// pipeline. With ~50 columns × ~10 glyphs × 24 fps the canvas was
/// asking SwiftUI for ~12 k typeset lines per second.
///
/// Two mitigations applied here:
///   1. Pre-resolve each unique (glyph, alpha-bucket) once per frame via
///      `ctx.resolve(_:)` and reuse across every column that wants the
///      same glyph at the same brightness. Cuts typeset calls from
///      O(columns × trailLength) to O(uniqueGlyphs × alphaBuckets) per
///      frame — about a 6× reduction on the default layout.
///   2. Drop frame rate from 24 fps to 12 fps. The decoration stays
///      smooth enough to read as "rain" while halving render cadence.
///      Net: ~12× fewer typeset calls per second.
private struct MatrixRainCanvas: View {
  private let columnSpacing: CGFloat = 16
  private let glyphHeight: CGFloat = 18
  private let glyphFontSize: CGFloat = 13
  private let glyphTickRate: Double = 4.0  // glyph cycles per second
  /// Frame rate (per second) for the rain animation.
  private let fps: Double = 12.0
  /// Alpha values are continuous in `drawColumn`; we discretize them to
  /// this many buckets so the resolve cache key (glyph, bucket) hits.
  /// 6 buckets give a visibly smooth fade while letting every column's
  /// trail share a small set of pre-resolved texts.
  private static let alphaBucketCount: Int = 6

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / fps)) { context in
      Canvas { ctx, size in
        let time = context.date.timeIntervalSinceReferenceDate
        draw(into: ctx, size: size, time: time)
      }
    }
  }

  private func draw(into ctx: GraphicsContext, size: CGSize, time: TimeInterval) {
    let columnCount = max(1, Int(size.width / columnSpacing))
    let glyphTick = floor(time * glyphTickRate)
    // Per-frame resolved-text cache: (glyph, alpha-bucket) → ResolvedText.
    // Resolving once per unique combo lets every column reuse the same
    // typeset CTLine instead of rebuilding it on every ctx.draw.
    var cache: [CacheKey: GraphicsContext.ResolvedText] = [:]
    let fontSize = glyphFontSize
    for col in 0..<columnCount {
      drawColumn(
        ctx: ctx,
        size: size,
        col: col,
        time: time,
        glyphTick: glyphTick,
        cache: &cache,
        fontSize: fontSize,
      )
    }
  }

  private struct CacheKey: Hashable {
    let glyph: Character
    let alphaBucket: Int
  }

  private func drawColumn(
    ctx: GraphicsContext,
    size: CGSize,
    col: Int,
    time: TimeInterval,
    glyphTick: Double,
    cache: inout [CacheKey: GraphicsContext.ResolvedText],
    fontSize: CGFloat,
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
      let bucket = Self.alphaBucket(for: alpha)
      let key = CacheKey(glyph: glyph, alphaBucket: bucket)
      let resolved: GraphicsContext.ResolvedText
      if let hit = cache[key] {
        resolved = hit
      } else {
        let bucketAlpha = Self.alphaForBucket(bucket)
        let text = Text(String(glyph))
          .font(.system(size: fontSize, design: .monospaced))
          .foregroundStyle(Color.green.opacity(bucketAlpha))
        resolved = ctx.resolve(text)
        cache[key] = resolved
      }
      ctx.draw(resolved, at: CGPoint(x: x, y: y))
    }
  }

  /// Snap a continuous alpha (0…1) to one of `alphaBucketCount` buckets
  /// so the resolve cache key has a small, finite domain.
  private static func alphaBucket(for alpha: Double) -> Int {
    let clamped = max(0.0, min(1.0, alpha))
    let bucket = Int(clamped * Double(alphaBucketCount - 1))
    return min(max(bucket, 0), alphaBucketCount - 1)
  }

  /// Inverse of `alphaBucket`: representative alpha for a bucket index.
  /// Bucket 0 maps to 0 and bucket `alphaBucketCount-1` maps to 1, with
  /// the rest evenly spaced in between.
  private static func alphaForBucket(_ bucket: Int) -> Double {
    Double(bucket) / Double(alphaBucketCount - 1)
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
