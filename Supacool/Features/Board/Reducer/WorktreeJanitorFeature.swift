import ComposableArchitecture
import Foundation
import IdentifiedCollections

private nonisolated let janitorLogger = SupaLogger("Supacool.WorktreeJanitor")

/// "Manage Worktrees…" sheet — enumerates every worktree registered for
/// a repo, classifies each against the live session list, streams size
/// + git metadata in per-row, and lets the user multi-select + delete
/// orphans to reclaim disk.
///
/// Scope by PR:
/// - PR2 (shipped): read-only scan + classification
/// - PR3 (this): multi-select + bulk delete with confirmation
/// - later: fold `git worktree prune` into the scan, per-row diff stat
///
/// Cancellation: the scan effect is keyed by `repositoryID`. When the
/// sheet is dismissed (parent sets state to nil via `@Presents`), TCA's
/// `ifLet` tears down the child reducer and any in-flight effects with
/// it — no manual cleanup needed.
@Reducer
struct WorktreeJanitorFeature {
  @ObservableState
  struct State: Equatable {
    let repositoryID: Repository.ID
    let repositoryName: String
    /// Snapshot of the parent's session list at sheet-open time. Used
    /// for classification only; the inventory does not subscribe to
    /// live session changes (sheet is a transient inspector).
    let sessionsSnapshot: [AgentSession]
    /// Inventory rows keyed by absolute worktree path. Empty until
    /// `_listLoaded` arrives. Mutated row-by-row as size + git metadata
    /// stream in.
    var rows: IdentifiedArrayOf<WorktreeInventoryEntry> = []
    /// True from sheet open until the per-row metadata fan-out
    /// completes (or fails). Drives the table's footer "Scanning…"
    /// label.
    var isScanning: Bool = false
    /// Set when the initial `list` call throws. Renders inline in the
    /// table footer instead of an alert (the user can still see what
    /// the scan got before the failure).
    var scanError: String?

    /// Paths the user has ticked for deletion. Only rows whose status
    /// is a deletion candidate may appear here; `toggleSelection` is
    /// the single enforcement point.
    var selectedIDs: Set<WorktreeInventoryEntry.ID> = []
    /// Paths currently in flight for delete. UI renders a spinner or
    /// dimmed row for these; used to guard against double-click.
    var deletingIDs: Set<WorktreeInventoryEntry.ID> = []
    /// Pending delete confirmation dialog contents. Non-nil → dialog
    /// is shown. Cleared on confirm/cancel.
    var deleteConfirmation: DeleteConfirmation?
    /// Accumulated failure messages from the most recent delete batch.
    /// Rendered inline in the footer so the user can see which
    /// orphans survived (typical cause: pre-delete script failure on
    /// a tracked worktree that sneaked into the selection).
    var deleteErrors: [String] = []

    /// Only candidate rows (orphan / orphan-dirty) are eligible for
    /// selection. Derived — cheap to recompute, not persisted.
    var candidateIDs: Set<WorktreeInventoryEntry.ID> {
      Set(rows.filter(\.isDeletionCandidate).map(\.id))
    }

    /// Total bytes across `selectedIDs`. Zero while sizes haven't
    /// streamed in yet.
    var selectedReclaimBytes: UInt64 {
      rows
        .filter { selectedIDs.contains($0.id) }
        .reduce(UInt64(0)) { acc, row in acc + (row.sizeBytes ?? 0) }
    }

    init(
      repositoryID: Repository.ID,
      repositoryName: String,
      sessionsSnapshot: [AgentSession]
    ) {
      self.repositoryID = repositoryID
      self.repositoryName = repositoryName
      self.sessionsSnapshot = sessionsSnapshot
    }
  }

  /// Minimal payload the confirmation dialog needs to render a preview
  /// of what's about to go. `id` makes the struct SwiftUI-friendly for
  /// `.confirmationDialog(presenting:)`.
  nonisolated struct DeleteConfirmation: Equatable, Identifiable, Sendable {
    let id: UUID
    /// Snapshot of what's being deleted. Frozen at confirmation time
    /// so a race between "confirm tap" and "delete fires" can't widen
    /// the blast radius if the user changes selection in the
    /// intervening millisecond.
    let targets: [Target]

    nonisolated struct Target: Equatable, Identifiable, Sendable {
      let id: WorktreeInventoryEntry.ID
      let name: String
      let branch: String?
      let sizeBytes: UInt64?
      let isDirty: Bool
    }

    var totalBytes: UInt64 {
      targets.reduce(UInt64(0)) { $0 + ($1.sizeBytes ?? 0) }
    }

    var hasDirty: Bool { targets.contains(where: \.isDirty) }
  }

  enum Action: Equatable {
    // MARK: Scan
    /// Fired by `.task` on sheet appear. Idempotent — guarded by
    /// `isScanning` so re-renders don't relaunch.
    case scanRequested
    /// Initial `wt`/git list returned. Carries the classified rows.
    case _listLoaded([WorktreeInventoryEntry])
    /// Initial list call threw. Surfaces inline rather than aborting.
    case _listFailed(message: String)
    /// `du -sk` returned for one row.
    case _sizeLoaded(rowID: WorktreeInventoryEntry.ID, bytes: UInt64)
    /// `git log -1` + `status --porcelain` + `rev-list` returned for
    /// one row.
    case _metadataLoaded(
      rowID: WorktreeInventoryEntry.ID,
      metadata: WorktreeInventoryGitMetadata
    )
    /// Per-row metadata fan-out finished — flips `isScanning` off.
    case _scanCompleted

    // MARK: Selection
    case toggleSelection(id: WorktreeInventoryEntry.ID)
    case selectAllCandidates
    case clearSelection

    // MARK: Delete
    /// User clicked "Delete N worktrees…" in the footer. Populates
    /// `deleteConfirmation`.
    case deleteSelectedRequested
    case deleteConfirmationCancelled
    case deleteConfirmed
    /// One row finished deleting (success or failure). Updates state
    /// optimistically — successful deletes shrink the table.
    case _deleteCompleted(
      id: WorktreeInventoryEntry.ID,
      result: DeleteResult
    )

    // MARK: Dismissal
    case closeRequested
    case delegate(Delegate)
  }

  nonisolated enum DeleteResult: Equatable, Sendable {
    case success
    case failure(message: String)
  }

  @CasePathable
  enum Delegate: Equatable {
    /// Sheet wants to be dismissed. Parent sets `state.janitor = nil`.
    case dismissed
  }

  @Dependency(WorktreeInventoryClient.self) var inventory
  @Dependency(GitClientDependency.self) var gitClient

  /// Best-effort base ref for ahead/behind comparisons. Hardcoded to
  /// `origin/HEAD` — when the repo doesn't have the symbolic-ref set up
  /// the rev-list call silently returns nil and the column renders as
  /// "—". A future PR will resolve the actual default branch up front
  /// so the values are accurate even on freshly-cloned repos.
  private static let defaultBaseRef = "origin/HEAD"

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      // MARK: - Scan

      case .scanRequested:
        guard !state.isScanning, state.rows.isEmpty else {
          // Already scanning or already scanned. `task` fires on every
          // appear — guard against re-entry without forcing the sheet
          // owner to track it.
          return .none
        }
        state.isScanning = true
        state.scanError = nil
        let repositoryID = state.repositoryID
        let sessions = state.sessionsSnapshot
        return .run { [inventory] send in
          let entries: [GitWtWorktreeEntry]
          do {
            entries = try await inventory.list(URL(fileURLWithPath: repositoryID))
          } catch {
            janitorLogger.warning(
              "list failed for \(repositoryID): \(error.localizedDescription)"
            )
            await send(._listFailed(message: error.localizedDescription))
            return
          }
          let rows = classifyWorktreeInventory(
            entries: entries,
            sessions: sessions,
            repositoryID: repositoryID
          )
          await send(._listLoaded(rows))

          // Fan out per-row metadata loads. Sequential across rows
          // keeps disk pressure manageable on large repos (47-worktree
          // centrum_backend would spawn 94 concurrent shell processes
          // otherwise); the two calls *within* a row run in parallel
          // via `async let` so each row settles in one round-trip.
          for row in rows {
            if case .repoRoot = row.status { continue }
            let path = URL(fileURLWithPath: row.id)
            async let sizeTask: UInt64? = try? await inventory.measure(path)
            async let metadataTask: WorktreeInventoryGitMetadata? =
              try? await inventory.gitMetadata(path, Self.defaultBaseRef)
            if let bytes = await sizeTask {
              await send(._sizeLoaded(rowID: row.id, bytes: bytes))
            }
            if let metadata = await metadataTask {
              await send(._metadataLoaded(rowID: row.id, metadata: metadata))
            }
          }
          await send(._scanCompleted)
        }
        .cancellable(id: ScanCancelID(repositoryID: state.repositoryID), cancelInFlight: true)

      case ._listLoaded(let rows):
        state.rows = IdentifiedArray(uniqueElements: rows)
        return .none

      case ._listFailed(let message):
        state.scanError = message
        state.isScanning = false
        return .none

      case ._sizeLoaded(let id, let bytes):
        state.rows[id: id]?.sizeBytes = bytes
        return .none

      case ._metadataLoaded(let id, let metadata):
        guard var row = state.rows[id: id] else { return .none }
        row.lastCommit = metadata.lastCommit
        row.aheadBehind = metadata.aheadBehind
        row = applyUncommittedCount(metadata.uncommittedCount, to: row)
        state.rows[id: id] = row
        return .none

      case ._scanCompleted:
        state.isScanning = false
        return .none

      // MARK: - Selection

      case .toggleSelection(let id):
        // Only candidates are selectable. Guarding here (rather than
        // in the view) means a stale tap after a row changed status
        // can't silently add an ineligible row.
        guard let row = state.rows[id: id], row.isDeletionCandidate else {
          return .none
        }
        if state.selectedIDs.contains(id) {
          state.selectedIDs.remove(id)
        } else {
          state.selectedIDs.insert(id)
        }
        return .none

      case .selectAllCandidates:
        state.selectedIDs = state.candidateIDs
        return .none

      case .clearSelection:
        state.selectedIDs.removeAll()
        return .none

      // MARK: - Delete

      case .deleteSelectedRequested:
        guard !state.selectedIDs.isEmpty else { return .none }
        let targets: [DeleteConfirmation.Target] =
          state.rows
          .filter { state.selectedIDs.contains($0.id) }
          .map { row in
            DeleteConfirmation.Target(
              id: row.id,
              name: row.name,
              branch: row.branch,
              sizeBytes: row.sizeBytes,
              isDirty: isDirty(row.status)
            )
          }
        state.deleteConfirmation = DeleteConfirmation(id: UUID(), targets: targets)
        return .none

      case .deleteConfirmationCancelled:
        state.deleteConfirmation = nil
        return .none

      case .deleteConfirmed:
        guard let confirmation = state.deleteConfirmation else { return .none }
        state.deleteConfirmation = nil
        state.deleteErrors = []
        let repositoryRootURL = URL(fileURLWithPath: state.repositoryID)
        let targets = confirmation.targets
        // Track in-flight deletes so the UI can dim/disable the rows.
        for target in targets {
          state.deletingIDs.insert(target.id)
        }
        return .run { [gitClient] send in
          // Sequential — parallelizing worktree removals contends on
          // git's lock and produces confusing error output. Batch size
          // is bounded by the user's selection, so it's fine.
          for target in targets {
            let result = await removeOrphanWorktree(
              gitClient: gitClient,
              target: target,
              repositoryRootURL: repositoryRootURL
            )
            await send(._deleteCompleted(id: target.id, result: result))
          }
        }

      case ._deleteCompleted(let id, .success):
        state.deletingIDs.remove(id)
        state.selectedIDs.remove(id)
        state.rows.remove(id: id)
        return .none

      case ._deleteCompleted(let id, .failure(let message)):
        state.deletingIDs.remove(id)
        // Leave the row and its selection alone so the user can see
        // which one failed; the error message is surfaced in the
        // footer.
        let name = state.rows[id: id]?.name ?? id
        state.deleteErrors.append("\(name): \(message)")
        return .none

      // MARK: - Dismissal

      case .closeRequested:
        return .send(.delegate(.dismissed))

      case .delegate:
        return .none
      }
    }
  }
}

// MARK: - Delete side effect

/// Call `gitClient.removeWorktree` against a synthesized `Worktree`
/// value built from the inventory row. Runs outside the reducer so the
/// latter stays pure.
///
/// Orphan worktrees aren't in `RepositoriesFeature.repositories` state
/// (that's what makes them orphans), so we can't route through the
/// existing `deleteWorktreeConfirmed` path. Synthesizing directly is
/// simpler than adding a parallel action to RepositoriesFeature — and
/// it skips the pre-delete script, which is a deliberate choice:
/// scripts are configured per-repo and typically reference build
/// state that's already stale on an orphan.
private func removeOrphanWorktree(
  gitClient: GitClientDependency,
  target: WorktreeJanitorFeature.DeleteConfirmation.Target,
  repositoryRootURL: URL
) async -> WorktreeJanitorFeature.DeleteResult {
  let workingDirectory = URL(fileURLWithPath: target.id)
  let synthetic = Worktree(
    id: target.id,
    // `name` is what gitClient uses to resolve the branch to delete
    // when `deleteBranchOnDeleteWorktree` is true. Fall back to the
    // directory name so we still remove the worktree itself even
    // when branch inference is ambiguous.
    name: target.branch ?? workingDirectory.lastPathComponent,
    detail: target.id,
    workingDirectory: workingDirectory,
    repositoryRootURL: repositoryRootURL,
    createdAt: nil,
    branch: target.branch
  )
  do {
    // PR3 hardcodes `deleteBranch: false`. The branch may carry work
    // the user cares about (orphan ≠ unwanted commits), so we remove
    // the worktree only and leave branch-deletion to a future opt-in
    // toggle in the confirmation dialog.
    _ = try await gitClient.removeWorktree(synthetic, /* deleteBranch */ false)
    return .success
  } catch {
    janitorLogger.warning(
      "removeWorktree failed for \(target.id): \(error.localizedDescription)"
    )
    return .failure(message: error.localizedDescription)
  }
}

// MARK: - Helpers

/// True when a row's status reflects an orphan with local uncommitted
/// changes — lets the confirmation dialog surface a stronger warning.
private func isDirty(_ status: WorktreeInventoryEntry.Status) -> Bool {
  if case .orphanDirty = status { return true }
  return false
}

// MARK: - Cancellation IDs

private nonisolated struct ScanCancelID: Hashable, Sendable {
  let repositoryID: Repository.ID
}
