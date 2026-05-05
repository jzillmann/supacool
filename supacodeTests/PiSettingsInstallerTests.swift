import Foundation
import Testing

@testable import Supacool

struct PiSettingsInstallerTests {
  private let fileManager = FileManager.default

  private func makeTempHomeURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("supacode-pi-installer-\(UUID().uuidString)", isDirectory: true)
  }

  @Test func installWritesAutoDiscoveredExtension() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = PiSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)

    try installer.install()

    let url = PiSettingsInstaller.extensionURL(homeDirectoryURL: homeURL)
    let source = try String(contentsOf: url, encoding: .utf8)
    #expect(source == PiSettingsInstaller.extensionSource)
    #expect(installer.isInstalled())
    #expect(installer.installState() == .current)
  }

  @Test func extensionMarksPiCompactionAsBusy() {
    let source = PiSettingsInstaller.extensionSource

    #expect(source.contains("pi.on(\"session_before_compact\""))
    #expect(source.contains("pi.on(\"session_compact\""))
    #expect(source.contains("sendSessionID(ctx, \"CompactionStart\")"))
    #expect(source.contains("sendSessionID(ctx, \"CompactionEnd\")"))
    #expect(source.contains("setBusyReason(\"compaction\", true)"))
    #expect(source.contains("setBusyReason(\"compaction\", false)"))
    #expect(source.contains("event.signal.addEventListener"))
    #expect(source.contains("COMPACTION_FALLBACK_MS"))
  }

  @Test func extensionKeepsIndependentBusyReasonsFromClearingEachOther() {
    let source = PiSettingsInstaller.extensionSource

    #expect(source.contains("const busyReasons = new Set();"))
    #expect(source.contains("const active = busyReasons.size > 0;"))
    #expect(source.contains("busyReasons.add(reason);"))
    #expect(source.contains("busyReasons.delete(reason);"))
    #expect(source.contains("setBusyReason(\"agent\", true)"))
    #expect(source.contains("setBusyReason(\"agent\", false)"))
    #expect(source.contains("busyReasons.clear();"))
  }

  @Test func staleWhenExistingExtensionDiffers() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let url = PiSettingsInstaller.extensionURL(homeDirectoryURL: homeURL)
    try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "old".write(to: url, atomically: true, encoding: .utf8)

    let installer = PiSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)

    #expect(installer.installState() == .stale)
    #expect(!installer.isInstalled())
  }

  @Test func uninstallRemovesExtension() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = PiSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)

    try installer.install()
    try installer.uninstall()

    let url = PiSettingsInstaller.extensionURL(homeDirectoryURL: homeURL)
    #expect(!fileManager.fileExists(atPath: url.path))
    #expect(installer.installState() == .missing)
  }
}
