import AppKit
import WakeMeUpCore

let app = NSApplication.shared
let delegate = AppDelegate.shared
app.delegate = delegate

_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
