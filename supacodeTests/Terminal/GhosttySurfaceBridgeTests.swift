import GhosttyKit
import Testing

@testable import Supacool

@MainActor
struct GhosttySurfaceBridgeTests {
  @Test func safeDropReachesTheInputTapOnceGhosttyPastesIt() {
    let bridge = GhosttySurfaceBridge()
    var tapped: [String] = []
    bridge.onInputTap = { tapped.append($0) }
    var pasted: [String] = []

    bridge.pasteDroppedText("ls -la") { pasted.append($0) }

    #expect(pasted == ["ls -la"])
    #expect(tapped == ["ls -la"])
    #expect(bridge.takePendingDropPaste() == nil)
  }

  @Test func unsafeDropWaitsForConfirmationBeforeTheInputTap() {
    let bridge = GhosttySurfaceBridge()
    var tapped: [String] = []
    bridge.onInputTap = { tapped.append($0) }
    var claimed: String?

    // ghostty requests confirmation from inside paste_text; the runtime claims the drop.
    bridge.pasteDroppedText("rm -rf x\n") { _ in claimed = bridge.takePendingDropPaste() }

    #expect(claimed == "rm -rf x\n")
    #expect(tapped.isEmpty)
  }

  @Test func onlyUnsafePastesAskTheUser() {
    #expect(GhosttyRuntime.asksUserToConfirm(GHOSTTY_CLIPBOARD_REQUEST_PASTE))
    #expect(!GhosttyRuntime.asksUserToConfirm(GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ))
    #expect(!GhosttyRuntime.asksUserToConfirm(GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE))
    #expect(!GhosttyRuntime.asksUserToConfirm(GHOSTTY_CLIPBOARD_REQUEST_KITTY_READ))
  }

  @Test func desktopNotificationEmitsCallback() {
    let bridge = GhosttySurfaceBridge()
    var received: (String, String)?
    bridge.onDesktopNotification = { title, body in
      received = (title, body)
    }

    var action = ghostty_action_s()
    action.tag = GHOSTTY_ACTION_DESKTOP_NOTIFICATION
    let target = ghostty_target_s()

    "Title".withCString { titlePtr in
      "Body".withCString { bodyPtr in
        action.action.desktop_notification = ghostty_action_desktop_notification_s(
          title: titlePtr,
          body: bodyPtr
        )
        _ = bridge.handleAction(target: target, action: action)
      }
    }

    #expect(received?.0 == "Title")
    #expect(received?.1 == "Body")
  }
}
