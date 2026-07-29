import Foundation
import Testing

@testable import Supacool

/// The "Open Links In" / "Open Server Links In" split: which browser a given
/// link resolves to, and how a URL classifies when no call site says.
struct WebLinkRoutingTests {
  private func settings(
    general: String? = nil,
    localServer: BrowserChoice? = nil
  ) -> GlobalSettings {
    var settings = GlobalSettings.default
    settings.preferredBrowserBundleID = general
    settings.localServerBrowser = localServer
    return settings
  }

  @Test func defaultsBothKindsToTheSystemHandler() {
    let settings = settings()
    #expect(settings.browser(for: .general) == .systemDefault)
    #expect(settings.browser(for: .localServer) == .systemDefault)
  }

  /// Upgrade behaviour for anyone who set a browser before the split existed:
  /// server links keep following the one preference they configured.
  @Test func serverLinksInheritTheGeneralBrowserWhenUnset() {
    let settings = settings(general: "com.apple.Safari")
    #expect(settings.browser(for: .localServer) == .app(bundleID: "com.apple.Safari"))
  }

  @Test func serverLinksOverrideTheGeneralBrowser() {
    let settings = settings(general: "com.apple.Safari", localServer: .app(bundleID: "com.google.Chrome"))
    #expect(settings.browser(for: .general) == .app(bundleID: "com.apple.Safari"))
    #expect(settings.browser(for: .localServer) == .app(bundleID: "com.google.Chrome"))
  }

  /// `.systemDefault` is a real choice, not "unset" — it has to beat a general
  /// preference rather than inherit it.
  @Test func serverLinksCanPinBackToTheSystemHandler() {
    let settings = settings(general: "com.google.Chrome", localServer: .systemDefault)
    #expect(settings.browser(for: .localServer) == .systemDefault)
  }

  @Test(arguments: [
    "http://localhost:3606",
    "http://127.0.0.1:8080/app",
    "http://0.0.0.0:5173",
    "http://mac-studio.local:3000",
    "https://app.localhost:4200",
  ])
  func classifiesLocalHostsAsServerLinks(urlString: String) throws {
    let url = try #require(URL(string: urlString))
    #expect(WebLinkKind(url: url) == .localServer)
  }

  @Test(arguments: [
    "https://github.com/jzillmann/supacool/pull/21",
    "https://linear.app/centrum/issue/CEN-123",
    "https://localhost.example.com/not-local",
  ])
  func classifiesEverythingElseAsGeneral(urlString: String) throws {
    let url = try #require(URL(string: urlString))
    #expect(WebLinkKind(url: url) == .general)
  }

  @Test func encodesBrowserChoiceAsOneReadableString() throws {
    let encoded = try JSONEncoder().encode(
      [BrowserChoice.systemDefault, .app(bundleID: "com.google.Chrome")]
    )
    #expect(String(bytes: encoded, encoding: .utf8) == #"["system-default","bundle:com.google.Chrome"]"#)
    #expect(
      try JSONDecoder().decode([BrowserChoice].self, from: encoded)
        == [.systemDefault, .app(bundleID: "com.google.Chrome")]
    )
  }

  /// Forward compatibility: a token written by a future version decodes to the
  /// system default instead of throwing away the whole settings file.
  @Test func decodesUnknownBrowserChoiceTokenAsSystemDefault() throws {
    let data = Data(#"["something-new"]"#.utf8)
    #expect(try JSONDecoder().decode([BrowserChoice].self, from: data) == [.systemDefault])
  }
}
