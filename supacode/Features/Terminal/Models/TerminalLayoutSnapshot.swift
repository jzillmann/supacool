import Foundation

struct TerminalLayoutSnapshot: Codable, Equatable, Sendable {
  let tabs: [TabSnapshot]
  let selectedTabIndex: Int

  struct TabSnapshot: Codable, Equatable, Sendable {
    let id: UUID?
    let title: String
    let icon: String?
    let tintColor: TerminalTabTintColor?
    let layout: LayoutNode
    let focusedLeafIndex: Int
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
