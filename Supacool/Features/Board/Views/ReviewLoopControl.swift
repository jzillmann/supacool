import SwiftUI

/// Compact presentation and controls for a session's review loop.
///
/// The coordinator owns `ReviewLoopState` and all mutations. This view only
/// presents the current snapshot and invokes the supplied intents.
struct ReviewLoopControl: View {
  let state: ReviewLoopState?
  /// True when a loop can start, or start over on top of a finished /
  /// parked one. `startSubject` names the PRs it would read (`#42, #43`).
  let canStart: Bool
  var startSubject: String = ""
  let onStart: () -> Void
  let onOpenReviewer: () -> Void
  let onDiagnose: () -> Void
  let onChoose: (ReviewDecisionChoice) -> Void
  let onStop: () -> Void

  @State private var isPopoverPresented = false

  var body: some View {
    Group {
      if let state {
        activeControl(state)
      } else if canStart {
        startControl
      }
    }
  }

  private var startControl: some View {
    Button(action: onStart) {
      Image(systemName: "checkmark.shield")
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Start review loop")
    }
    .buttonStyle(.plain)
    .help(startHelp)
  }

  private var startHelp: String {
    startSubject.isEmpty ? "Start review loop" : "Start review loop on \(startSubject)"
  }

  private func activeControl(_ state: ReviewLoopState) -> some View {
    Button {
      isPopoverPresented.toggle()
    } label: {
      HStack(spacing: 4) {
        Image(systemName: phaseSystemImage(state))
          .font(.caption2)
          .accessibilityHidden(true)
        Text(compactLabel(state))
          .font(.caption2.weight(.semibold).monospacedDigit())
          .lineLimit(1)
      }
      .foregroundStyle(phaseColor(state))
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(phaseColor(state).opacity(0.12))
      .clipShape(Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Review loop, round \(state.round) of \(state.maximumRounds)")
    .help("Review loop: round \(state.round) of \(state.maximumRounds) — click for details")
    .popover(isPresented: $isPopoverPresented, arrowEdge: .top) {
      ReviewLoopPopover(
        state: state,
        restartSubject: canStart ? startSubject : nil,
        onStart: onStart,
        onOpenReviewer: onOpenReviewer,
        onDiagnose: onDiagnose,
        onChoose: onChoose,
        onStop: onStop
      )
    }
  }

  private func compactLabel(_ state: ReviewLoopState) -> String {
    switch state.phase {
    case .reviewing: "Review \(state.round)/\(state.maximumRounds)"
    case .fixing: "Fix \(state.round)/\(state.maximumRounds)"
    case .conferring: "Confer \(state.round)/\(state.maximumRounds)"
    case .diagnosing: "Diagnose"
    case .needsDecision: "Decision"
    case .passed: "Passed"
    case .stopped: "Stopped"
    }
  }

  private func phaseSystemImage(_ state: ReviewLoopState) -> String {
    switch state.phase {
    case .passed: return "checkmark.circle.fill"
    case .needsDecision, .stopped: return "exclamationmark.triangle.fill"
    case .fixing: return "wrench.and.screwdriver"
    case .conferring: return "bubble.left.and.bubble.right"
    case .reviewing, .diagnosing: return "arrow.triangle.2.circlepath"
    }
  }

  private func phaseColor(_ state: ReviewLoopState) -> Color {
    switch state.phase {
    case .passed: return .green
    case .needsDecision, .stopped: return .orange
    case .reviewing, .fixing, .conferring, .diagnosing: return .accentColor
    }
  }
}

private struct ReviewLoopPopover: View {
  let state: ReviewLoopState
  /// Non-nil when a fresh loop may replace this one; names its PRs.
  let restartSubject: String?
  let onStart: () -> Void
  let onOpenReviewer: () -> Void
  let onDiagnose: () -> Void
  let onChoose: (ReviewDecisionChoice) -> Void
  let onStop: () -> Void

  private var phaseLabel: String {
    switch state.phase {
    case .reviewing: "Reviewing"
    case .fixing: "Fixing"
    case .conferring: "Reviewer answering the agent"
    case .diagnosing: "Diagnosing"
    case .needsDecision: "Needs decision"
    case .passed: "Passed"
    case .stopped: "Stopped"
    }
  }

  private var shouldEscalate: Bool {
    state.phase == .needsDecision || state.convergenceWarning || state.round >= state.maximumRounds
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("Review loop", systemImage: "checkmark.shield")
          .font(.headline)
        Spacer()
        Text("R\(state.round)/\(state.maximumRounds)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      LabeledContent("Phase", value: phaseLabel)
      if state.pullRequestURLs.count > 1 {
        LabeledContent("Reviewing", value: state.pullRequestURLs.map(Self.pullRequestLabel).joined(separator: ", "))
      }
      if let lastReviewedSHA = state.lastReviewedSHA, !lastReviewedSHA.isEmpty {
        VStack(alignment: .leading, spacing: 3) {
          Text("Last commit")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(lastReviewedSHA)
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .lineLimit(1)
        }
      }
      if let lastSummary = state.lastSummary, !lastSummary.isEmpty {
        Text(lastSummary)
          .font(.callout)
          .foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let agentMessage = state.lastAgentMessage, !agentMessage.isEmpty {
        VStack(alignment: .leading, spacing: 3) {
          Text("Agent's last message")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(agentMessage)
            .font(.callout)
            .lineLimit(6)
            .fixedSize(horizontal: false, vertical: true)
            .help(agentMessage)
        }
      }
      if shouldEscalate {
        Label(
          state.escalationReason
            ?? (state.round >= state.maximumRounds
              ? "The review loop reached its round limit."
              : "Several rounds have not converged."),
          systemImage: "exclamationmark.triangle.fill"
        )
        .font(.callout)
        .foregroundStyle(.orange)
      }

      Divider()

      Button("Open reviewer", systemImage: "rectangle.split.2x1") {
        onOpenReviewer()
      }
      .help("Open the reviewer terminal")

      if shouldEscalate {
        Button("Diagnose architecture", systemImage: "magnifyingglass") {
          onDiagnose()
        }
        .help("Run one bounded pass to identify the root cause of non-convergence")
      }

      if state.phase == .needsDecision {
        ForEach(state.decisionChoices, id: \.self) { choice in
          Button(choice.title, systemImage: choice.systemImage) {
            onChoose(choice)
          }
          .help(choice.help)
        }
      } else if state.canAskReviewer {
        // Mid-round: the agent pushed back or asked something. No need to
        // wait for the loop to park before the reviewer hears it.
        Button(ReviewDecisionChoice.askReviewer.title, systemImage: ReviewDecisionChoice.askReviewer.systemImage) {
          onChoose(.askReviewer)
        }
        .help(ReviewDecisionChoice.askReviewer.help)
      }

      if let restartSubject {
        // A finished or parked loop is the end of one cycle, not of the
        // session: the next PR (or the same one, after a human fixed what
        // parked the loop) gets a fresh round 1 from here.
        Button(
          restartSubject.isEmpty ? "Start new review" : "Start new review on \(restartSubject)",
          systemImage: "arrow.counterclockwise"
        ) {
          onStart()
        }
        .help("Replace this loop with a fresh one, round 1, on every PR the session has open now")
      }

      if state.phase != .passed && state.phase != .stopped {
        Button("Stop review", systemImage: "stop.fill", role: .destructive) {
          onStop()
        }
        .help("Stop the review loop")
      }
    }
    .padding(16)
    .frame(width: 300, alignment: .leading)
  }

  /// `#42` from a PR URL, for the popover's PR list.
  private static func pullRequestLabel(_ url: String) -> String {
    url.split(separator: "/").last.map { "#\($0)" } ?? url
  }
}
