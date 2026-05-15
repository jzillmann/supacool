import Foundation

struct TerminalLayoutSnapshot: Codable, Equatable, Sendable {
  let tabs: [TabSnapshot]
  let selectedTabIndex: Int

  init(tabs: [TabSnapshot], selectedTabIndex: Int) {
    self.tabs = tabs
    self.selectedTabIndex = selectedTabIndex
  }

  // Forward-compatible Codable — convention documented in
  // docs/agent-guides/persistence.md. Synthesized Codable would refuse
  // to read older files when fields are added below.
  enum CodingKeys: String, CodingKey {
    case tabs, selectedTabIndex
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    tabs = try c.decodeIfPresent([TabSnapshot].self, forKey: .tabs) ?? []
    selectedTabIndex = try c.decodeIfPresent(Int.self, forKey: .selectedTabIndex) ?? 0
  }

  struct TabSnapshot: Codable, Equatable, Sendable {
    let id: UUID?
    let title: String
    let icon: String?
    let tintColor: TerminalTabTintColor?
    let layout: LayoutNode
    let focusedLeafIndex: Int
    /// Owning session, when this tab belongs to an `AgentSession`'s
    /// composition. `nil` for worktree-mode tabs not tied to a board card.
    /// Used by the launch-time reattach pass to rebuild a session's
    /// auxiliary terminals.
    let sessionID: UUID?

    init(
      id: UUID?,
      title: String,
      icon: String?,
      tintColor: TerminalTabTintColor?,
      layout: LayoutNode,
      focusedLeafIndex: Int,
      sessionID: UUID? = nil
    ) {
      self.id = id
      self.title = title
      self.icon = icon
      self.tintColor = tintColor
      self.layout = layout
      self.focusedLeafIndex = focusedLeafIndex
      self.sessionID = sessionID
    }

    enum CodingKeys: String, CodingKey {
      case id, title, icon, tintColor, layout, focusedLeafIndex, sessionID
    }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      id = try c.decodeIfPresent(UUID.self, forKey: .id)
      title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
      icon = try c.decodeIfPresent(String.self, forKey: .icon)
      tintColor = try c.decodeIfPresent(TerminalTabTintColor.self, forKey: .tintColor)
      // `layout` is the only structurally required field — a snapshot
      // without it is meaningless and should fail the whole tab.
      layout = try c.decode(LayoutNode.self, forKey: .layout)
      focusedLeafIndex = try c.decodeIfPresent(Int.self, forKey: .focusedLeafIndex) ?? 0
      sessionID = try c.decodeIfPresent(UUID.self, forKey: .sessionID)
    }
  }

  indirect enum LayoutNode: Codable, Equatable, Sendable {
    case leaf(SurfaceSnapshot)
    case split(SplitSnapshot)
  }

  struct SplitSnapshot: Codable, Equatable, Sendable {
    let direction: SplitDirection
    let ratio: Double
    let left: LayoutNode
    let right: LayoutNode
  }

  struct SurfaceSnapshot: Codable, Equatable, Sendable {
    let id: UUID?
    let workingDirectory: String?
  }

}

extension TerminalLayoutSnapshot {
  /// Returns the saved tab matching `tabID`, or (for legacy single-tab
  /// snapshots written before tab IDs were stable) the only tab with its
  /// ID rewritten to the requested session tab.
  func restorableTabSnapshot(for tabID: TerminalTabID) -> TabSnapshot? {
    if let exact = tabs.first(where: { $0.id == tabID.rawValue }) {
      return exact
    }
    guard tabs.count == 1, let only = tabs.first else { return nil }
    return only.withID(tabID.rawValue)
  }
}

extension TerminalLayoutSnapshot.TabSnapshot {
  func withID(_ id: UUID) -> Self {
    Self(
      id: id,
      title: title,
      icon: icon,
      tintColor: tintColor,
      layout: layout,
      focusedLeafIndex: focusedLeafIndex,
      sessionID: sessionID
    )
  }

  func withSessionID(_ sessionID: UUID?) -> Self {
    Self(
      id: id,
      title: title,
      icon: icon,
      tintColor: tintColor,
      layout: layout,
      focusedLeafIndex: focusedLeafIndex,
      sessionID: sessionID
    )
  }
}

extension TerminalLayoutSnapshot.LayoutNode {
  /// The leftmost leaf in the subtree.
  var firstLeaf: TerminalLayoutSnapshot.SurfaceSnapshot {
    switch self {
    case .leaf(let surface):
      return surface
    case .split(let split):
      return split.left.firstLeaf
    }
  }

  /// The number of leaves in the subtree.
  var leafCount: Int {
    switch self {
    case .leaf:
      return 1
    case .split(let split):
      return split.left.leafCount + split.right.leafCount
    }
  }
}
