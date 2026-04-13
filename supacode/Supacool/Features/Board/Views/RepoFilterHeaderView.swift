import ComposableArchitecture
import SwiftUI

/// A horizontal chip bar showing all registered repositories. Chips toggle
/// selection. When no chips are selected, every repo is visible ("show all").
///
/// Lives at the top of the BoardView.
struct RepoFilterHeaderView: View {
  let repositories: IdentifiedArrayOf<Repository>
  let filters: BoardFilters
  let onToggleRepository: (String) -> Void
  let onShowAll: () -> Void

  var body: some View {
    if repositories.count <= 1 {
      // Single repo (or none): no point offering a filter. Keeps the header
      // clean when the only choice is "All" vs. "the one repo you have."
      EmptyView()
    } else {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          AllChip(
            isActive: filters.showsAllRepositories,
            onTap: onShowAll
          )
          ForEach(repositories) { repository in
            RepoChip(
              name: repository.name,
              isActive: filters.selectedRepositoryIDs.contains(repository.id),
              onTap: { onToggleRepository(repository.id) }
            )
          }
        }
        .padding(.horizontal, 16)
      }
      .frame(height: 40)
    }
  }
}

private struct AllChip: View {
  let isActive: Bool
  let onTap: () -> Void

  var body: some View {
    Button(action: onTap) {
      Text("All")
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .foregroundStyle(isActive ? Color.accentColor : .secondary)
        .background(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
        .overlay(
          Capsule()
            .strokeBorder(isActive ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: 1)
        )
        .clipShape(Capsule())
    }
    .buttonStyle(.plain)
    .help("Show all repositories")
  }
}

private struct RepoChip: View {
  let name: String
  let isActive: Bool
  let onTap: () -> Void

  var body: some View {
    Button(action: onTap) {
      HStack(spacing: 4) {
        Image(systemName: "folder.fill")
          .font(.caption2)
        Text(name)
          .font(.caption.weight(.medium))
          .lineLimit(1)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .foregroundStyle(isActive ? Color.accentColor : .secondary)
      .background(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
      .overlay(
        Capsule()
          .strokeBorder(isActive ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: 1)
      )
      .clipShape(Capsule())
    }
    .buttonStyle(.plain)
    .help(isActive ? "Hide \(name)" : "Show \(name)")
  }
}
