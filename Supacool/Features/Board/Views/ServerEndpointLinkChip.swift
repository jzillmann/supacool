import SwiftUI

/// The clickable `:3606` that sits next to a server lifecycle chip.
///
/// A script reporting a whole fleet of ports gets a menu rather than a link:
/// `ServerEndpointScanner` deliberately declines to guess which of five
/// unremarkable ports a human meant, and this is where that shows up.
struct ServerEndpointLinkChip: View {
  let endpoints: [ServerEndpoint]

  @Environment(\.openURL) private var openURL

  @ViewBuilder
  var body: some View {
    if let primary = ServerEndpointScanner.primary(of: endpoints), let url = primary.url {
      Button {
        openURL(url)
      } label: {
        chipLabel(primary.label)
      }
      .buttonStyle(.plain)
      .contextMenu { endpointMenuItems }
      .help(primaryHelp(for: primary))
    } else if endpoints.count > 1 {
      Menu {
        endpointMenuItems
      } label: {
        chipLabel("\(endpoints.count) ports")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Ports this workspace's server reported. Pick one to open it.")
    }
  }

  @ViewBuilder
  private var endpointMenuItems: some View {
    ForEach(endpoints) { endpoint in
      if let url = endpoint.url {
        Button {
          openURL(url)
        } label: {
          Text(verbatim: url.absoluteString)
        }
      }
    }
  }

  private func chipLabel(_ text: String) -> some View {
    HStack(spacing: 3) {
      Image(systemName: "arrow.up.forward.square")
        .accessibilityHidden(true)
      Text(text)
        // Same pin as the vitals counts: inside a compressed toolbar a short
        // numeric Text resolves at an ideal width that wraps mid-number.
        .lineLimit(1)
        .fixedSize()
    }
    .font(.caption2.weight(.semibold))
    .foregroundStyle(Color.accentColor)
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(Color.accentColor.opacity(0.12))
    .clipShape(Capsule())
  }

  private func primaryHelp(for primary: ServerEndpoint) -> String {
    guard let url = primary.url else { return "Open this workspace's server." }
    var lines = ["Open \(url.absoluteString)"]
    if endpoints.count > 1 {
      let others = endpoints.filter { $0 != primary }.map(\.label).joined(separator: ", ")
      lines.append("Also listening: \(others). Right-click for all.")
    }
    return lines.joined(separator: "\n")
  }
}
