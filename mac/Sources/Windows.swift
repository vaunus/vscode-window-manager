import AppKit
import ApplicationServices

// Finds, moves and raises VS Code windows with the Accessibility API.

let vscodeBundleId = "com.microsoft.VSCode"
// Corner radius of a macOS window (measured on macOS 26). The bar uses it for
// its own corners, and for the solid pieces that fill the gaps outside VS
// Code's rounded left corners, next to the bar. Not used to place windows.
let windowRadius: CGFloat = 16

enum VSCodeWindows {
    static func app() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: vscodeBundleId).first
    }

    static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
    }

    static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func point(_ el: AXUIElement, _ name: String) -> CGPoint? {
        guard let v = attr(el, name), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    static func size(_ el: AXUIElement, _ name: String) -> CGSize? {
        guard let v = attr(el, name), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    // Position and size, in AX coordinates (top-left origin).
    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = point(el, kAXPositionAttribute), let s = size(el, kAXSizeAttribute) else { return nil }
        return CGRect(origin: p, size: s)
    }

    // A normal window, not a dialog.
    static func isStandard(_ ax: AXUIElement) -> Bool {
        (attr(ax, kAXSubroleAttribute) as? String) == kAXStandardWindowSubrole
    }

    // Normal VS Code windows (no dialogs).
    static func windows(_ app: NSRunningApplication) -> [AXUIElement] {
        let el = AXUIElementCreateApplication(app.processIdentifier)
        guard let list = attr(el, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        return list.filter(isStandard)
    }

    static func focusedWindow(_ app: NSRunningApplication) -> AXUIElement? {
        element(attr(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute))
    }

    // The front VS Code window next to the bar. AX lists windows front to back.
    static func frontArranged(_ app: NSRunningApplication, width: CGFloat) -> AXUIElement? {
        windows(app).first { isArranged($0, width: width) }
    }

    // True if VS Code is in front and this window has the keyboard focus.
    // A dialog or another VS Code window takes the focus away.
    static func isFocused(_ ax: AXUIElement, _ app: NSRunningApplication) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              let focused = focusedWindow(app) else { return false }
        return CFEqual(focused, ax)
    }

    // True if the window fills the place next to the bar.
    static func isArranged(_ ax: AXUIElement, width: CGFloat) -> Bool {
        guard let r = targetFrame(width: width), let f = frame(ax) else { return false }
        return abs(f.minX - r.minX) < 2 && abs(f.minY - r.minY) < 2
            && abs(f.width - r.width) < 2 && abs(f.height - r.height) < 2
    }

    // The close, minimize and zoom buttons together, relative to the
    // window's top-left corner.
    static func buttonsFrame(_ ax: AXUIElement) -> CGRect? {
        guard let origin = point(ax, kAXPositionAttribute) else { return nil }
        var all: CGRect?
        for name in [kAXCloseButtonAttribute, kAXMinimizeButtonAttribute, kAXZoomButtonAttribute] {
            guard let button = element(attr(ax, name)), let f = frame(button) else { continue }
            all = all?.union(f) ?? f
        }
        return all?.offsetBy(dx: -origin.x, dy: -origin.y)
    }

    // Em and en dashes become "-", so " - " and " — " both work as separators.
    static func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: "—", with: "-").replacingOccurrences(of: "–", with: "-")
    }

    // Title parts. The window.title setting decides the format, for example
    // "folder - branch" or "file.js — folder — Visual Studio Code".
    static func titleParts(_ title: String) -> [String] {
        var t = normalize(title).trimmingCharacters(in: .whitespaces)
        // An empty last part (for example no branch) leaves a trailing " -".
        while t.hasSuffix(" -") { t = String(t.dropLast(2)).trimmingCharacters(in: .whitespaces) }
        return t.components(separatedBy: " - ").map {
            $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "●")))
        }
    }

    // How well an AX window matches a registry window. 0 = no match.
    static func score(_ ax: AXUIElement, _ w: VSWindow) -> Int {
        let parts = titleParts((attr(ax, kAXTitleAttribute) as? String) ?? "")
        let name = normalize(w.name)
        if parts.first == name { return 3 }
        if parts.dropFirst().contains(name) { return 2 }
        if let doc = attr(ax, kAXDocumentAttribute) as? String, let url = URL(string: doc), url.isFileURL {
            let p = realPath(url.path)
            if w.folders.contains(where: { isInside(p, $0) }) { return 1 }
        }
        return 0
    }

    static func find(_ app: NSRunningApplication, _ w: VSWindow) -> AXUIElement? {
        var best: AXUIElement?
        var bestScore = 0
        for ax in windows(app) {
            let s = score(ax, w)
            if s > bestScore {
                best = ax
                bestScore = s
            }
        }
        return best
    }

    // UUID of the screen for the bar, from the settings. nil: the main screen.
    static var screenId: String?

    // The bar's screen minus the bar, in AX coordinates (top-left origin of
    // the main screen).
    static func targetFrame(width: CGFloat) -> CGRect? {
        guard let screen = NSScreen.bar(screenId), let main = NSScreen.screens.first else { return nil }
        let vf = screen.visibleFrame
        return CGRect(x: vf.minX + width, y: main.frame.maxY - vf.maxY, width: vf.width - width, height: vf.height)
    }

    // Bar frame, in Cocoa coordinates (bottom-left origin).
    static func barFrame(width: CGFloat) -> NSRect {
        guard let screen = NSScreen.bar(screenId) else { return NSRect(x: 0, y: 0, width: width, height: 600) }
        let vf = screen.visibleFrame
        return NSRect(x: vf.minX, y: vf.minY, width: width, height: vf.height)
    }

    // Strip just right of the bar, where the corner pieces go. Cocoa coordinates.
    static func cornerFrame(width: CGFloat) -> NSRect {
        let bar = barFrame(width: width)
        return NSRect(x: bar.maxX, y: bar.minY, width: windowRadius, height: bar.height)
    }

    // Box over the window buttons of a window next to the bar. Cocoa coordinates.
    // The 3 pt margin stays clear of the window's rounded corner and border.
    static func coverFrame(width: CGFloat, buttons: CGRect) -> NSRect? {
        guard let target = targetFrame(width: width), let main = NSScreen.screens.first else { return nil }
        let r = buttons.offsetBy(dx: target.minX, dy: target.minY).insetBy(dx: -3, dy: -3)
        return NSRect(x: r.minX, y: main.frame.maxY - r.maxY, width: r.width, height: r.height)
    }

    // restore: false leaves a minimized window minimized.
    static func place(_ ax: AXUIElement, width: CGFloat, restore: Bool = true) {
        guard let r = targetFrame(width: width) else { return }
        if isFullScreen(ax) { return }
        if isMinimized(ax) {
            guard restore else { return }
            AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        var origin = r.origin
        var size = r.size
        guard let pos = AXValueCreate(.cgPoint, &origin), let sz = AXValueCreate(.cgSize, &size) else { return }
        // Position, size, then position again: some windows clamp the first move.
        AXUIElementSetAttributeValue(ax, kAXPositionAttribute as CFString, pos)
        AXUIElementSetAttributeValue(ax, kAXSizeAttribute as CFString, sz)
        AXUIElementSetAttributeValue(ax, kAXPositionAttribute as CFString, pos)
    }

    static func isMinimized(_ ax: AXUIElement) -> Bool {
        (attr(ax, kAXMinimizedAttribute) as? Bool) == true
    }

    static func isFullScreen(_ ax: AXUIElement) -> Bool {
        (attr(ax, "AXFullScreen") as? Bool) == true
    }

    // True if at least one VS Code window is not minimized.
    static func hasVisibleWindow(_ app: NSRunningApplication) -> Bool {
        windows(app).contains { !isMinimized($0) }
    }

    // Window server number of the front VS Code window on the current Space.
    // Covered windows count. Hidden and minimized windows do not.
    static func frontWindowNumber(_ app: NSRunningApplication) -> Int? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        return list?.first {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier
                && ($0[kCGWindowLayer as String] as? Int) == 0
        }?[kCGWindowNumber as String] as? Int
    }

    // Close a VS Code window, like a click on its close button (the cover
    // hides that button). VS Code asks first if files are not saved.
    // Returns the window. Nil if no window matches.
    @discardableResult
    static func close(_ w: VSWindow) -> AXUIElement? {
        guard let app = app(), let ax = find(app, w),
              let button = element(attr(ax, kAXCloseButtonAttribute)) else { return nil }
        AXUIElementPerformAction(button, kAXPressAction as CFString)
        return ax
    }

    // Hide VS Code, like ⌘H. All windows go at once (minimize does them one
    // by one), and a click on VS Code in the Dock brings them all back.
    static func hideApp() {
        app()?.hide()
    }

    static func arrangeAll(width: CGFloat) {
        guard let app = app() else { return }
        for ax in windows(app) { place(ax, width: width, restore: false) }
    }

    // Bring VS Code to the front with its last active window.
    @discardableResult
    static func activateApp() -> NSRunningApplication? {
        guard let app = app() else { return nil }
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        app.activate(options: [])
        return app
    }

    // Size the window next to the bar and bring it to the front.
    static func focus(_ w: VSWindow, width: CGFloat) {
        guard let app = app() else { return }
        guard let ax = find(app, w) else {
            openWithCLI(app, w)
            return
        }
        place(ax, width: width)
        AXUIElementSetAttributeValue(ax, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
        activateApp()
        // Raise again after activation, so this window ends on top.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
        }
    }

    // Fallback when no AX window matches: ask VS Code to focus the folder.
    static func openWithCLI(_ app: NSRunningApplication, _ w: VSWindow) {
        guard let bundle = app.bundleURL, let target = w.workspaceFile ?? w.rawFolders.first else { return }
        let cli = bundle.appendingPathComponent("Contents/Resources/app/bin/code")
        let p = Process()
        p.executableURL = cli
        p.arguments = [target]
        try? p.run()
    }
}

// Tells the bar when VS Code opens, moves or resizes a window, or changes
// its front window. Watches the VS Code that runs now. Call update() again
// when VS Code starts or quits.
@MainActor
final class WindowWatcher {
    var onAttach: ((NSRunningApplication) -> Void)?
    var onCreated: ((AXUIElement) -> Void)?
    var onChanged: ((AXUIElement) -> Void)?
    // The window that got focus (or became the main window), and which of
    // the two notifications it is.
    var onFocusChanged: ((AXUIElement, String) -> Void)?
    private var observer: AXObserver?
    private var pid: pid_t = 0

    func update() {
        let app = VSCodeWindows.app()
        let current = app?.processIdentifier ?? 0
        if current == pid && observer != nil { return }
        stop()
        guard let app, AXIsProcessTrusted() else { return }
        var obs: AXObserver?
        let created = AXObserverCreate(current, { _, element, notification, refcon in
            guard let refcon else { return }
            let watcher = Unmanaged<WindowWatcher>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            MainActor.assumeIsolated { watcher.handle(element, name) }
        }, &obs)
        guard created == .success, let obs else { return }
        let el = AXUIElementCreateApplication(current)
        let ref = Unmanaged.passUnretained(self).toOpaque()
        // Fails while VS Code is still starting. The next update() tries again.
        guard AXObserverAddNotification(obs, el, kAXWindowCreatedNotification as CFString, ref) == .success else { return }
        AXObserverAddNotification(obs, el, kAXMainWindowChangedNotification as CFString, ref)
        AXObserverAddNotification(obs, el, kAXFocusedWindowChangedNotification as CFString, ref)
        AXObserverAddNotification(obs, el, kAXWindowMovedNotification as CFString, ref)
        AXObserverAddNotification(obs, el, kAXWindowResizedNotification as CFString, ref)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        observer = obs
        pid = current
        onAttach?(app)
    }

    private func stop() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        pid = 0
    }

    private func handle(_ element: AXUIElement, _ name: String) {
        switch name {
        case kAXWindowCreatedNotification: onCreated?(element)
        case kAXWindowMovedNotification, kAXWindowResizedNotification: onChanged?(element)
        default: onFocusChanged?(element, name)
        }
    }
}

extension NSScreen {
    // Stays the same after a restart, unlike the display number.
    var displayUUID: String? {
        guard let n = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(n.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    // The screen with this UUID. If it is not connected, the main screen
    // (the one with the menu bar).
    static func bar(_ uuid: String?) -> NSScreen? {
        screens.first { uuid != nil && $0.displayUUID == uuid } ?? screens.first
    }
}

// An AX element as a dictionary key. Two elements for the same window are equal.
struct AXKey: Hashable {
    let element: AXUIElement

    init(_ element: AXUIElement) { self.element = element }

    static func == (a: AXKey, b: AXKey) -> Bool { CFEqual(a.element, b.element) }

    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}
