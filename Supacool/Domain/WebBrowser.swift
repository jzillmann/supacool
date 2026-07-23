import AppKit
import ComposableArchitecture
import Foundation
import SwiftUI

/// A web browser installed on this Mac that can open `https` links, plus the
/// routing that honors the user's "Open Links In" preference.
///
/// The preference lives in `GlobalSettings.preferredBrowserBundleID`
/// (`nil` = the system default handler). Every app web-link open funnels
/// through `open(_:)` — either directly (call sites that used
/// `NSWorkspace.shared.open`) or via the `OpenURLAction.preferredBrowser`
/// environment override installed at the app root — so PR links,
/// server-endpoint chips, and Linear links all land in the same browser.
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

  /// Opens `url` in the user's preferred browser, falling back to the system
  /// default handler when no preference is set or the chosen browser is gone.
  static func open(_ url: URL) {
    @Shared(.settingsFile) var settingsFile
    guard let preferred = settingsFile.global.preferredBrowserBundleID,
      let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: preferred)
    else {
      NSWorkspace.shared.open(url)
      return
    }
    NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
  }
}

extension OpenURLAction {
  /// Routes `http`/`https` links through the user's preferred browser and lets
  /// the system handle every other scheme (`mailto:`, `linear:`, `x-apple:`, …).
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
