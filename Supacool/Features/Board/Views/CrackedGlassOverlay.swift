import SwiftUI

/// Decorative "shattered glass / frozen over" overlay for dormant
/// session cards (parked, detached, interrupted, SSH-disconnected).
/// Two fracture styles are combined into one look:
///
/// - Edge cracks (ice): hairlines that shoot from random edge points
///   into the interior with jagged branching. Feels glacial.
/// - Impact web (glass): a cluster of short cracks radiating from a
///   single off-center point, like the card took a knock. Feels hard.
///
/// Everything is seeded from the session UUID so the pattern is stable
/// across redraws — no flicker on hover, window resize, or theme change.
struct CrackedGlassOverlay: View {
  let seed: UInt64
  /// 0 = invisible, 1 = full strength. Callers tune per status.
  let intensity: Double

  var body: some View {
    ZStack {
      // Cool frost wash brightens the whole card so it reads as
      // "frozen over" before the eye picks up the hairlines.
      // `plusLighter` keeps it additive so it works on light + dark.
      LinearGradient(
        colors: [
          frostTint.opacity(0.14 * intensity),
          frostTint.opacity(0.04 * intensity),
          frostTint.opacity(0.18 * intensity),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .blendMode(.plusLighter)

      // Cracks rendered in normal blend so the dark shadow strokes
      // stay dark (plusLighter was erasing them on light cards).
      // `Color.primary` adapts to light / dark mode automatically:
      // dark cracks on a light card, bright cracks on a dark card.
      Canvas { context, size in
        var rng = SeededGenerator(seed: seed)
        drawEdgeCracks(into: &context, size: size, rng: &rng)
        drawImpactWeb(into: &context, size: size, rng: &rng)
      }
    }
    .allowsHitTesting(false)
  }

  private var frostTint: Color {
    Color(.displayP3, red: 0.78, green: 0.90, blue: 1.0, opacity: 1)
  }

  // MARK: - Edge cracks (ice)

  private func drawEdgeCracks(
    into context: inout GraphicsContext,
    size: CGSize,
    rng: inout SeededGenerator
  ) {
    let crackCount = 4 + Int(rng.next() % 3)  // 4–6
    for _ in 0..<crackCount {
      let (path, branch) = buildEdgeCrack(size: size, rng: &rng)
      strokeCrack(path, branch: branch, into: &context)
    }
  }

  private func buildEdgeCrack(
    size: CGSize,
    rng: inout SeededGenerator
  ) -> (main: Path, branch: Path?) {
    let edge = rng.next() % 4
    let t = CGFloat(rng.nextDouble())
    let start: CGPoint = switch edge {
    case 0: CGPoint(x: t * size.width, y: 0)
    case 1: CGPoint(x: size.width, y: t * size.height)
    case 2: CGPoint(x: t * size.width, y: size.height)
    default: CGPoint(x: 0, y: t * size.height)
    }
    let target = CGPoint(
      x: size.width * CGFloat(0.25 + rng.nextDouble() * 0.5),
      y: size.height * CGFloat(0.25 + rng.nextDouble() * 0.5)
    )
    let segments = 2 + Int(rng.next() % 3)
    let jitter: CGFloat = 14

    var path = Path()
    path.move(to: start)
    var tip = start
    for i in 1...segments {
      let progress = CGFloat(i) / CGFloat(segments)
      let base = CGPoint(
        x: start.x + (target.x - start.x) * progress,
        y: start.y + (target.y - start.y) * progress
      )
      let point = CGPoint(
        x: base.x + CGFloat(rng.nextDouble() - 0.5) * jitter * 2,
        y: base.y + CGFloat(rng.nextDouble() - 0.5) * jitter * 2
      )
      path.addLine(to: point)
      tip = point
    }

    var branch: Path?
    if rng.nextDouble() > 0.5 {
      let angle = CGFloat(rng.nextDouble() * .pi * 2)
      let length: CGFloat = 8 + CGFloat(rng.nextDouble() * 18)
      var bp = Path()
      bp.move(to: tip)
      bp.addLine(to: CGPoint(
        x: tip.x + cos(angle) * length,
        y: tip.y + sin(angle) * length
      ))
      branch = bp
    }

    return (path, branch)
  }

  // MARK: - Impact web (glass)

  private func drawImpactWeb(
    into context: inout GraphicsContext,
    size: CGSize,
    rng: inout SeededGenerator
  ) {
    // Tuck the impact toward a corner so it doesn't cover the title.
    let impact = CGPoint(
      x: size.width * CGFloat(0.55 + rng.nextDouble() * 0.35),
      y: size.height * CGFloat(0.20 + rng.nextDouble() * 0.55)
    )
    let spokeCount = 5 + Int(rng.next() % 3)  // 5–7
    let baseAngle = rng.nextDouble() * .pi * 2

    for i in 0..<spokeCount {
      let sector = (.pi * 2) / Double(spokeCount)
      let angle = baseAngle + Double(i) * sector
        + (rng.nextDouble() - 0.5) * sector * 0.5
      let length: CGFloat = 18 + CGFloat(rng.nextDouble() * 26)
      let tip = CGPoint(
        x: impact.x + cos(angle) * length,
        y: impact.y + sin(angle) * length
      )
      // One kink mid-spoke to avoid a perfectly straight ray.
      let midT: CGFloat = 0.55 + CGFloat(rng.nextDouble() * 0.2)
      let perp = angle + .pi / 2
      let offset: CGFloat = (CGFloat(rng.nextDouble()) - 0.5) * 6
      let mid = CGPoint(
        x: impact.x + (tip.x - impact.x) * midT + cos(perp) * offset,
        y: impact.y + (tip.y - impact.y) * midT + sin(perp) * offset
      )
      var spoke = Path()
      spoke.move(to: impact)
      spoke.addLine(to: mid)
      spoke.addLine(to: tip)
      strokeCrack(spoke, branch: nil, into: &context)
    }

    // Tiny concentric shard polygon around the impact for that
    // "the glass here is really shattered" feel.
    let shardRadius: CGFloat = 5 + CGFloat(rng.nextDouble() * 3)
    var shard = Path()
    let shardSides = 5 + Int(rng.next() % 3)
    for i in 0..<shardSides {
      let a = Double(i) / Double(shardSides) * .pi * 2 + baseAngle
      let r = shardRadius * CGFloat(0.7 + rng.nextDouble() * 0.5)
      let p = CGPoint(x: impact.x + cos(a) * r, y: impact.y + sin(a) * r)
      if i == 0 { shard.move(to: p) } else { shard.addLine(to: p) }
    }
    shard.closeSubpath()
    strokeCrack(shard, branch: nil, into: &context)
  }

  // MARK: - Stroke helpers

  private func strokeCrack(
    _ path: Path,
    branch: Path?,
    into context: inout GraphicsContext
  ) {
    let main = StrokeStyle(lineWidth: 0.8, lineCap: .round, lineJoin: .round)
    let thin = StrokeStyle(lineWidth: 0.6, lineCap: .round, lineJoin: .round)

    // Dark shadow offset down-right fakes depth like a real fracture.
    let shadowT = CGAffineTransform(translationX: 0.8, y: 0.8)
    context.stroke(
      path.applying(shadowT),
      with: .color(.black.opacity(0.45 * intensity)),
      style: thin
    )
    // Main crack line in primary so it adapts to colour scheme.
    context.stroke(
      path,
      with: .color(Color.primary.opacity(0.55 * intensity)),
      style: main
    )
    // Bright highlight on the upper-left edge of the crack.
    let hlT = CGAffineTransform(translationX: -0.4, y: -0.4)
    context.stroke(
      path.applying(hlT),
      with: .color(.white.opacity(0.35 * intensity)),
      style: thin
    )

    if let branch {
      context.stroke(
        branch.applying(shadowT),
        with: .color(.black.opacity(0.35 * intensity)),
        style: thin
      )
      context.stroke(
        branch,
        with: .color(Color.primary.opacity(0.45 * intensity)),
        style: thin
      )
    }
  }
}

/// Deterministic xorshift64 — keeps each card's fracture pattern stable
/// across app launches and redraws. `Hashable.hashValue` isn't stable
/// across processes, so we derive the seed from UUID bytes at the call
/// site instead.
struct SeededGenerator: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    self.state = seed == 0 ? 0xdead_beef_cafe_babe : seed
  }

  mutating func next() -> UInt64 {
    state ^= state << 13
    state ^= state >> 7
    state ^= state << 17
    return state
  }

  mutating func nextDouble() -> Double {
    Double(next() % 1_000_000) / 1_000_000
  }
}

#Preview("On light card") {
  ZStack {
    RoundedRectangle(cornerRadius: 10, style: .continuous)
      .fill(Color(white: 0.92))
    CrackedGlassOverlay(seed: 0x1234_5678_9abc_def0, intensity: 1.0)
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
  }
  .frame(width: 260, height: 140)
  .padding()
}

#Preview("On dark card") {
  ZStack {
    RoundedRectangle(cornerRadius: 10, style: .continuous)
      .fill(Color(white: 0.15))
    CrackedGlassOverlay(seed: 0x1234_5678_9abc_def0, intensity: 1.0)
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
  }
  .frame(width: 260, height: 140)
  .padding()
}
