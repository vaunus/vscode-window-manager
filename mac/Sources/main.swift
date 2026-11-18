import AppKit
import ServiceManagement

// uninstall.sh runs this before it deletes the app.
if CommandLine.arguments.contains("--remove-login-item") {
    try? SMAppService.mainApp.unregister()
    exit(0)
}

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    let app = NSApplication.shared
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
