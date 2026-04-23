import ComposableArchitecture
import Foundation
import IdentifiedCollections

private nonisolated let janitorLogger = SupaLogger("Supacool.WorktreeJanitor")

/// Read-only "Manage Worktrees…" sheet — enumerates every worktree
/// registered for a repo, classifies each against the live session list,
/// and streams in size + git metadata so the user can spot disk hogs and
/// orphans (worktrees Supacool no longer references) at a glance.
///
/// PR2 ships **inspect only**. The table renders status, size, last
/// commit, and dirty count; the existing `pruneWorktreesRequested` flow
/// in `BoardFeature` is untouched. PR3 adds multi-select + delete and
/// folds the prune flow inside the Janitor's scan.
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

  enum Action: Equatable {
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
    /// User clicked Done / Cancel in the sheet footer. Parent dismisses
    /// the @Presents state when it sees this delegate.
    case closeRequested
    case delegate(Delegate)
  }

  @CasePathable
  enum Delegate: Equatable {
    /// Sheet wants to be dismissed. Parent sets `state.janitor = nil`.
    case dismissed
  }

  @Dependency(WorktreeInventoryClient.self) var inventory

  /// Best-effort base ref for ahead/behind comparisons. PR2 hardcodes
  /// `origin/HEAD` — when the repo doesn't have a symbolic-ref set up
  /// the rev-list call returns nil and the column simply renders as
  /// "—". PR3 will resolve the actual default branch up front so the
  /// values are accurate even on freshly-cloned repos.
  private static let defaultBaseRef = "origin/HEAD"

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
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
            // Skip the repo root and any classification we already
            // know shouldn't be touched — measuring the parent of
            // every worktree would double-count disk usage.
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

      case .closeRequested:
        return .send(.delegate(.dismissed))

      case .delegate:
        return .none
      }
    }
  }
}

// MARK: - Cancellation IDs

private nonisolated struct ScanCancelID: Hashable, Sendable {
  let repositoryID: Repository.ID
}
