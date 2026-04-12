enum SidebarViewMode: String, CaseIterable, Identifiable, Codable, Sendable {
  case pinned
  case all

  var id: String { rawValue }

  var label: String {
    switch self {
    case .pinned: "Pinned"
    case .all: "All"
    }
  }

  var systemImage: String {
    switch self {
    case .pinned: "pin.fill"
    case .all: "list.bullet"
    }
  }
}
