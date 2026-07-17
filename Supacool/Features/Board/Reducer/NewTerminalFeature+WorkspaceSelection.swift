import Foundation
import IdentifiedCollections

/// The workspace-selection inference, canonical-query, worktree
/// adoption/ownership, and submit-time resolution helpers, mechanically
/// extracted from `NewTerminalFeature.swift`; behavior identical.
extension NewTerminalFeature {
  // MARK: - Selection inference

  /// Given a free-text query, figure out what workspace the user means.
  /// Exact matches (worktree > local branch > remote branch) win;
  /// otherwise it's a new-branch candidate. Empty query = repo root.
  static func inferSelection(from rawQuery: String, state: State) -> WorkspaceSelection {
    let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return .repoRoot }

    // 1) Existing worktree (match against branch or name).
    if let repoID = state.selectedRepositoryID,
      let repo = state.availableRepositories[id: repoID]
    {
      if let wt = repo.worktrees.first(where: { ($0.branch ?? $0.name) == trimmed && $0.isWorktree }) {
        return .existingWorktree(id: wt.id)
      }
    }
    // 2) Existing local branch.
    if state.availableLocalBranches.contains(trimmed) {
      return .existingBranch(name: trimmed)
    }
    // 3) Full remote ref match (e.g. typed "origin/feat-x").
    if state.availableRemoteBranches.contains(trimmed) {
      return .existingBranch(name: stripRemotePrefix(trimmed))
    }
    // 4) Short name matches a remote branch's local-part (e.g. "feat-x" → "origin/feat-x").
    if state.availableRemoteBranches.contains(where: { stripRemotePrefix($0) == trimmed }) {
      return .existingBranch(name: trimmed)
    }
    // 5) Fallback: new branch.
    return .newBranch(name: trimmed)
  }

  /// Canonical text to display in the query field for a given selection.
  static func canonicalQuery(for selection: WorkspaceSelection, state: State) -> String {
    switch selection {
    case .repoRoot:
      return ""
    case .existingWorktree(let id):
      if let repoID = state.selectedRepositoryID,
        let repo = state.availableRepositories[id: repoID],
        let wt = repo.worktrees.first(where: { $0.id == id })
      {
        return wt.branch ?? wt.name
      }
      return URL(fileURLWithPath: id).lastPathComponent
    case .existingBranch(let name), .newBranch(let name):
      return name
    }
  }

  static func stripRemotePrefix(_ ref: String) -> String {
    if let slashIdx = ref.firstIndex(of: "/") {
      return String(ref[ref.index(after: slashIdx)...])
    }
    return ref
  }

  /// If the target worktree directory is still on disk and looks like a
  /// live git worktree (its `.git` marker is present), return a Worktree
  /// pointing at it so the caller can skip `git worktree add`. Used to
  /// recover from rerun where the previous session's directory was
  /// preserved but git's record (or the in-app cache) drifted. Returns
  /// nil when there's nothing to adopt — let the normal create path
  /// handle (and surface) the real failure.
  /// Returns true when the `.existingBranch(name: branchName)` selection
  /// in `createButtonTapped` was pre-armed by the PR banner (as opposed
  /// to typed manually in the workspace field). Drives the force-fetch
  /// path: PR branches are remote-by-definition, so we fetch even when
  /// the global `fetchOriginBeforeWorktreeCreation` setting is off.
  nonisolated static func isPRArmedExistingBranch(
    pullRequestLookup: PullRequestLookupState,
    branchName: String
  ) -> Bool {
    guard case .resolved(let context) = pullRequestLookup else { return false }
    return context.metadata.headRefName == branchName
  }

  nonisolated static func adoptExistingWorktreeDirectory(
    branchName: String,
    baseDirectory: URL,
    repoRootURL: URL
  ) -> Worktree? {
    let worktreeURL = baseDirectory
      .appending(path: branchName, directoryHint: .isDirectory)
      .standardizedFileURL
    let fileManager = FileManager.default
    let worktreePath = worktreeURL.path(percentEncoded: false)
    let gitMarkerPath = worktreeURL.appendingPathComponent(".git").path(percentEncoded: false)
    guard fileManager.fileExists(atPath: worktreePath),
      fileManager.fileExists(atPath: gitMarkerPath)
    else {
      return nil
    }
    let repositoryRootURL = repoRootURL.standardizedFileURL
    return Worktree(
      id: worktreePath,
      name: branchName,
      detail: "",
      workingDirectory: worktreeURL,
      repositoryRootURL: repositoryRootURL,
      createdAt: nil,
      branch: branchName
    )
  }

  /// Policy: any session that points at a worktree (= anything except
  /// `.repoRoot`) cleans up that worktree when the card is removed.
  /// The earlier "only own what we created" carve-out gave us
  /// orphaned directories whenever a user picked an existing worktree
  /// from the picker — too easy to forget the cleanup. The
  /// `sessionsUsingWorkspace` ref-count guard in `BoardFeature
  /// .removeSession` still prevents removal of a worktree that
  /// another card is using.
  static func shouldRemoveBackingWorktreeOnDelete(
    selection: WorkspaceSelection
  ) -> Bool {
    switch selection {
    case .repoRoot:
      return false
    case .existingWorktree, .existingBranch, .newBranch:
      return true
    }
  }

  /// Submit-time normalization point for the user's workspace choice.
  /// This intentionally does **not** promote `.repoRoot` to a generated
  /// worktree. The Scope picker says "Main" runs at the repo root, and
  /// the reducer must honor that exact selection. SessionSpawner may do a
  /// best-effort repo-root sync, but it does not rewrite this choice.
  nonisolated static func resolveSubmittedSelection(
    selection: WorkspaceSelection,
    agent _: AgentType?,
    trimmedPrompt _: String,
    rerunOwnedWorktreeID _: String?
  ) -> WorkspaceSelection {
    selection
  }

  /// Pre-resolves the card's display name when the sheet has enough
  /// context to do better than chopping the prompt into 5 words. PR-armed
  /// flows produce `"PR #42: title"`; Linear-armed flows produce
  /// `"CEN-6690 · title"`. Returns `nil` when neither applies, letting
  /// `AgentSession.deriveDisplayName` handle the fallback.
  ///
  /// PR resolution wins over Linear because a pasted PR URL is the
  /// strongest signal in the sheet — the user explicitly aimed at a
  /// specific PR. A Linear id in the prompt could just be a passing
  /// reference.
  static func suggestedDisplayName(state: State) -> String? {
    if case .resolved(let context) = state.pullRequestLookup {
      return "PR #\(context.parsed.number): \(context.metadata.title)"
    }
    if let ticketID = state.activeLinearTicketID,
      let title = state.linearTitleCache[ticketID], !title.isEmpty
    {
      return displayNameFromLinearTitle(ticketID: ticketID, title: title)
    }
    return nil
  }
}

/// Error surfaced from the create effect when the state snapshot taken at
/// submit-time no longer matches reality (e.g. the picked existing
/// worktree was removed between picker-time and submit).
nonisolated enum NewTerminalError: LocalizedError {
  case worktreeMissing
  /// Neither the local branch nor the remote-tracking ref exists, and a
  /// refspec fetch against the first configured remote failed. Without
  /// a resolvable ref, `git worktree add` would emit its cryptic
  /// "invalid reference" — this surfaces something the user can act on.
  case branchNotFoundAfterFetch(name: String)
  /// `git worktree add <path> <branch>` would fail because the branch is
  /// already checked out at a *different* path. Carries the conflicting
  /// `Worktree` so the BoardFeature can offer Reuse / Delete & recreate.
  case branchAlreadyCheckedOut(branch: String, existing: Worktree)
  var errorDescription: String? {
    switch self {
    case .worktreeMissing: "Picked worktree is no longer available."
    case .branchNotFoundAfterFetch(let name):
      "Branch '\(name)' not found locally or on any configured remote."
    case .branchAlreadyCheckedOut(let branch, let existing):
      "Branch '\(branch)' is already checked out at "
        + "\(existing.workingDirectory.path(percentEncoded: false))."
    }
  }
}

extension String {
  /// Returns the remote name if this ref starts with `<remote>/`, matched
  /// against known remotes. Longest-match wins to handle ambiguous
  /// prefixes (e.g. `origin` vs `origin-mirror`). Named distinctly from
  /// upstream supacode's `matchingRemote` to avoid collisions on future
  /// upstream syncs.
  nonisolated func supacoolMatchingRemote(from remotes: [String]) -> String? {
    remotes.sorted { $0.count > $1.count }.first { hasPrefix("\($0)/") }
  }
}
