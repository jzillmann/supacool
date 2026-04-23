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
  let onShowAll: () -> Void
  let onAddRepository: () -> Void
  let onConfigureRepositories: () -> Void
  /// Tapping the trailing broom button on a repo row runs
  /// `git worktree prune` for that repo + reconciles any orphan session
  /// cards. Wired up in BoardRootView.
  let onPruneWorktrees: (Repository) -> Void
  /// Opens the read-only "Manage Worktrees…" inspector for the chosen
  /// repo. Lives next to (not replacing) the prune entry in PR2; PR3
  /// will fold the prune action into the janitor's scan and remove the
  /// dedicated prune item.
  let onManageWorktrees: (Repository) -> Void

  @State private var isPresented: Bool = false

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
      let visible = repositories.filter { filters.includes(repositoryID: $0.id) }.count
      if visible == repositories.count {
        return "All repositories"
      }
      return "\(visible) of \(repositories.count)"
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
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

        // Discoverable entry point for `git worktree prune`. Expands
        // into a submenu of repos (or fires directly when there's only
        // one) so the user doesn't have to guess which tiny icon cleans
        // up worktrees.
        pruneFooter
        // Read-only janitor inspector. Placed below prune in PR2 so
        // the existing affordance keeps working untouched; PR3 will
        // fold prune into the janitor's scan and remove this section's
        // sibling above.
        manageFooter
      }
    }
    .frame(minWidth: 240)
    .padding(.vertical, 4)
  }

  @ViewBuilder
  private var pruneFooter: some View {
    if repositories.count == 1, let only = repositories.first {
      Button {
        isPresented = false
        onPruneWorktrees(only)
      } label: {
        pruneFooterLabel(text: "Prune Stale Worktrees…")
      }
      .buttonStyle(.plain)
      .help("Run git worktree prune and clean up orphan session cards")
    } else {
      Menu {
        ForEach(repositories) { repo in
          Button(repo.name) {
            isPresented = false
            onPruneWorktrees(repo)
          }
        }
      } label: {
        pruneFooterLabel(text: "Prune Stale Worktrees…")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .help("Pick a repository to run git worktree prune against")
    }
  }

  private func pruneFooterLabel(text: String) -> some View {
    HStack {
      Image(systemName: "wand.and.sparkles")
        .foregroundStyle(.secondary)
      Text(text)
        .font(.callout.weight(.medium))
      Spacer()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .contentShape(Rectangle())
  }

  @ViewBuilder
  private var manageFooter: some View {
    if repositories.count == 1, let only = repositories.first {
      Button {
        isPresented = false
        onManageWorktrees(only)
      } label: {
        manageFooterLabel(text: "Manage Worktrees…")
      }
      .buttonStyle(.plain)
      .help("Inspect every worktree on disk for this repo (size, status, git metadata)")
    } else {
      Menu {
        ForEach(repositories) { repo in
          Button(repo.name) {
            isPresented = false
            onManageWorktrees(repo)
          }
        }
      } label: {
        manageFooterLabel(text: "Manage Worktrees…")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .help("Pick a repository to inspect its worktrees")
    }
  }

  private func manageFooterLabel(text: String) -> some View {
    HStack {
      Image(systemName: "list.bullet.rectangle")
        .foregroundStyle(.secondary)
      Text(text)
        .font(.callout.weight(.medium))
      Spacer()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .contentShape(Rectangle())
  }

  private func isIncluded(_ repo: Repository) -> Bool {
    filters.selectedRepositoryIDs.contains(repo.id)
      && !filters.showsAllRepositories
  }
}
