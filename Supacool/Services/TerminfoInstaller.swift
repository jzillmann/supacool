import Foundation

private nonisolated let terminfoInstallerLogger = SupaLogger("Supacool.TerminfoInstaller")

/// Installs the bundled `xterm-ghostty` (and `ghostty`) terminfo entries into
/// `~/.terminfo` so spawned shells can render the line editor correctly.
///
/// **Why this exists:** Ghostty configures `TERM=xterm-ghostty` for spawned
/// PTYs and tries to set `TERMINFO=<bundle>/Contents/Resources/terminfo` to
/// match. That env-passing path is fragile in practice — anything in the
/// launchd session can leak its own `TERMINFO` (a co-installed ghostty fork
/// like cmux.app does this), `/usr/bin/login` whitelists are platform-
/// dependent, and shell startup files can `unset` it. When the override
/// fails, ncurses can't resolve `xterm-ghostty` and zsh's ZLE produces
/// scrambled redraws (`tput: unknown terminal "xterm-ghostty"` followed by
/// duplicated keystrokes on the prompt).
///
/// `~/.terminfo` is always part of ncurses' default lookup path regardless
/// of `TERMINFO` state, so populating it here gives the user shell a
/// guaranteed source of truth. Stock Ghostty.app accomplishes the same
/// thing via its installer; this is the equivalent for our embedded build.
@MainActor
enum TerminfoInstaller {
  private static let entries: [String] = [
    // Hashed-prefix layout that ncurses uses on macOS.
    // `78` = 'x', `67` = 'g'. Both directories are written by `tic` from
    // `ghostty.terminfo`.
    "78/xterm-ghostty",
    "67/ghostty",
  ]

  static func installIfNeeded() {
    guard
      let bundleTerminfo = Bundle.main.resourceURL?.appendingPathComponent("terminfo")
    else {
      terminfoInstallerLogger.warning("App bundle has no terminfo directory; skipping install")
      return
    }
    let userTerminfo = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".terminfo")

    var installed = 0
    for entry in entries {
      let src = bundleTerminfo.appendingPathComponent(entry)
      let dst = userTerminfo.appendingPathComponent(entry)
      do {
        guard try shouldCopy(src: src, dst: dst) else { continue }
        try install(src: src, dst: dst)
        installed += 1
      } catch {
        terminfoInstallerLogger.warning(
          "Failed to install terminfo entry \(entry): \(error.localizedDescription)"
        )
      }
    }
    if installed > 0 {
      terminfoInstallerLogger.info(
        "Installed \(installed) terminfo entry/entries into \(userTerminfo.path)"
      )
    }
  }

  private static func shouldCopy(src: URL, dst: URL) throws -> Bool {
    let fm = FileManager.default
    guard fm.fileExists(atPath: src.path) else { return false }
    guard fm.fileExists(atPath: dst.path) else { return true }
    let srcMtime = try fm.attributesOfItem(atPath: src.path)[.modificationDate] as? Date
    let dstMtime = try fm.attributesOfItem(atPath: dst.path)[.modificationDate] as? Date
    guard let srcMtime, let dstMtime else { return true }
    return srcMtime > dstMtime
  }

  private static func install(src: URL, dst: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(
      at: dst.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    if fm.fileExists(atPath: dst.path) {
      try fm.removeItem(at: dst)
    }
    try fm.copyItem(at: src, to: dst)
  }
}
