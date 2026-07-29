import Sharing
import SwiftUI

/// Drives the embedded MCP server from the persisted remote-control settings:
/// starts it on launch when enabled, stops it on toggle-off, restarts it on a
/// port change. Same pattern as `GhosttyColorSchemeSyncView`.
struct MCPControlServerSyncView<Content: View>: View {
  @Shared(.settingsFile) private var settingsFile
  let server: MCPControlServer
  let content: Content

  init(server: MCPControlServer, @ViewBuilder content: () -> Content) {
    self.server = server
    self.content = content()
  }

  var body: some View {
    content
      .task {
        await apply()
      }
      .onChange(of: settingsFile.global.remoteControlServerEnabled) {
        Task { await apply() }
      }
      .onChange(of: settingsFile.global.remoteControlServerPort) {
        Task { await apply() }
      }
  }

  private func apply() async {
    let global = settingsFile.global
    guard global.remoteControlServerEnabled else {
      if server.status != .stopped {
        await server.stop()
      }
      return
    }
    let port = UInt16(clamping: global.remoteControlServerPort)
    if case .running(let current) = server.status, current == port {
      return
    }
    await server.stop()
    await server.start(port: port)
  }
}
