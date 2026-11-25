import AppKit
import ApplicationServices

// Finds, moves and raises VSCode windows with the Accessibility API.

let vscodeBundleId = "com.microsoft.VSCode"
// Corner radius of a macOS window (measured on macOS 26). The bar uses it for
// its own corners, and for the solid pieces that fill the gaps outside VS
// Code's rounded top corners, under the bar. Not used to place windows.
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

    // Normal VSCode windows (no dialogs).
    static func windows(_ app: NSRunningApplication) -> [AXUIElement] {
        let el = AXUIElementCreateApplication(app.processIdentifier)
        guard let list = attr(el, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        return list.filter(isStandard)
    }

    static func focusedWindow(_ app: NSRunningApplication) -> AXUIElement? {
        element(attr(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute))
    }

    // The front VSCode window next to the bar. AX lists windows front to back.
    static func frontArranged(_ app: NSRunningApplication, height: CGFloat) -> AXUIElement? {
        windows(app).first { isArranged($0, height: height) }
    }

    // True if VSCode is in front and this window has the keyboard focus.
    // A dialog or another VSCode window takes the focus away.
    static func isFocused(_ ax: AXUIElement, _ app: NSRunningApplication) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              let focused = focusedWindow(app) else { return false }
        return CFEqual(focused, ax)
    }

    // True if the window fills the place next to the bar.
    static func isArranged(_ ax: AXUIElement, height: CGFloat) -> Bool {
        guard let r = targetFrame(height: height), let f = frame(ax) else { return false }
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

    // UUID of the bar's screen, from the settings. nil: the main screen.
    static var screenId: String?

    // Where the bar and the VSCode windows are, as one group, in AX
    // coordinates (top-left origin of the main screen). The bar is on top
    // and the windows fill the rest. nil: all of the bar's screen.
    static var group: CGRect?

    // Cocoa coordinates (bottom-left origin) to AX coordinates, and back.
    // It is the same flip both ways.
    static func flip(_ r: CGRect) -> CGRect {
        guard let main = NSScreen.screens.first else { return r }
        return CGRect(x: r.minX, y: main.frame.maxY - r.maxY, width: r.width, height: r.height)
    }

    static func flip(_ p: CGPoint) -> CGPoint {
        guard let main = NSScreen.screens.first else { return p }
        return CGPoint(x: p.x, y: main.frame.maxY - p.y)
    }

    // The screen without the menu bar and the Dock, in AX coordinates.
    static func visibleFrame(_ screen: NSScreen) -> CGRect {
        flip(screen.visibleFrame)
    }

    static var groupFrame: CGRect? {
        group ?? NSScreen.bar(screenId).map(visibleFrame)
    }

    // The group minus the bar, in AX coordinates.
    static func targetFrame(height: CGFloat) -> CGRect? {
        guard let g = groupFrame else { return nil }
        return CGRect(x: g.minX, y: g.minY + height, width: g.width, height: g.height - height)
    }

    // Bar frame, in Cocoa coordinates (bottom-left origin). group: another
    // group frame, for example while the user drags a window.
    static func barFrame(height: CGFloat, group: CGRect? = nil) -> NSRect {
        guard let g = group ?? groupFrame else { return NSRect(x: 0, y: 0, width: 800, height: height) }
        return flip(CGRect(x: g.minX, y: g.minY, width: g.width, height: height))
    }

    // The screen with this point on it. AX coordinates.
    static func screen(at p: CGPoint) -> NSScreen? {
        NSScreen.screens.first { flip($0.frame).contains(p) }
    }

    // The screen with the most of this rect on it. nil if it is on no screen.
    static func screen(for r: CGRect) -> NSScreen? {
        func area(_ s: NSScreen) -> CGFloat {
            let i = flip(s.frame).intersection(r)
            return i.isNull ? 0 : i.width * i.height
        }
        guard let best = NSScreen.screens.max(by: { area($0) < area($1) }), area(best) > 0 else { return nil }
        return best
    }

    // The group on one screen, so all of the bar is in view. Near all of
    // the screen counts as all of it, so a group that fills its screen
    // still fills it when the Dock or the resolution changes. A group on no
    // screen (its screen is not connected) fills the bar's screen.
    static func fit(_ g: CGRect, on screen: NSScreen? = nil) -> CGRect? {
        guard let s = screen ?? self.screen(for: g) else { return NSScreen.bar(screenId).map(visibleFrame) }
        let v = visibleFrame(s)
        let t: CGFloat = 40
        if abs(g.minX - v.minX) < t, abs(g.minY - v.minY) < t, abs(g.maxX - v.maxX) < t, abs(g.maxY - v.maxY) < t {
            return v
        }
        let w = min(g.width, v.width), h = min(g.height, v.height)
        return CGRect(x: min(max(g.minX, v.minX), v.maxX - w), y: min(max(g.minY, v.minY), v.maxY - h), width: w, height: h)
    }

    // True if the group fills its screen.
    static func isFill(_ g: CGRect) -> Bool {
        guard let s = screen(for: g) else { return false }
        let v = visibleFrame(s)
        return abs(g.minX - v.minX) < 2 && abs(g.minY - v.minY) < 2 && abs(g.maxX - v.maxX) < 2 && abs(g.maxY - v.maxY) < 2
    }

    // Where tiles can have their edges, as parts of the screen. macOS tiles
    // are halves, quarters and fill. Rectangle has thirds too.
    static let halves: [CGFloat] = [0, 1 / 2, 1]
    static let thirds: [CGFloat] = [0, 1 / 3, 1 / 2, 2 / 3, 1]

    // The rect's edges as parts of the screen (0: left or top, 1: right or
    // bottom), if each edge is near one of these parts. The tolerance is for
    // the gaps that macOS and Rectangle can put around tiles.
    static func tileParts(_ r: CGRect, on v: CGRect, _ parts: [CGFloat])
        -> (left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat)? {
        let t: CGFloat = 30
        func part(_ a: CGFloat, _ start: CGFloat, _ size: CGFloat) -> CGFloat? {
            parts.first { abs(start + $0 * size - a) <= t }
        }
        guard let left = part(r.minX, v.minX, v.width), let right = part(r.maxX, v.minX, v.width),
              let top = part(r.minY, v.minY, v.height), let bottom = part(r.maxY, v.minY, v.height),
              right - left >= 0.3, bottom - top >= 0.3 else { return nil }
        return (left, right, top, bottom)
    }

    // True if macOS or Rectangle tiled the window on this screen.
    static func isTile(_ r: CGRect, on v: CGRect, parts: [CGFloat] = halves) -> Bool {
        tileParts(r, on: v, parts) != nil
    }

    // The Rectangle command for a tile. Only commands that do more when
    // they repeat: halves can go to the next screen, and Rectangle can
    // change their size. Not Maximize. Thirds only on a wide screen, where
    // Rectangle makes columns.
    static func rectangleCommand(_ r: CGRect, on v: CGRect) -> String? {
        guard let p = tileParts(r, on: v, thirds) else { return nil }
        // In sixths: 2 is a third, 3 a half, 4 two thirds.
        let key = [p.left, p.right, p.top, p.bottom].map { Int(($0 * 6).rounded()) }
        let names: [[Int]: String] = [
            [0, 3, 0, 6]: "left-half", [3, 6, 0, 6]: "right-half", [0, 6, 0, 3]: "top-half", [0, 6, 3, 6]: "bottom-half",
            [0, 3, 0, 3]: "top-left", [3, 6, 0, 3]: "top-right", [0, 3, 3, 6]: "bottom-left", [3, 6, 3, 6]: "bottom-right",
            [0, 2, 0, 6]: "first-third", [2, 4, 0, 6]: "center-third", [4, 6, 0, 6]: "last-third",
            [0, 4, 0, 6]: "first-two-thirds", [2, 6, 0, 6]: "last-two-thirds",
        ]
        guard let name = names[key] else { return nil }
        return name.contains("third") && v.height > v.width ? nil : name
    }

    // A full screen window: macOS full screen, or VSCode's own full screen
    // (window.nativeFullScreen off), which covers the whole screen.
    static func fillsScreen(_ ax: AXUIElement) -> Bool {
        if isFullScreen(ax) { return true }
        guard let f = frame(ax), let s = screen(for: f) else { return false }
        let sf = flip(s.frame)
        return f.minX <= sf.minX + 1 && f.minY <= sf.minY + 1 && f.maxX >= sf.maxX - 1 && f.maxY >= sf.maxY - 1
    }

    // Strip just under the bar, where the corner pieces go. Cocoa coordinates.
    static func cornerFrame(height: CGFloat, group: CGRect? = nil) -> NSRect {
        cornerFrame(bar: barFrame(height: height, group: group))
    }

    static func cornerFrame(bar: NSRect) -> NSRect {
        NSRect(x: bar.minX, y: bar.minY - windowRadius, width: bar.width, height: windowRadius)
    }

    // Box over the window buttons of a window next to the bar. Cocoa coordinates.
    // The 3 pt margin stays clear of the window's rounded corner and border.
    static func coverFrame(height: CGFloat, buttons: CGRect) -> NSRect? {
        guard let target = targetFrame(height: height) else { return nil }
        return flip(buttons.offsetBy(dx: target.minX, dy: target.minY).insetBy(dx: -3, dy: -3))
    }

    // When the bar last placed each window. Its own moves send move and
    // resize events too. Those are not the user's.
    static var placedAt: [AXKey: Date] = [:]

    static func placedByBar(_ ax: AXUIElement, within seconds: TimeInterval = 0.3) -> Bool {
        placedAt[AXKey(ax)].map { Date().timeIntervalSince($0) < seconds } ?? false
    }

    // One step of a slide. A window that gets narrower moves first, and one
    // that gets wider grows first, so the other edge only goes past its new
    // place, mostly off the screen, and not inside it.
    static func setFrame(_ ax: AXUIElement, _ r: CGRect) {
        placedAt[AXKey(ax)] = Date()
        var origin = r.origin
        var size = r.size
        guard let pos = AXValueCreate(.cgPoint, &origin), let sz = AXValueCreate(.cgSize, &size) else { return }
        let narrower = (self.size(ax, kAXSizeAttribute)?.width ?? 0) > r.width
        for (name, value) in narrower ? [(kAXPositionAttribute, pos), (kAXSizeAttribute, sz)]
                                      : [(kAXSizeAttribute, sz), (kAXPositionAttribute, pos)] {
            AXUIElementSetAttributeValue(ax, name as CFString, value)
        }
    }

    // restore: false leaves a minimized window minimized.
    static func place(_ ax: AXUIElement, height: CGFloat, restore: Bool = true) {
        guard let r = targetFrame(height: height) else { return }
        if isFullScreen(ax) { return }
        if isMinimized(ax) {
            guard restore else { return }
            AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        let now = Date()
        placedAt = placedAt.filter { now.timeIntervalSince($0.value) < 5 }
        placedAt[AXKey(ax)] = now
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

    // True if at least one VSCode window is not minimized.
    static func hasVisibleWindow(_ app: NSRunningApplication) -> Bool {
        windows(app).contains { !isMinimized($0) }
    }

    // Window server number of the front VSCode window on the current Space.
    // Covered windows count. Hidden and minimized windows do not.
    static func frontWindowNumber(_ app: NSRunningApplication) -> Int? {
        frontWindowInfo(app)?[kCGWindowNumber as String] as? Int
    }

    static func frontWindowInfo(_ app: NSRunningApplication) -> [String: Any]? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        return list?.first {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier
                && ($0[kCGWindowLayer as String] as? Int) == 0
        }
    }

    // A window's frame from the window server, in AX coordinates.
    static func bounds(_ info: [String: Any]) -> CGRect? {
        guard let d = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: d as CFDictionary)
    }

    // The window that the user drags: the front VSCode window, once it is
    // away from this frame. The others stay there, next to the bar.
    static func movingWindowNumber(_ app: NSRunningApplication, from f: CGRect) -> CGWindowID? {
        guard let info = frontWindowInfo(app), let b = bounds(info),
              abs(b.minX - f.minX) >= 1 || abs(b.minY - f.minY) >= 1 || abs(b.width - f.width) >= 1 || abs(b.height - f.height) >= 1
        else { return nil }
        return info[kCGWindowNumber as String] as? CGWindowID
    }

    // Where the window is on screen now. Quick: the window server knows it
    // during a drag, and VSCode is not asked.
    static func windowBounds(_ number: CGWindowID) -> CGRect? {
        let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], number) as? [[String: Any]]
        return list?.first.flatMap(bounds)
    }

    // Close a VSCode window, like a click on its close button (the cover
    // hides that button). VSCode asks first if files are not saved.
    // False if the window has no close button.
    static func close(_ ax: AXUIElement) -> Bool {
        guard let button = element(attr(ax, kAXCloseButtonAttribute)) else { return false }
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    // Hide VSCode, like ⌘H. All windows go at once (minimize does them one
    // by one), and a click on VSCode in the Dock brings them all back.
    static func hideApp() {
        app()?.hide()
    }

    static func arrangeAll(height: CGFloat) {
        guard let app = app() else { return }
        for ax in windows(app) { place(ax, height: height, restore: false) }
    }

    // Bring VSCode to the front with its last active window.
    @discardableResult
    static func activateApp() -> NSRunningApplication? {
        guard let app = app() else { return nil }
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        app.activate(options: [])
        return app
    }

    // Size the window under the bar and bring it to the front.
    static func focus(_ ax: AXUIElement, height: CGFloat) {
        place(ax, height: height)
        AXUIElementSetAttributeValue(ax, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
        activateApp()
        // Raise again after activation, so this window ends on top.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
        }
    }

    // Fallback when no AX window matches: ask VSCode to focus the folder.
    static func openWithCLI(_ app: NSRunningApplication, _ w: VSWindow) {
        guard let bundle = app.bundleURL, let target = w.workspaceFile ?? w.rawFolders.first else { return }
        runCLI(bundle, [target])
    }

    // Open a folder or a workspace file, like "code <path>". VSCode shows
    // the tabs it had. Starts VSCode if it is not running.
    static func open(_ path: String) {
        guard let bundle = app()?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: vscodeBundleId)
        else { return }
        runCLI(bundle, [path])
    }

    // Open a new, empty VSCode window. It shows VSCode's Welcome page,
    // where the user picks a folder. If VSCode is not running, start it:
    // it then opens its own windows.
    static func newWindow() {
        if let app = app(), let bundle = app.bundleURL {
            runCLI(bundle, ["--new-window"])
        } else if let bundle = NSWorkspace.shared.urlForApplication(withBundleIdentifier: vscodeBundleId) {
            NSWorkspace.shared.openApplication(at: bundle, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // VSCode's "code" command, from the app bundle.
    private static func runCLI(_ bundle: URL, _ arguments: [String]) {
        let p = Process()
        p.executableURL = bundle.appendingPathComponent("Contents/Resources/app/bin/code")
        p.arguments = arguments
        try? p.run()
    }
}

// Tells the bar when VSCode opens, moves or resizes a window, or changes
// its front window. Watches the VSCode that runs now. Call update() again
// when VSCode starts or quits.
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
        // Fails while VSCode is still starting. The next update() tries again.
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
