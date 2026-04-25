import ComposableArchitecture
import Foundation
import IdentifiedCollections

private nonisolated let janitorLogger = SupaLogger("Supacool.WorktreeJanitor")

/// "Manage Worktrees…" sheet — single entry point for inspecting,
/// cleaning, and deleting worktrees for a repo.
///
/// The scan pipeline:
///   1. `git worktree prune` — reaps stale admin records so the list
///      is trustworthy (replaces the old "Prune Stale Worktrees…"
///      affordance, now removed).
///   2. Resolve the repo's default branch via `symbolic-ref origin/HEAD`
///      → drives ahead/behind + diff-stat base. Falls back to
///      `origin/HEAD` when the symref isn't set.
///   3. List worktrees and classify against the live session snapshot.
///   4. Compute orphan session cards — sessions whose backing worktree
///      is no longer present in the inventory — and surface a banner
///      so the user can remove those cards in the same pass.
///   5. Fan out per-row size + git metadata (parallel within a row,
///      sequential across rows to bound disk pressure).
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
    /// for classification and orphan-session detection.
    let sessionsSnapshot: [AgentSession]
    /// Inventory rows keyed by absolute worktree path.
    var rows: IdentifiedArrayOf<WorktreeInventoryEntry> = []
    var isScanning: Bool = false
    var scanError: String?

    /// Base ref for ahead/behind + diff-stat. Starts at a fallback and
    /// gets replaced with the resolved `origin/<default-branch>` once
    /// the scan's `defaultBranchRef` call completes. Older rows that
    /// already fetched metadata against the fallback keep whatever
    /// ahead/behind they computed — the UI re-renders with the
    /// resolved value for newly-expanded diff stats.
    var baseRef: String = "origin/HEAD"
    /// Number of git worktree admin records pruned by the scan's
    /// opening `git worktree prune` step. Rendered in the footer so
    /// the user sees the equivalent of the old prune-toast summary.
    var prunedRefCount: Int = 0
    /// Sessions whose backing worktree isn't in the inventory any
    /// more. Surfaced as a banner at the top of the sheet; user can
    /// clear the cards (delegate) or dismiss the banner.
    var orphanSessionIDs: [AgentSession.ID] = []
    var orphanBannerDismissed: Bool = false

    // MARK: Selection / delete

    var selectedIDs: Set<WorktreeInventoryEntry.ID> = []
    var deletingIDs: Set<WorktreeInventoryEntry.ID> = []
    var deleteConfirmation: DeleteConfirmation?
    var deleteErrors: [String] = []
    /// Size of the current delete batch (set on `.deleteConfirmed`,
    /// cleared once `deletingIDs` drains). Drives the footer's
    /// "Deleting X of N…" progress label so the user sees forward
    /// motion instead of a stale "8 selected · reclaim Y" string.
    var deleteScheduledTotal: Int = 0

    // MARK: Row expansion

    /// Row whose disclosure chevron is open. Only one at a time so the
    /// sheet doesn't grow unbounded.
    var expandedRowID: WorktreeInventoryEntry.ID?
    /// Rows with an in-flight `diffStat` fetch. Drives the inline
    /// "Loading diff…" placeholder.
    var loadingDiffStatIDs: Set<WorktreeInventoryEntry.ID> = []

    // MARK: Derived

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

    /// True when the orphan banner should appear. Hides itself when
    /// there are no orphans *or* the user dismissed it.
    var showsOrphanBanner: Bool {
      !orphanSessionIDs.isEmpty && !orphanBannerDismissed
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

  /// Minimal payload the confirmation dialog needs.
  nonisolated struct DeleteConfirmation: Equatable, Identifiable, Sendable {
    let id: UUID
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
    case scanRequested
    /// `git worktree prune --verbose` finished — carries the count for
    /// the footer summary. Always fires (0 on error) so the UI can
    /// advance past the "scanning" state even when prune is denied.
    case _pruneCompleted(prunedRefCount: Int)
    /// Default branch resolved to a concrete ref like `origin/main`.
    case _baseRefResolved(String)
    /// Initial list returned. Carries classified rows *and* the orphan
    /// session ids computed against the inventory paths — folding both
    /// into one action avoids a state race where UI rendering sees
    /// rows without orphans (or vice versa).
    case _listLoaded(
      rows: [WorktreeInventoryEntry],
      orphanSessionIDs: [AgentSession.ID]
    )
    case _listFailed(message: String)
    case _sizeLoaded(rowID: WorktreeInventoryEntry.ID, bytes: UInt64)
    case _metadataLoaded(
      rowID: WorktreeInventoryEntry.ID,
      metadata: WorktreeInventoryGitMetadata
    )
    case _scanCompleted

    // MARK: Selection
    case toggleSelection(id: WorktreeInventoryEntry.ID)
    case selectAllCandidates
    case clearSelection

    // MARK: Delete
    case deleteSelectedRequested
    case deleteConfirmationCancelled
    case deleteConfirmed
    case _deleteCompleted(
      id: WorktreeInventoryEntry.ID,
      result: DeleteResult
    )

    // MARK: Row expansion
    /// Toggle the inline diff-stat drawer for a row. Fires a lazy
    /// `inventory.diffStat` fetch on the first expansion of each row.
    case toggleRowExpansion(id: WorktreeInventoryEntry.ID)
    case _diffStatLoaded(id: WorktreeInventoryEntry.ID, result: DiffStatResult)

    // MARK: Orphan session banner
    /// User clicked "Remove cards" in the orphan banner. Delegates up
    /// to the parent so `BoardFeature` can chain `.removeSession` for
    /// each id (which tears down the live tab + shared session state
    /// in one place instead of reimplementing it here).
    case removeOrphanCardsRequested
    case dismissOrphanBanner

    // MARK: Dismissal
    case closeRequested
    case delegate(Delegate)
  }

  nonisolated enum DeleteResult: Equatable, Sendable {
    case success
    case failure(message: String)
  }

  nonisolated enum DiffStatResult: Equatable, Sendable {
    case success(String)
    case failure(message: String)
  }

  @CasePathable
  enum Delegate: Equatable {
    case dismissed
    /// Parent should remove these session cards. Carries the ids
    /// computed during the last scan; parent is expected to chain
    /// `.removeSession` per id.
    case removeOrphanSessionCardsRequested(ids: [AgentSession.ID])
  }

  @Dependency(WorktreeInventoryClient.self) var inventory
  @Dependency(GitClientDependency.self) var gitClient
  @Dependency(SupacoolWorktreePruneClient.self) var worktreePrune

  /// Fallback when `defaultBranchRef` throws. Git treats `origin/HEAD`
  /// as a symbolic alias in most contexts, so rev-list / diff calls
  /// usually still work — just with a less precise error message when
  /// they don't.
  private static let fallbackBaseRef = "origin/HEAD"

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      // MARK: - Scan

      case .scanRequested:
        guard !state.isScanning, state.rows.isEmpty else {
          return .none
        }
        state.isScanning = true
        state.scanError = nil
        state.prunedRefCount = 0
        state.orphanSessionIDs = []
        state.orphanBannerDismissed = false
        state.baseRef = Self.fallbackBaseRef
        let repositoryID = state.repositoryID
        let sessions = state.sessionsSnapshot
        return .run { [inventory, worktreePrune] send in
          let repoRoot = URL(fileURLWithPath: repositoryID)

          // 1. Prune stale admin records so the list call returns
          //    ground truth. Silent on failure — prune is nice-to-have,
          //    not required for the rest of the scan.
          let prunedCount: Int
          do {
            let result = try await worktreePrune.prune(repoRoot)
            prunedCount = result.prunedRefs.count
          } catch {
            janitorLogger.warning(
              "prune failed for \(repositoryID): \(error.localizedDescription)"
            )
            prunedCount = 0
          }
          await send(._pruneCompleted(prunedRefCount: prunedCount))

          // 2. Resolve the default branch ref so per-row metadata
          //    queries report accurate ahead/behind. Fallback is
          //    baked into State at scan start, so failure here is a
          //    no-op beyond the log line.
          if let resolved = try? await inventory.defaultBranchRef(repoRoot) {
            await send(._baseRefResolved(resolved))
          } else {
            janitorLogger.debug(
              "defaultBranchRef unresolved for \(repositoryID); keeping fallback"
            )
          }

          // 3. List + classify.
          let entries: [GitWtWorktreeEntry]
          do {
            entries = try await inventory.list(repoRoot)
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

          // 4. Orphan session detection. Uses the same path-normalizer
          //    as classification so matching is consistent. Repo root
          //    is always in the inventory, so sessions at the root
          //    won't be flagged.
          let inventoryPaths = Set(rows.map(\.id))
          let orphanSessionIDs = findOrphanSessionIDsFromInventory(
            sessions: sessions,
            repositoryID: repositoryID,
            inventoryPaths: inventoryPaths
          )
          await send(._listLoaded(rows: rows, orphanSessionIDs: orphanSessionIDs))

          // 5. Per-row fan-out. Read the resolved base ref from the
          //    store via the send closure's current action payload is
          //    not possible — instead we duplicate the fallback here
          //    and accept that if `_baseRefResolved` hasn't landed by
          //    this point the ahead/behind queries use the fallback.
          //    In practice step 2 completes well before step 5.
          for row in rows {
            if case .repoRoot = row.status { continue }
            let path = URL(fileURLWithPath: row.id)
            async let sizeTask: UInt64? = try? await inventory.measure(path)
            async let metadataTask: WorktreeInventoryGitMetadata? =
              try? await inventory.gitMetadata(path, Self.fallbackBaseRef)
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

      case ._pruneCompleted(let count):
        state.prunedRefCount = count
        return .none

      case ._baseRefResolved(let ref):
        state.baseRef = ref
        return .none

      case ._listLoaded(let rows, let orphanSessionIDs):
        state.rows = IdentifiedArray(uniqueElements: rows)
        state.orphanSessionIDs = orphanSessionIDs
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
        for target in targets {
          state.deletingIDs.insert(target.id)
        }
        state.deleteScheduledTotal = targets.count
        return .run { [gitClient] send in
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
        if state.expandedRowID == id {
          state.expandedRowID = nil
        }
        state.rows.remove(id: id)
        if state.deletingIDs.isEmpty {
          state.deleteScheduledTotal = 0
        }
        return .none

      case ._deleteCompleted(let id, .failure(let message)):
        state.deletingIDs.remove(id)
        let name = state.rows[id: id]?.name ?? id
        state.deleteErrors.append("\(name): \(message)")
        if state.deletingIDs.isEmpty {
          state.deleteScheduledTotal = 0
        }
        return .none

      // MARK: - Row expansion

      case .toggleRowExpansion(let id):
        if state.expandedRowID == id {
          state.expandedRowID = nil
          return .none
        }
        state.expandedRowID = id
        // Only fetch the diff once per row — cached in-place on the
        // inventory entry.
        guard state.rows[id: id]?.diffStat == nil,
          !state.loadingDiffStatIDs.contains(id)
        else {
          return .none
        }
        state.loadingDiffStatIDs.insert(id)
        let baseRef = state.baseRef
        let path = URL(fileURLWithPath: id)
        return .run { [inventory] send in
          do {
            let output = try await inventory.diffStat(path, baseRef)
            await send(._diffStatLoaded(id: id, result: .success(output)))
          } catch {
            await send(
              ._diffStatLoaded(id: id, result: .failure(message: error.localizedDescription))
            )
          }
        }
        .cancellable(id: DiffStatCancelID(rowID: id), cancelInFlight: true)

      case ._diffStatLoaded(let id, .success(let output)):
        state.loadingDiffStatIDs.remove(id)
        // Empty output means "no diff vs base" — stash a sentinel so
        // we don't re-fetch on re-expand. Trim trailing whitespace so
        // the inline renderer's line-count heuristics stay sane.
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        state.rows[id: id]?.diffStat = trimmed.isEmpty ? "(no differences)" : output
        return .none

      case ._diffStatLoaded(let id, .failure(let message)):
        state.loadingDiffStatIDs.remove(id)
        state.rows[id: id]?.diffStat = "Failed to load diff: \(message)"
        return .none

      // MARK: - Orphan banner

      case .removeOrphanCardsRequested:
        let ids = state.orphanSessionIDs
        guard !ids.isEmpty else { return .none }
        state.orphanSessionIDs = []
        state.orphanBannerDismissed = false
        return .send(.delegate(.removeOrphanSessionCardsRequested(ids: ids)))

      case .dismissOrphanBanner:
        state.orphanBannerDismissed = true
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
/// value built from the inventory row.
private func removeOrphanWorktree(
  gitClient: GitClientDependency,
  target: WorktreeJanitorFeature.DeleteConfirmation.Target,
  repositoryRootURL: URL
) async -> WorktreeJanitorFeature.DeleteResult {
  let workingDirectory = URL(fileURLWithPath: target.id)
  let synthetic = Worktree(
    id: target.id,
    name: target.branch ?? workingDirectory.lastPathComponent,
    detail: target.id,
    workingDirectory: workingDirectory,
    repositoryRootURL: repositoryRootURL,
    createdAt: nil,
    branch: target.branch
  )
  do {
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

private func isDirty(_ status: WorktreeInventoryEntry.Status) -> Bool {
  if case .orphanDirty = status { return true }
  return false
}

// MARK: - Cancellation IDs

private nonisolated struct ScanCancelID: Hashable, Sendable {
  let repositoryID: Repository.ID
}

private nonisolated struct DiffStatCancelID: Hashable, Sendable {
  let rowID: WorktreeInventoryEntry.ID
}
