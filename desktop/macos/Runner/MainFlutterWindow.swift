import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.minSize = NSSize(width: 560, height: 420)
    self.setFrameAutosaveName("MeetingNotesMain")
    // For checking layouts: MEETING_NOTES_WINDOW=900x700 opens the window at that size.
    if let want = ProcessInfo.processInfo.environment["MEETING_NOTES_WINDOW"] {
      let n = want.split(separator: "x").compactMap { Double($0) }
      if n.count == 2 {
        self.setFrame(NSRect(x: 80, y: 80, width: n[0], height: n[1]), display: true)
      }
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    // The player's Full screen button: put this window in or out of macOS full screen.
    // Answers true when it changed something, so the app only undoes what it did.
    let channel = FlutterMethodChannel(
      name: "meeting_notes/window", binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self, call.method == "fullScreen", let want = call.arguments as? Bool else {
        result(FlutterMethodNotImplemented)
        return
      }
      if self.styleMask.contains(.fullScreen) != want {
        self.toggleFullScreen(nil)
        result(true)
      } else {
        result(false)
      }
    }

    super.awakeFromNib()
  }
}
