import ComposableArchitecture
import SwiftUI

/// Toolbar button that summarizes the repo filter and expands into a
/// popover. The popover lists all registered repos as toggleable rows and
/// offers an "Add Repository…" button at the bottom.
///
/// Replaces the horizontal chip bar that used to live below the window
/// title. Button label shows the active state:
/// - No repos registered → "Add Repository"
/// - 1 repo, included → that repo's name
/// - Showing all → "All repositories"
/// - Subset selected → "N of M selected"
struct RepoPickerButton: View {
  let repositories: IdentifiedArrayOf<Repository>
  let filters: BoardFilters
  let onToggleRepository: (String) -> Void
  let onFocusRepository: (String) -> Void
  let onShowAll: () -> Void
  let onAddRepository: () -> Void
  let onConfigureRepositories: () -> Void

  @State private var isPresented: Bool = false
  @State private var hoveredRepositoryID: Repository.ID?

  var body: some View {
    Button {
      if repositories.isEmpty {
        onAddRepository()
      } else {
        isPresented.toggle()
      }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: repositories.isEmpty ? "folder.badge.plus" : "folder.fill")
          .foregroundStyle(repositories.isEmpty ? .blue : .yellow)
        Text(summary)
          .lineLimit(1)
        if !repositories.isEmpty {
          Image(systemName: "chevron.down")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
        }
      }
    }
    .help(helpText)
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      popoverContent
    }
  }

  private var summary: String {
    switch repositories.count {
    case 0:
      return "Add Repository"
    case 1:
      return repositories.first?.name ?? "Repository"
    default:
      if filters.showsAllRepositories {
        return "All repositories"
      }
      let visibleRepos = repositories.filter { filters.includes(repositoryID: $0.id) }
      if visibleRepos.count == repositories.count {
        return "All repositories"
      }
      if visibleRepos.count == 1, let only = visibleRepos.first {
        return only.name
      }
      return "\(visibleRepos.count) of \(repositories.count)"
    }
  }

  private var helpText: String {
    if repositories.isEmpty {
      return "Register a repository (⌘O)"
    }
    return "Filter by repository"
  }

  private var popoverContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Header with "All" toggle.
      Button {
        onShowAll()
      } label: {
        HStack {
          Image(systemName: filters.showsAllRepositories ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(filters.showsAllRepositories ? Color.accentColor : Color.secondary)
          Text("All repositories")
            .font(.callout.weight(.medium))
          Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      Divider()

      ForEach(repositories) { repo in
        HStack(spacing: 0) {
          Button {
            onToggleRepository(repo.id)
          } label: {
            HStack {
              Image(systemName: isIncluded(repo) ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isIncluded(repo) ? Color.accentColor : Color.secondary)
              Image(systemName: "folder.fill")
                .font(.caption)
                .foregroundStyle(.yellow)
              Text(repo.name)
                .font(.callout)
                .lineLimit(1)
              Spacer()
            }
            .padding(.leading, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)

          Button {
            onFocusRepository(repo.id)
            isPresented = false
          } label: {
            Image(systemName: "scope")
              .font(.caption.weight(.semibold))
              .foregroundStyle(isFocused(repo) ? Color.accentColor : Color.secondary)
              .frame(width: 28, height: 28)
              .opacity(shouldShowFocusButton(for: repo) ? 1 : 0)
          }
          .buttonStyle(.plain)
          .help("Focus \(repo.name) only")
          .accessibilityLabel("Focus \(repo.name) only")
          .accessibilityHidden(!shouldShowFocusButton(for: repo))
          .disabled(!shouldShowFocusButton(for: repo))
        }
        .padding(.trailing, 6)
        .contentShape(Rectangle())
        .onHover { isHovering in
          hoveredRepositoryID = isHovering ? repo.id : nil
        }
      }

      Divider()

      Button {
        isPresented = false
        onAddRepository()
      } label: {
        HStack {
          Image(systemName: "folder.badge.plus")
            .foregroundStyle(.blue)
          Text("Add Repository…")
            .font(.callout.weight(.medium))
          Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .keyboardShortcut("o", modifiers: .command)

      if !repositories.isEmpty {
        Button {
          isPresented = false
          onConfigureRepositories()
        } label: {
          HStack {
            Image(systemName: "gearshape")
              .foregroundStyle(.secondary)
            Text("Configure Repositories…")
              .font(.callout.weight(.medium))
            Spacer()
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
    .frame(minWidth: 240)
    .padding(.vertical, 4)
  }

  private func isIncluded(_ repo: Repository) -> Bool {
    filters.selectedRepositoryIDs.contains(repo.id)
      && !filters.showsAllRepositories
  }

  private func isFocused(_ repo: Repository) -> Bool {
    filters.selectedRepositoryIDs == [repo.id]
  }

  private func shouldShowFocusButton(for repo: Repository) -> Bool {
    hoveredRepositoryID == repo.id || isFocused(repo)
  }
}
