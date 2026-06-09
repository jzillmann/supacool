import ComposableArchitecture
import CustomDump
import Foundation
import Sentry

extension Reducer where State: Equatable {
  @ReducerBuilder<State, Action>
  func logActions() -> some Reducer<State, Action> {
    LogActionsReducer(base: self)
  }
}

struct LogActionsReducer<Base: Reducer>: Reducer where Base.State: Equatable {
  let base: Base

  private let logger = SupaLogger("TCA")

  func reduce(into state: inout Base.State, action: Base.Action) -> Effect<Base.Action> {
    let actionLabel = debugCaseOutput(action)
    logger.debug("Action: \(actionLabel)")
    #if DEBUG
      // Snapshot before/after by value so the diff can run off main.
      // Two copies of State per action sound costly, but State is a
      // value type and Swift's copy-on-write means the copies are
      // cheap-shallow until something else mutates the underlying
      // storage. The diff computation (CustomDump.diff) and the
      // Equatable comparison `previousState != state` were each
      // *significantly* expensive on main for boards with 19+
      // sessions — a `sample` capture during a 1.2 s freeze caught
      // `LogActionsReducer.reduce` at 137 main-thread samples per
      // stall, with the diff walk on top of the previous `print()`
      // cost.
      //
      // Now: capture both snapshots, reduce, then hand the pair to
      // SupaLogger's background queue. The diff/equality work
      // happens off-main; the action-dispatch path returns
      // instantly.
      let previousState = state
      let effects = base.reduce(into: &state, action: action)
      let nextState = state
      SupaLogger.dispatchStateDiff(previous: previousState, next: nextState)
      return effects
    #else
      SentrySDK.logger.info("Action: \(actionLabel)")
      let breadcrumb = Breadcrumb(level: .debug, category: "action")
      breadcrumb.message = actionLabel
      SentrySDK.addBreadcrumb(breadcrumb)
      return base.reduce(into: &state, action: action)
    #endif
  }
}

func debugCaseOutput(
  _ value: Any,
  abbreviated: Bool = false
) -> String {
  func debugCaseOutputHelp(_ value: Any) -> String {
    let mirror = Mirror(reflecting: value)
    switch mirror.displayStyle {
    case .enum:
      guard let child = mirror.children.first else {
        let childOutput = "\(value)"
        return childOutput == "\(typeName(type(of: value)))" ? "" : ".\(childOutput)"
      }
      let childOutput = debugCaseOutputHelp(child.value)
      return ".\(child.label ?? "")\(childOutput.isEmpty ? "" : "(\(childOutput))")"
    case .tuple:
      return mirror.children.map { label, value in
        let childOutput = debugCaseOutputHelp(value)
        let labelValue = label.map { isUnlabeledArgument($0) ? "_:" : "\($0):" } ?? ""
        let suffix = childOutput.isEmpty ? "" : " \(childOutput)"
        return "\(labelValue)\(suffix)"
      }
      .joined(separator: ", ")
    default:
      return ""
    }
  }

  return (value as? any CustomDebugStringConvertible)?.debugDescription
    ?? "\(abbreviated ? "" : typeName(type(of: value)))\(debugCaseOutputHelp(value))"
}

private func isUnlabeledArgument(_ label: String) -> Bool {
  label.firstIndex(where: { $0 != "." && !$0.isNumber }) == nil
}

// Pre-compiled regex constants used by `typeName`. A live `sample`
// capture during a 985 ms main-thread stall caught the previous
// inline `#/.../#` literals being parsed *per call* — Swift didn't
// constant-fold them, so every TCA action label triggered ~5 fresh
// `Regex.init → Parser.parse → parseCustomCharacterClass` walks
// through ICU's regex parser, totalling ~200 ms of main per stall.
// Pulling them to file-scope `let`s forces the compile cost to be
// paid exactly once per process.
private let unknownContextRegex = #/\(unknown context at \$[0-9A-Fa-f]+\)\./#
private let swiftOptionalRegex = #/\bSwift\.Optional<([^><]+)>/#
private let swiftArrayRegex = #/\bSwift\.Array<([^><]+)>/#
private let swiftDictionaryRegex = #/\bSwift\.Dictionary<([^,<]+), ([^><]+)>/#
private let qualifierStripRegex = #/\w+\.([\w.]+)/#
private let genericsStripRegex = #/<.+>/#

/// Cache of `typeName` results keyed by `ObjectIdentifier(type)`.
/// `typeName` is deterministic in its inputs (the `Any.Type`, plus
/// the two flags); the same TCA action enum will resolve to the same
/// label forever, so we cache once and re-use across every
/// invocation. With many actions per second this saves both the
/// `_typeName` runtime lookup and the regex substitution chain.
nonisolated private struct TypeNameCacheKey: Hashable, Sendable {
  let typeID: ObjectIdentifier
  let qualified: Bool
  let genericsAbbreviated: Bool
}
/// Class wrapper so the cache and its lock live on a single
/// nonisolated reference, sidestepping the Swift 6 @MainActor
/// default-isolation rules that block top-level mutable globals.
nonisolated final class TypeNameCache: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [TypeNameCacheKey: String] = [:]
  fileprivate func get(_ key: TypeNameCacheKey) -> String? {
    lock.lock(); defer { lock.unlock() }
    return storage[key]
  }
  fileprivate func set(_ key: TypeNameCacheKey, _ value: String) {
    lock.lock(); defer { lock.unlock() }
    storage[key] = value
  }
}
nonisolated private let typeNameCache = TypeNameCache()

private func typeName(
  _ type: Any.Type,
  qualified: Bool = true,
  genericsAbbreviated: Bool = true
) -> String {
  let cacheKey = TypeNameCacheKey(
    typeID: ObjectIdentifier(type),
    qualified: qualified,
    genericsAbbreviated: genericsAbbreviated
  )
  if let cached = typeNameCache.get(cacheKey) {
    return cached
  }

  var name = _typeName(type, qualified: qualified)
    .replacing(unknownContextRegex, with: "")
  for _ in 1...10 {
    let abbreviated =
      name
      .replacing(swiftOptionalRegex) { match in
        "\(match.1)?"
      }
      .replacing(swiftArrayRegex) { match in
        "[\(match.1)]"
      }
      .replacing(swiftDictionaryRegex) { match in
        "[\(match.1): \(match.2)]"
      }
    if abbreviated == name { break }
    name = abbreviated
  }
  name = name.replacing(qualifierStripRegex) { match in
    "\(match.1)"
  }
  if genericsAbbreviated {
    name = name.replacing(genericsStripRegex, with: "")
  }
  typeNameCache.set(cacheKey, name)
  return name
}
