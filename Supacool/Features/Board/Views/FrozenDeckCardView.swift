import SwiftUI

/// Collapsed stand-in for a pile of idle (detached) sessions.
///
/// After a relaunch every persisted session comes back detached, so the
/// "Waiting on Me" rail fills up with cracked-glass cards that all want the
/// same two things: resume, or get out of the way. The deck folds them into
/// one card — rendered as a literal stack of cards — and offers exactly those
/// two moves. Tapping the body fans the pile back out.
///
/// Priority-flagged sessions are never swept in; the deck's whole job is to
/// hide things the user hasn't flagged as worth seeing.
struct FrozenDeckCardView: View {
  let sessions: [AgentSession]
  /// How many of `sessions` a bulk resume can actually revive. Sessions with
  /// no agent, no captured native session id, and no picker support are dead
  /// weight — they can still be expanded, just not resumed en masse.
  let resumableCount: Int
  let onResumeAll: () -> Void
  let onExpand: () -> Void

  @State private var isHovered: Bool = false

  var body: some View {
    ZStack(alignment: .top) {
      backingLayer(inset: 24, lift: 10, opacity: 0.45)
      backingLayer(inset: 12, lift: 5, opacity: 0.7)
      frontCard
    }
    // Leave room for the two backing layers peeking above the front card so
    // they don't collide with the section header.
    .padding(.top, 10)
    .animation(.easeOut(duration: 0.12), value: isHovered)
    .onHover { hovering in
      isHovered = hovering
      if hovering {
        NSCursor.pointingHand.push()
      } else {
        NSCursor.pop()
      }
    }
  }

  /// One of the cards peeking out from behind the front of the deck. Narrower
  /// and lifted, so the pile reads as depth rather than as a drop shadow.
  private func backingLayer(inset: CGFloat, lift: CGFloat, opacity: Double) -> some View {
    cardShape
      .fill(.background.secondary)
      .overlay(
        cardShape
          .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
      )
      .frame(height: 40, alignment: .top)
      .padding(.horizontal, inset)
      .offset(y: -lift)
      .opacity(opacity)
      .allowsHitTesting(false)
  }

  private var frontCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      header
      Text("\(sessions.count) idle sessions")
        .font(.headline)
        .foregroundStyle(.primary)
        .monospacedDigit()
      Text(sessionSummary)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .multilineTextAlignment(.leading)
      Spacer(minLength: 0)
      footer
    }
    .padding(14)
    .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
    .background(.background.secondary)
    .overlay {
      cardShape
        .strokeBorder(Color.secondary.opacity(isHovered ? 0.45 : 0.25), lineWidth: 1)
        .allowsHitTesting(false)
    }
    .overlay {
      CrackedGlassOverlay(seed: crackSeed, intensity: 0.85)
    }
    .clipShape(cardShape)
    .contentShape(cardShape)
    // Matches SessionCardView: the card hosts its own buttons, so a wrapping
    // Button makes macOS click routing flaky. Tap-to-expand stays a gesture.
    .onTapGesture(perform: onExpand)
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(.isButton)
    .accessibilityLabel("\(sessions.count) idle sessions, stacked")
    .accessibilityHint("Activate to fan the stack back out into individual cards")
  }

  private var header: some View {
    HStack(spacing: 6) {
      Image(systemName: "rectangle.stack.fill")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text("Frozen")
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary)
      Spacer(minLength: 0)
      Label(BoardSessionStatus.detached.label, systemImage: BoardSessionStatus.detached.systemImage)
        .font(.caption)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
    }
  }

  private var footer: some View {
    HStack(spacing: 8) {
      deckButton(
        title: "Resume All",
        systemImage: "play.circle.fill",
        prominent: true,
        action: onResumeAll
      )
      .disabled(resumableCount == 0)
      .help(resumeHelp)

      deckButton(
        title: "Ungroup",
        systemImage: "rectangle.split.3x1",
        prominent: false,
        action: onExpand
      )
      .help("Fan the stack out into individual cards")
    }
  }

  private func deckButton(
    title: String,
    systemImage: String,
    prominent: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Label(title, systemImage: systemImage)
        .font(.caption.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
          Capsule(style: .continuous)
            .fill(prominent ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.thinMaterial))
        )
        .overlay(
          Capsule(style: .continuous)
            .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
    }
    .buttonStyle(.plain)
  }

  private var resumeHelp: String {
    switch resumableCount {
    case 0: "None of these sessions can be resumed automatically — ungroup to handle them one by one"
    case sessions.count: "Resume all \(sessions.count) sessions"
    default: "Resume \(resumableCount) of \(sessions.count) sessions — the rest need attention individually"
    }
  }

  /// First couple of session names, then a "+n more" tail. Gives the pile a
  /// face so it isn't just an anonymous number.
  private var sessionSummary: String {
    let names = sessions.prefix(2).map(\.displayName)
    let remainder = sessions.count - names.count
    let joined = names.joined(separator: " · ")
    return remainder > 0 ? "\(joined) · +\(remainder) more" : joined
  }

  private var cardShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: 10, style: .continuous)
  }

  /// Stable fracture pattern for the deck, pinned to the first session's id
  /// the same way `SessionCardView` pins each card's own pattern.
  private var crackSeed: UInt64 {
    guard let first = sessions.first else { return 0 }
    var uuid = first.id.uuid
    return withUnsafeBytes(of: &uuid) { $0.load(as: UInt64.self) }
  }
}
