import Foundation

private nonisolated let piSettingsInstallerLogger = SupaLogger("PiSettings")

/// Installs Supacool's Pi extension into Pi's global auto-discovery
/// directory. Pi loads `~/.pi/agent/extensions/*.ts` on startup, so no
/// settings.json mutation is required.
nonisolated struct PiSettingsInstaller {
  static let extensionFileName = "supacool-hooks.ts"

  let homeDirectoryURL: URL
  let fileManager: FileManager

  init(
    homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default
  ) {
    self.homeDirectoryURL = homeDirectoryURL
    self.fileManager = fileManager
  }

  func isInstalled() -> Bool {
    installState() == .current
  }

  func installState() -> AgentHookSettingsFileInstaller.InstallState {
    let url = extensionURL
    guard fileManager.fileExists(atPath: url.path) else { return .missing }
    do {
      let data = try Data(contentsOf: url)
      guard let source = String(data: data, encoding: .utf8) else { return .stale }
      return source == Self.extensionSource ? .current : .stale
    } catch {
      piSettingsInstallerLogger.warning("Failed to inspect Pi extension at \(url.path): \(error)")
      return .stale
    }
  }

  func install() throws {
    let url = extensionURL
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(Self.extensionSource.utf8).write(to: url, options: .atomic)
  }

  func uninstall() throws {
    let url = extensionURL
    guard fileManager.fileExists(atPath: url.path) else { return }
    try fileManager.removeItem(at: url)
  }

  private var extensionURL: URL {
    Self.extensionURL(homeDirectoryURL: homeDirectoryURL)
  }

  static func extensionURL(homeDirectoryURL: URL) -> URL {
    homeDirectoryURL
      .appendingPathComponent(".pi", isDirectory: true)
      .appendingPathComponent("agent", isDirectory: true)
      .appendingPathComponent("extensions", isDirectory: true)
      .appendingPathComponent(extensionFileName, isDirectory: false)
  }

  /// TypeScript source for the Pi extension. Keep this npm-dependency-free:
  /// global Pi extensions are loaded directly by Pi via jiti.
  static let extensionSource = #"""
    import { createConnection } from "node:net";

    const IDLE_DEBOUNCE_MS = 500;
    const SOCKET_TIMEOUT_MS = 1000;
    const AGENT_NAME = "pi";

    let busy = false;
    let idleTimer = undefined;

    function supacoolEnv() {
      const socketPath = process.env.SUPACOOL_SOCKET_PATH;
      const worktreeID = process.env.SUPACOOL_WORKTREE_ID;
      const tabID = process.env.SUPACOOL_TAB_ID;
      const surfaceID = process.env.SUPACOOL_SURFACE_ID;
      if (!socketPath || !worktreeID || !tabID || !surfaceID) return undefined;
      return { socketPath, worktreeID, tabID, surfaceID };
    }

    function sendToSupacool(payload) {
      const env = supacoolEnv();
      if (!env) return;

      const socket = createConnection(env.socketPath);
      socket.setTimeout(SOCKET_TIMEOUT_MS);
      socket.on("error", () => {});
      socket.on("timeout", () => socket.destroy());
      socket.end(payload);
    }

    function header() {
      const env = supacoolEnv();
      if (!env) return undefined;
      return `${env.worktreeID} ${env.tabID} ${env.surfaceID}`;
    }

    function clearIdleTimer() {
      if (idleTimer !== undefined) clearTimeout(idleTimer);
      idleTimer = undefined;
    }

    function sendBusy(active, force = false) {
      if (!force && busy === active) return;
      busy = active;

      const baseHeader = header();
      if (!baseHeader) return;
      sendToSupacool(`${baseHeader} ${active ? "1" : "0"} ${process.pid}\n`);
    }

    function sendSessionID(ctx, eventName) {
      const baseHeader = header();
      if (!baseHeader) return;

      let sessionID;
      try {
        sessionID = ctx.sessionManager.getSessionId();
      } catch {
        return;
      }
      if (!sessionID) return;

      const payload = {
        hook_event_name: eventName,
        title: "",
        message: "",
        session_id: sessionID,
      };
      sendToSupacool(`${baseHeader} ${AGENT_NAME}\n${JSON.stringify(payload)}\n`);
    }

    export default function (pi) {
      pi.on("session_start", async (_event, ctx) => {
        sendSessionID(ctx, "SessionStart");
      });

      pi.on("agent_start", async (_event, ctx) => {
        clearIdleTimer();
        sendSessionID(ctx, "AgentStart");
        sendBusy(true);
      });

      pi.on("agent_end", async () => {
        clearIdleTimer();
        idleTimer = setTimeout(() => {
          idleTimer = undefined;
          sendBusy(false);
        }, IDLE_DEBOUNCE_MS);
      });

      pi.on("session_shutdown", async () => {
        clearIdleTimer();
        sendBusy(false, true);
      });
    }
    """#
}
