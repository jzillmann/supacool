import AppKit
import ComposableArchitecture
import Foundation
import SwiftUI

/// A browser the user picked for one class of link. Persisted inside
/// `GlobalSettings`; an *optional* `BrowserChoice` uses `nil` for "inherit
/// whatever the general preference is" — see `GlobalSettings.browser(for:)`.
nonisolated enum BrowserChoice: Codable, Hashable, Sendable {
  /// Whatever LaunchServices hands `https` to.
  case systemDefault
  /// A specific app, e.g. `com.google.Chrome`.
  case app(bundleID: String)

  var bundleID: String? {
    guard case .app(let bundleID) = self else { return nil }
    return bundleID
  }

  // Encoded as one string rather than a keyed object so the settings file stays
  // readable. The `bundle:` prefix keeps a bundle id from ever colliding with
  // the system-default token, and an unrecognized token decodes as the system
  // default instead of throwing — the forward-compat rule every persisted type
  // here follows.
  private static let systemDefaultToken = "system-default"
  private static let appPrefix = "bundle:"

  init(from decoder: any Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    guard raw.hasPrefix(Self.appPrefix) else {
      self = .systemDefault
      return
    }
    self = .app(bundleID: String(raw.dropFirst(Self.appPrefix.count)))
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .systemDefault:
      try container.encode(Self.systemDefaultToken)
    case .app(let bundleID):
      try container.encode(Self.appPrefix + bundleID)
    }
  }
}

/// The classes of web link Supacool opens, each routable to its own browser.
///
/// The split exists because the two are read in different tools: tickets and
/// pull requests belong with the rest of your logged-in work browsing, while
/// the thing a session is *building* wants the browser you debug in.
nonisolated enum WebLinkKind: Hashable, Sendable, CaseIterable {
  /// Pull requests, Linear tickets, docs — everything that isn't a dev server.
  case general
  /// A workspace's own server: the card's endpoint chip, plus any
  /// `localhost`-family URL no matter where it was clicked.
  case localServer

  /// Hosts that mean "the app this session is running". Callers that already
  /// know they hold a server URL (the endpoint chip) pass `.localServer`
  /// explicitly — a lifecycle script is free to report a non-local host.
  private static let localHosts: Set<String> = ["localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]"]

  init(url: URL) {
    let host = url.host()?.lowercased() ?? ""
    let isLocal =
      Self.localHosts.contains(host) || host.hasSuffix(".local") || host.hasSuffix(".localhost")
    self = isLocal ? .localServer : .general
  }
}

extension GlobalSettings {
  /// The browser `kind` should open in, resolving `localServerBrowser`'s
  /// "inherit" case against the general preference.
  func browser(for kind: WebLinkKind) -> BrowserChoice {
    let general = preferredBrowserBundleID.map { BrowserChoice.app(bundleID: $0) } ?? .systemDefault
    switch kind {
    case .general: return general
    case .localServer: return localServerBrowser ?? general
    }
  }
}

/// A web browser installed on this Mac that can open `https` links, plus the
/// routing that honors the user's "Open Links In" preferences.
///
/// The preferences live in `GlobalSettings.preferredBrowserBundleID` (general
/// links; `nil` = the system default handler) and
/// `GlobalSettings.localServerBrowser` (dev-server links; `nil` = follow the
/// general one). Every app web-link open funnels through `open(_:kind:)` —
/// either directly (call sites that used `NSWorkspace.shared.open`) or via the
/// `OpenURLAction.preferredBrowser` environment override installed at the app
/// root — so PR links, server-endpoint chips, and Linear links all route
/// through the same rules.
@MainActor
struct WebBrowser: Identifiable, Equatable, Sendable {
  /// The app's bundle identifier, e.g. `com.google.Chrome`. Doubles as `id`.
  let bundleID: String
  /// Human-readable name for the Settings picker, e.g. "Google Chrome".
  let name: String

  var id: String { bundleID }

  /// A representative https URL used to probe LaunchServices for browsers.
  private static let probe = URL(string: "https://example.com")!

  /// Every app registered to open `https` URLs, sorted by name. Deduped by
  /// bundle id (LaunchServices can list the same app under several URLs).
  static var installed: [WebBrowser] {
    var seen = Set<String>()
    let browsers = NSWorkspace.shared.urlsForApplications(toOpen: probe).compactMap {
      appURL -> WebBrowser? in
      guard let bundleID = Bundle(url: appURL)?.bundleIdentifier, seen.insert(bundleID).inserted
      else { return nil }
      let name = FileManager.default.displayName(atPath: appURL.path).replacing(".app", with: "")
      return WebBrowser(bundleID: bundleID, name: name)
    }
    return browsers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  /// Opens `url` in the browser the user picked for `kind`, falling back to the
  /// system default handler when no preference is set or the chosen browser is
  /// gone. `kind` defaults to classifying the URL by host, so a `localhost`
  /// link lands in the dev browser wherever it was clicked.
  static func open(_ url: URL, kind: WebLinkKind? = nil) {
    @Shared(.settingsFile) var settingsFile
    let choice = settingsFile.global.browser(for: kind ?? WebLinkKind(url: url))
    guard let preferred = choice.bundleID,
      let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: preferred)
    else {
      NSWorkspace.shared.open(url)
      return
    }
    NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
  }
}

extension OpenURLAction {
  /// Routes `http`/`https` links through the preferred browser for their
  /// `WebLinkKind` and lets the system handle every other scheme (`mailto:`,
  /// `linear:`, `x-apple:`, …).
  /// Installed at the app root so `@Environment(\.openURL)` call sites — the
  /// server-endpoint chip, PR check popovers — honor the preference for free.
  static var preferredBrowser: OpenURLAction {
    OpenURLAction { url in
      guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
        return .systemAction
      }
      WebBrowser.open(url)
      return .handled
    }
  }
}
