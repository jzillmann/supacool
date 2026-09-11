import ComposableArchitecture
import SwiftUI

/// Non-modal stack of parked review decisions, floating bottom-trailing over
/// both the board and the full-screen terminal.
///
/// Replaces the old app-modal alert: an escalation never blocks the window or
/// interrupts typing, and one decision can no longer overwrite another. The
/// stack reads `pendingReviewDecisions`, which derives from the persisted loop
/// phase — so every parked decision is here, and still here after a relaunch.
/// The top card is one decision; the layers behind it say more are waiting.
struct ReviewDecisionStackView: View {
  @Bindable var store: StoreOf<BoardFeature>
  /// Space below the stack. Zero when tray cards sit underneath it.
  var bottomInset: CGFloat = 16

  @State private var selectedID: AgentSession.ID?
  @State private var isCollapsed = false

  var body: some View {
    let decisions = store.pendingReviewDecisions
    let decisionIDs = decisions.map(\.id)
    // A container rather than a Group, so `onChange` stays installed while the
    // stack is empty and the first decision can still expand it.
    VStack(alignment: .trailing, spacing: 0) {
      if let current = decisions.first(where: { $0.id == selectedID }) ?? decisions.first,
        let loop = current.reviewLoop
      {
        Group {
          if isCollapsed {
            collapsedPill(count: decisions.count)
          } else {
            ReviewDecisionCard(
              session: current,
              loop: loop,
              position: (decisionIDs.firstIndex(of: current.id) ?? 0) + 1,
              count: decisions.count,
              onStep: { offset in step(offset, from: current.id, in: decisionIDs) },
              onCollapse: { isCollapsed = true },
              onOpen: { store.send(.focusSession(id: current.id)) },
              onInspect: { store.send(.openReviewLoopReviewer(id: current.id)) },
              onChoose: { choice in store.send(.reviewDecision(choice, sessionID: current.id)) },
              onDiagnose: { store.send(.diagnoseReviewLoop(id: current.id)) },
              onStop: { store.send(.stopReviewLoop(id: current.id)) },
              onLater: { store.send(.snoozeReviewDecision(id: current.id)) }
            )
            .background(alignment: .top) { stackLayers(count: decisions.count) }
          }
        }
        .padding(.trailing, 16)
        .padding(.bottom, bottomInset)
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .onChange(of: decisionIDs) { oldIDs, newIDs in
      // A new escalation brings itself to the front, even if the user
      // collapsed the stack for an earlier one.
      if let newest = newIDs.first(where: { !oldIDs.contains($0) }) {
        selectedID = newest
        isCollapsed = false
      }
    }
    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: decisionIDs)
  }

  private func step(_ offset: Int, from id: AgentSession.ID, in ids: [AgentSession.ID]) {
    guard let index = ids.firstIndex(of: id), !ids.isEmpty else { return }
    selectedID = ids[(index + offset + ids.count) % ids.count]
  }

  private func collapsedPill(count: Int) -> some View {
    Button {
      isCollapsed = false
    } label: {
      Label(
        count == 1 ? "1 review decision" : "\(count) review decisions",
        systemImage: "exclamationmark.triangle.fill"
      )
      .font(.callout.weight(.medium))
      .foregroundStyle(.orange)
      .padding(.horizontal, 12)
      .padding(.vertical, 7)
      .background(.regularMaterial, in: Capsule())
      .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
      .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
    }
    .buttonStyle(.plain)
    .help("Show pending review decisions")
  }

  /// Up to two card edges peeking out above the top card.
  private func stackLayers(count: Int) -> some View {
    let depth = min(count - 1, 2)
    return ZStack(alignment: .top) {
      ForEach((0..<max(depth, 0)).reversed(), id: \.self) { index in
        let level = CGFloat(index + 1)
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(.regularMaterial)
          .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
          )
          .scaleEffect(x: 1 - 0.05 * level, y: 1, anchor: .top)
          .offset(y: -7 * level)
      }
    }
  }
}

private struct ReviewDecisionCard: View {
  let session: AgentSession
  let loop: ReviewLoopState
  let position: Int
  let count: Int
  let onStep: (Int) -> Void
  let onCollapse: () -> Void
  let onOpen: () -> Void
  let onInspect: () -> Void
  let onChoose: (ReviewDecisionChoice) -> Void
  let onDiagnose: () -> Void
  let onStop: () -> Void
  let onLater: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      header

      Button(action: onOpen) {
        Text(session.displayName)
          .font(.headline)
          .foregroundStyle(.primary)
          .lineLimit(2)
          .multilineTextAlignment(.leading)
      }
      .buttonStyle(.plain)
      .help("Open this session")

      if let reason = loop.escalationReason, !reason.isEmpty {
        Text(reason)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(4)
          .fixedSize(horizontal: false, vertical: true)
          .help(reason)
      }

      actions
    }
    .padding(12)
    .frame(width: 360, alignment: .leading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
  }

  private var header: some View {
    HStack(spacing: 6) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.caption)
        .foregroundStyle(.orange)
        .accessibilityHidden(true)
      Text("Review decision · R\(loop.round)/\(loop.maximumRounds)")
        .font(.caption.weight(.semibold).monospacedDigit())
        .foregroundStyle(.secondary)
      Spacer()
      if count > 1 {
        iconButton("chevron.left", label: "Previous decision") { onStep(-1) }
        Text("\(position)/\(count)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        iconButton("chevron.right", label: "Next decision") { onStep(1) }
      }
      iconButton("chevron.down", label: "Collapse the decision stack", action: onCollapse)
    }
  }

  private var actions: some View {
    let choices = loop.decisionChoices
    return HStack(spacing: 6) {
      if let primary = choices.first {
        Button(primary.title) { onChoose(primary) }
          .buttonStyle(.borderedProminent)
          .help(primary.help)
      }
      Button("Inspect", action: onInspect)
        .help("Open the session with the reviewer terminal active — the decision stays here")
      Menu("More") {
        ForEach(choices.dropFirst(), id: \.self) { choice in
          Button(choice.title, systemImage: choice.systemImage) { onChoose(choice) }
            .help(choice.help)
        }
        Button("Diagnose architecture", systemImage: "magnifyingglass", action: onDiagnose)
          .help("Run one bounded pass to identify the root cause of non-convergence")
        Divider()
        Button("Stop review", systemImage: "stop.fill", role: .destructive, action: onStop)
          .help("Stop the review loop")
      }
      .fixedSize()
      .help("More ways to answer this decision")
      Spacer(minLength: 0)
      Button("Later", action: onLater)
        .buttonStyle(.borderless)
        .help("Hide this decision until the loop asks again")
    }
    .controlSize(.small)
  }

  private func iconButton(
    _ systemName: String,
    label: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(3)
        .contentShape(Rectangle())
        .accessibilityLabel(label)
    }
    .buttonStyle(.plain)
    .help(label)
  }
}

extension ReviewDecisionChoice {
  var title: String {
    switch self {
    case .resumeRound: "Continue round"
    case .resendFindings: "Send findings again"
    case .sendFindings(let rounds) where rounds > 1: "Send findings, then \(rounds) more rounds"
    case .sendFindings: "Send findings to agent"
    case .rereview(let rounds) where rounds > 1: "Re-review, then \(rounds) more rounds"
    case .rereview: "Re-review"
    }
  }

  var systemImage: String {
    switch self {
    case .resumeRound: "play.fill"
    case .resendFindings: "arrow.uturn.right"
    case .sendFindings(let rounds), .rereview(let rounds):
      rounds > 1 ? "forward.end.fill" : "forward.fill"
    }
  }

  var help: String {
    switch self {
    case .resumeRound:
      "Keep this round open: review the new commit if the agent made one, otherwise ask the agent to finish"
    case .resendFindings:
      "Hand the same findings to the agent again"
    case .sendFindings(let rounds) where rounds > 1:
      "Hand the findings to the agent, and let the loop run \(rounds) more rounds before it asks again"
    case .sendFindings:
      "Hand the reviewer's findings to the implementation agent, then ask again after one round"
    case .rereview(let rounds) where rounds > 1:
      "Review again, and let the loop run \(rounds) more rounds before it asks again"
    case .rereview:
      "Allow exactly one more review round"
    }
  }
}
