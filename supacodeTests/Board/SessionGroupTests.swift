import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import Supacool

@MainActor
struct SessionGroupTests {
  // MARK: - Membership / cycle helpers (pure)

  @Test func memberAfterAndBeforeWrapAround() {
    let a = UUID(), b = UUID(), c = UUID()
    let group = SessionGroup(name: "Trio", sessionIDs: [a, b, c])

    #expect(group.memberAfter(a) == b)
    #expect(group.memberAfter(c) == a)  // wraps
    #expect(group.memberBefore(a) == c)  // wraps
    #expect(group.memberBefore(b) == a)
  }

  @Test func singleMemberGroupHasNothingToCycleTo() {
    let a = UUID()
    let group = SessionGroup(name: "Solo", sessionIDs: [a])
    #expect(group.memberAfter(a) == nil)
    #expect(group.memberBefore(a) == nil)
  }

  @Test func cycleFromNonMemberReturnsNil() {
    let a = UUID(), b = UUID(), stranger = UUID()
    let group = SessionGroup(name: "Pair", sessionIDs: [a, b])
    #expect(group.memberAfter(stranger) == nil)
    #expect(group.memberBefore(stranger) == nil)
  }

  // MARK: - Purging on permanent removal

  @Test func purgingRemovesMemberAndDropsEmptiedGroups() {
    let a = UUID(), b = UUID(), c = UUID()
    let pair = SessionGroup(name: "Pair", sessionIDs: [a, b])
    let solo = SessionGroup(name: "Solo", sessionIDs: [a])
    let other = SessionGroup(name: "Other", sessionIDs: [c])

    let result = SessionGroup.purging(sessionID: a, from: [pair, solo, other])

    // `pair` keeps [b]; `solo` emptied → dropped; `other` untouched.
    #expect(result.count == 2)
    #expect(result[0].id == pair.id)
    #expect(result[0].sessionIDs == [b])
    #expect(result[1].id == other.id)
    #expect(result[1].sessionIDs == [c])
  }

  // MARK: - Forward-compatible decoding

  @Test func decodingMissingOptionalFieldsFallsBackToDefaults() throws {
    let json = """
      {
        "id": "00000000-0000-0000-0000-000000000009",
        "name": "Feature + tests"
      }
      """
    let group = try JSONDecoder().decode(SessionGroup.self, from: Data(json.utf8))
    #expect(group.id == UUID(uuidString: "00000000-0000-0000-0000-000000000009"))
    #expect(group.name == "Feature + tests")
    #expect(group.sessionIDs == [])
  }

  // MARK: - Reducer: pin / add / remove / rename / delete

  @Test(.dependencies) func pinSessionToNewGroupCreatesGroupWithGivenName() async {
    let session = Self.sampleSession()
    let groupID = UUID(uuidString: "11111111-0000-0000-0000-000000000001")!
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let store = TestStore(initialState: BoardFeature.State()) {
      BoardFeature()
    } withDependencies: {
      $0.uuid = .constant(groupID)
      $0.date = .constant(now)
    }

    await store.send(.pinSessionToNewGroup(id: session.id, name: "  Feature + tests  ")) {
      $0.$sessionGroups.withLock {
        $0 = [
          SessionGroup(
            id: groupID,
            name: "Feature + tests",
            sessionIDs: [session.id],
            createdAt: now
          ),
        ]
      }
    }
  }

  @Test(.dependencies) func pinWithBlankNameAndNoMatchingSessionFallsBackToGroupLabel() async {
    // Blank name + no matching session exercises the `?? "Group"` tail of
    // the fallback (a present session would contribute its displayName).
    let orphanID = UUID()
    let groupID = UUID(uuidString: "11111111-0000-0000-0000-000000000002")!
    let now = Date(timeIntervalSince1970: 0)
    let store = TestStore(initialState: BoardFeature.State()) {
      BoardFeature()
    } withDependencies: {
      $0.uuid = .constant(groupID)
      $0.date = .constant(now)
    }
    store.exhaustivity = .off

    await store.send(.pinSessionToNewGroup(id: orphanID, name: "   "))
    #expect(store.state.sessionGroups.count == 1)
    #expect(store.state.sessionGroups.first?.name == "Group")
    #expect(store.state.sessionGroups.first?.sessionIDs == [orphanID])
  }

  @Test(.dependencies) func addSessionToGroupAppendsSecondAndIgnoresDuplicate() async {
    let a = UUID(), b = UUID()
    let group = SessionGroup(name: "Pair", sessionIDs: [a])
    let store = TestStore(
      initialState: {
        let state = BoardFeature.State()
        state.$sessionGroups.withLock { $0 = [group] }
        return state
      }()
    ) {
      BoardFeature()
    }

    await store.send(.addSessionToGroup(id: b, groupID: group.id)) {
      $0.$sessionGroups.withLock { $0[0].sessionIDs = [a, b] }
    }
    // Re-adding an existing member is a no-op.
    await store.send(.addSessionToGroup(id: b, groupID: group.id))
  }

  @Test(.dependencies) func removeSessionFromGroupDeletesGroupWhenEmptied() async {
    let a = UUID(), b = UUID()
    let group = SessionGroup(name: "Pair", sessionIDs: [a, b])
    let store = TestStore(
      initialState: {
        let state = BoardFeature.State()
        state.$sessionGroups.withLock { $0 = [group] }
        return state
      }()
    ) {
      BoardFeature()
    }

    await store.send(.removeSessionFromGroup(id: a, groupID: group.id)) {
      $0.$sessionGroups.withLock { $0[0].sessionIDs = [b] }
    }
    await store.send(.removeSessionFromGroup(id: b, groupID: group.id)) {
      $0.$sessionGroups.withLock { $0 = [] }
    }
  }

  @Test(.dependencies) func renameGroupIgnoresBlankAndTrimsOtherwise() async {
    let group = SessionGroup(name: "Old", sessionIDs: [UUID()])
    let store = TestStore(
      initialState: {
        let state = BoardFeature.State()
        state.$sessionGroups.withLock { $0 = [group] }
        return state
      }()
    ) {
      BoardFeature()
    }
    store.exhaustivity = .off

    await store.send(.renameGroup(id: group.id, name: "   "))  // blank → ignored
    #expect(store.state.sessionGroups.first?.name == "Old")
    await store.send(.renameGroup(id: group.id, name: "  New name "))  // trimmed
    #expect(store.state.sessionGroups.first?.name == "New name")
  }

  @Test(.dependencies) func deleteGroupRemovesIt() async {
    let group = SessionGroup(name: "Doomed", sessionIDs: [UUID()])
    let store = TestStore(
      initialState: {
        let state = BoardFeature.State()
        state.$sessionGroups.withLock { $0 = [group] }
        return state
      }()
    ) {
      BoardFeature()
    }

    await store.send(.deleteGroup(id: group.id)) {
      $0.$sessionGroups.withLock { $0 = [] }
    }
  }

  // MARK: - Reducer: cycle drives full-screen focus

  @Test(.dependencies) func cycleForwardFocusesNextMember() async {
    let a = UUID(), b = UUID()
    let group = SessionGroup(name: "Pair", sessionIDs: [a, b])
    let store = TestStore(
      initialState: {
        var state = BoardFeature.State()
        state.$sessionGroups.withLock { $0 = [group] }
        state.focusedSessionID = a
        return state
      }()
    ) {
      BoardFeature()
    }
    store.exhaustivity = .off

    await store.send(.cycleGroup(from: a, direction: .forward))
    await store.receive(\.focusForward)
    #expect(store.state.focusedSessionID == b)
  }

  @Test(.dependencies) func cycleOnSingleMemberGroupIsNoOp() async {
    let a = UUID()
    let group = SessionGroup(name: "Solo", sessionIDs: [a])
    let store = TestStore(
      initialState: {
        var state = BoardFeature.State()
        state.$sessionGroups.withLock { $0 = [group] }
        state.focusedSessionID = a
        return state
      }()
    ) {
      BoardFeature()
    }
    store.exhaustivity = .off

    // No `.focusForward` is emitted; focus stays put.
    await store.send(.cycleGroup(from: a, direction: .forward))
    #expect(store.state.focusedSessionID == a)
  }

  // MARK: - Reducer: drag-to-group (drop one card onto another)

  @Test(.dependencies) func dropOntoUngroupedTargetFormsNewPair() async {
    let dragged = UUID(), target = UUID()
    let groupID = UUID(uuidString: "22222222-0000-0000-0000-000000000001")!
    let now = Date(timeIntervalSince1970: 0)
    let store = TestStore(initialState: BoardFeature.State()) {
      BoardFeature()
    } withDependencies: {
      $0.uuid = .constant(groupID)
      $0.date = .constant(now)
    }
    store.exhaustivity = .off

    await store.send(.dropSessionOntoSession(dragged: dragged, target: target))
    #expect(store.state.sessionGroups.count == 1)
    // Target is the anchor → listed first.
    #expect(store.state.sessionGroups.first?.sessionIDs == [target, dragged])
    #expect(store.state.sessionGroups.first?.name == "Group")
  }

  @Test(.dependencies) func dropOntoGroupedTargetJoinsThatGroup() async {
    let a = UUID(), b = UUID(), dragged = UUID()
    let group = SessionGroup(name: "Pair", sessionIDs: [a, b])
    let store = TestStore(
      initialState: {
        let state = BoardFeature.State()
        state.$sessionGroups.withLock { $0 = [group] }
        return state
      }()
    ) {
      BoardFeature()
    }
    store.exhaustivity = .off

    // Dropped onto `a`, which is already grouped → dragged joins that group,
    // no new group is formed.
    await store.send(.dropSessionOntoSession(dragged: dragged, target: a))
    #expect(store.state.sessionGroups.count == 1)
    #expect(store.state.sessionGroups.first?.sessionIDs == [a, b, dragged])
  }

  @Test(.dependencies) func dropGroupedCardOntoUngroupedTargetPullsTargetIn() async {
    let a = UUID(), b = UUID(), target = UUID()
    let group = SessionGroup(name: "Pair", sessionIDs: [a, b])
    let store = TestStore(
      initialState: {
        let state = BoardFeature.State()
        state.$sessionGroups.withLock { $0 = [group] }
        return state
      }()
    ) {
      BoardFeature()
    }
    store.exhaustivity = .off

    // `a` is grouped, `target` is not → target is added to a's group.
    await store.send(.dropSessionOntoSession(dragged: a, target: target))
    #expect(store.state.sessionGroups.count == 1)
    #expect(store.state.sessionGroups.first?.sessionIDs == [a, b, target])
  }

  @Test(.dependencies) func dropOntoSelfIsNoOp() async {
    let a = UUID()
    let store = TestStore(initialState: BoardFeature.State()) {
      BoardFeature()
    }
    store.exhaustivity = .off

    await store.send(.dropSessionOntoSession(dragged: a, target: a))
    #expect(store.state.sessionGroups.isEmpty)
  }

  // MARK: - Helpers

  private static func sampleSession(
    id: UUID = UUID(),
    repositoryID: String = "/tmp/repo",
    prompt: String = "Investigate"
  ) -> AgentSession {
    AgentSession(
      id: id,
      repositoryID: repositoryID,
      worktreeID: repositoryID,
      agent: .claude,
      initialPrompt: prompt
    )
  }
}
