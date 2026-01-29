import SwiftUI

struct PullRequestStatusButton: View {
  let model: PullRequestStatusModel
  @Environment(\.openURL) private var openURL

  var body: some View {
    Button {
      if let url = model.url {
        openURL(url)
      }
    } label: {
      HStack(spacing: 6) {
        if let checkBreakdown = model.checkBreakdown {
          PullRequestBadgeView(
            text: model.badgeText,
            color: model.badgeColor
          )
          PullRequestChecksRingView(breakdown: checkBreakdown)
        } else {
          PullRequestBadgeView(
            text: model.badgeText,
            color: model.badgeColor
          )
        }
        if let detailText = model.detailText {
          Text(detailText)
        }
      }
      .font(.caption)
      .monospaced()
    }
    .buttonStyle(.plain)
    .help(model.helpText)
  }

}

struct PullRequestStatusModel: Equatable {
  let number: Int
  let state: String?
  let url: URL?
  let checkBreakdown: PullRequestCheckBreakdown?
  let detailText: String?

  init?(pullRequest: GithubPullRequest?) {
    guard
      let pullRequest,
      Self.shouldDisplay(state: pullRequest.state, number: pullRequest.number)
    else {
      return nil
    }
    self.number = pullRequest.number
    let state = pullRequest.state.uppercased()
    self.state = state
    self.url = URL(string: pullRequest.url)
    if state == "MERGED" {
      self.detailText = "Merged"
      self.checkBreakdown = nil
      return
    }
    let isDraft = pullRequest.isDraft
    let prefix = "\(isDraft ? "(Drafted) " : "")↗ - "
    let checks = pullRequest.statusCheckRollup?.checks ?? []
    if checks.isEmpty {
      self.detailText = prefix + "Checks unavailable"
      self.checkBreakdown = nil
      return
    }
    let breakdown = PullRequestCheckBreakdown(checks: checks)
    let checksLabel = breakdown.total == 1 ? "check" : "checks"
    var parts: [String] = []
    if breakdown.failed > 0 {
      parts.append("\(breakdown.failed) failed")
    }
    if breakdown.inProgress > 0 {
      parts.append("\(breakdown.inProgress) in progress")
    }
    if breakdown.skipped > 0 {
      parts.append("\(breakdown.skipped) skipped")
    }
    if breakdown.expected > 0 {
      parts.append("\(breakdown.expected) expected")
    }
    if breakdown.total > 0 {
      parts.append("\(breakdown.passed) successful")
    }
    self.detailText = prefix + parts.joined(separator: ", ") + " \(checksLabel)"
    self.checkBreakdown = breakdown
  }

  var badgeText: String {
    PullRequestBadgeStyle.style(state: state, number: number)?.text ?? "#\(number)"
  }

  var badgeColor: Color {
    PullRequestBadgeStyle.style(state: state, number: number)?.color ?? .secondary
  }

  var helpText: String {
    "Open pull request on GitHub"
  }

  static func shouldDisplay(state: String?, number: Int?) -> Bool {
    guard number != nil else {
      return false
    }
    return state?.uppercased() != "CLOSED"
  }
}
