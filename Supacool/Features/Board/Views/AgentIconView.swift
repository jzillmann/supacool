import SwiftUI

extension AgentType {
  /// Resolves the agent's `icon` (asset or SF symbol) into a SwiftUI Image.
  var image: Image {
    switch icon {
    case .asset(let name): Image(name)
    case .symbol(let name): Image(systemName: name)
    }
  }

  /// Resolves the agent's tint color name (`"purple"`, `"cyan"`, `"primary"`,
  /// etc.) into a SwiftUI `Color`. Unknown names fall back to `.secondary`
  /// — keeps the UI rendering rather than crashing on a typo.
  var tintColor: Color {
    Self.color(named: tintColorName)
  }

  /// Same color resolution but takes an optional agent so the "Shell" /
  /// `nil` case can render with the secondary color used everywhere.
  static func tintColor(for agent: AgentType?) -> Color {
    guard let agent else { return .secondary }
    return agent.tintColor
  }

  /// Whitelist of system color names supported by registry entries. New
  /// entries must use one of these — keeps the app off custom hex per
  /// CLAUDE.md ("Never use custom colors").
  static let supportedTintColorNames: [String] = [
    "primary", "secondary",
    "purple", "cyan", "orange", "pink", "green", "blue", "red",
    "yellow", "mint", "teal", "indigo", "brown", "gray",
  ]

  fileprivate static func color(named name: String) -> Color {
    switch name {
    case "primary": .primary
    case "secondary": .secondary
    case "purple": .purple
    case "cyan": .cyan
    case "orange": .orange
    case "pink": .pink
    case "green": .green
    case "blue": .blue
    case "red": .red
    case "yellow": .yellow
    case "mint": .mint
    case "teal": .teal
    case "indigo": .indigo
    case "brown": .brown
    case "gray": .gray
    default: .secondary
    }
  }
}

/// Renders an agent's icon (or a shell-fallback) at a given size with the
/// agent's tint color. Used by board cards, bookmark pills, the new
/// terminal sheet, and the full-screen terminal toolbar.
struct AgentIconView: View {
  let agent: AgentType?
  var size: CGFloat = 14
  var weight: Font.Weight = .medium

  var body: some View {
    Group {
      if let agent {
        agent.image
          .resizable()
          .scaledToFit()
      } else {
        Image(systemName: "apple.terminal")
          .resizable()
          .scaledToFit()
      }
    }
    .frame(width: size, height: size)
    .foregroundStyle(AgentType.tintColor(for: agent))
    .font(.system(size: size, weight: weight))
  }
}
