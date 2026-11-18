import AppKit
import Combine
import SwiftUI

final class BarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = BarModel()
    let settings = Settings()
    let recorder = ShortcutRecorder()
    let loginItem = LoginItem()
    let watcher = WindowWatcher()
    // Watches the window files, so a new title bar color shows at once.
    var windowFiles: FolderWatcher?
    var updatePending = false
    // What the cover shows, so it can be recolored at once without asking
    // VS Code anything. VS Code answers slowly while it redraws for a switch.
    var coverRowId: String?
    // The selected row shows the same title bar color as the cover.
    var coverFocused: Bool {
        get { model.focused }
        set { if model.focused != newValue { model.focused = newValue } }
    }
    // VS Code windows next to the bar, and their row ids.
    var arrangedRows: [AXKey: String] = [:]
    var ticks = 0
    var panel: BarPanel!
    var corners: NSPanel!
    var cover: NSPanel!
    var timer: Timer?
    // Keeps the bar hidden while VS Code hides.
    var hideUntil = Date.distantPast
    // Windows that moved or changed size, to put back next to the bar.
    var changed: [AXUIElement] = []
    var snapPending = false
    // Windows that did not fit next to the bar (for example with Stage
    // Manager on), and the frame they stayed at. The bar does not try such a
    // window again until its frame changes, so it does not fight the window.
    var stuck: [(window: AXUIElement, frame: CGRect)] = []
    var cancellables: Set<AnyCancellable> = []

    var width: CGFloat { CGFloat(settings.width) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        allowBackgroundCursor()
        // Shows the system prompt once if access is missing.
        model.trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        VSCodeWindows.screenId = settings.screen

        // Non-activating: a click on a row does not take focus from VS Code,
        // so one click is enough to switch windows.
        panel = BarPanel(contentRect: VSCodeWindows.barFrame(width: width), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        // Clear, so the bar can draw its own rounded corners.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The bar color is fixed dark, so keep text and controls dark-mode.
        panel.appearance = NSAppearance(named: .darkAqua)
        // No shadow, so no gradient falls on the corner pieces.
        panel.hasShadow = false

        // Clear strip above VS Code with solid pieces in its rounded corner gaps.
        // Above VS Code, so VS Code's shadow can't tint them. Clicks pass through.
        corners = NSPanel(contentRect: VSCodeWindows.cornerFrame(width: width), styleMask: [.borderless], backing: .buffered, defer: false)
        corners.level = .floating
        corners.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        corners.isOpaque = false
        corners.backgroundColor = .clear
        corners.hasShadow = false
        corners.ignoresMouseEvents = true
        corners.hidesOnDeactivate = false
        corners.contentView = NSHostingView(rootView: CornerPieces(radius: windowRadius, join: model.join))

        // Solid box over the close, minimize and zoom buttons of the VS Code
        // window. It takes their clicks. The bar has its own buttons.
        cover = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        cover.level = .floating
        cover.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        cover.backgroundColor = barNSColor
        cover.hasShadow = false
        cover.hidesOnDeactivate = false

        let actions = BarActions(
            close: { NSApp.terminate(nil) },
            pick: { [weak self] row in self?.pick(row) },
            move: { [weak self] from, to in self?.move(from, to) },
            toggleSettings: { [weak self] in self?.toggleSettings() },
            arrangeAll: { [weak self] in self?.arrangeAll() },
            hideAll: { [weak self] in self?.hideAll() },
            resetLayout: { [weak self] in self?.resetLayout() },
            clearHotKey: { [weak self] in self?.setHotKey(nil) }
        )
        panel.contentView = FirstMouseHostingView(rootView: BarView(
            model: model, settings: settings, recorder: recorder, loginItem: loginItem, actions: actions))

        // Resize the bar and the VS Code windows when the width changes.
        settings.$width.dropFirst().removeDuplicates().sink { [weak self] w in
            self?.layoutPanels(width: CGFloat(w))
            VSCodeWindows.arrangeAll(width: CGFloat(w))
            self?.updateVisibility()
        }
        .store(in: &cancellables)

        // Move the bar and the VS Code windows to the new screen.
        settings.$screen.dropFirst().removeDuplicates().sink { [weak self] id in
            VSCodeWindows.screenId = id
            self?.screensChanged()
        }
        .store(in: &cancellables)

        setUpShortcut()
        setUpWatcher()

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(appChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(appChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(appsChanged), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(appsChanged), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)

        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func setUpWatcher() {
        watcher.onCreated = { [weak self] ax in self?.arrangeNew(ax) }
        watcher.onChanged = { [weak self] ax in self?.windowChanged(ax) }
        watcher.onFocusChanged = { [weak self] ax, name in
            guard let self else { return }
            if name == kAXFocusedWindowChangedNotification {
                // A window next to the bar got focus, so it is now in front.
                // Any other window (a dialog, or one elsewhere) takes the
                // focus from the one under the cover.
                if let id = self.arrangedRows[AXKey(ax)] {
                    self.coverRowId = id
                    self.coverFocused = self.vscodeInFront
                } else {
                    self.coverFocused = false
                }
                self.recolorCoverNow()
            }
            self.updateSoon()
        }
        // Once per VS Code run: when the bar opens, or when VS Code starts later.
        watcher.onAttach = { [weak self] _ in self?.arrangeAll() }
        watcher.update()
    }

    // A new VS Code window goes next to the bar right away. Place it again a
    // moment later, in case VS Code sets its saved size after it opens.
    func arrangeNew(_ ax: AXUIElement) {
        guard VSCodeWindows.isStandard(ax) else { return }
        VSCodeWindows.place(ax, width: width, restore: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                VSCodeWindows.place(ax, width: self.width, restore: false)
                self.updateVisibility()
            }
        }
    }

    // A VS Code window moved or changed size: by a drag, the Window menu,
    // macOS tiling or a shortcut. It goes back next to the bar.
    func windowChanged(_ ax: AXUIElement) {
        if !changed.contains(where: { CFEqual($0, ax) }) { changed.append(ax) }
        scheduleSnapBack()
    }

    func scheduleSnapBack() {
        guard !snapPending else { return }
        snapPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated { self?.snapBack() }
        }
    }

    // Waits while a mouse button is down, so a drag ends first. Our own
    // place() also sends move and resize events. Those windows are already
    // next to the bar, so nothing happens.
    func snapBack() {
        snapPending = false
        if NSEvent.pressedMouseButtons != 0 {
            scheduleSnapBack()
            return
        }
        let windows = changed
        changed = []
        // A closed window has no frame.
        stuck.removeAll { VSCodeWindows.frame($0.window) == nil }
        for ax in windows {
            guard VSCodeWindows.isStandard(ax), !VSCodeWindows.isMinimized(ax), !VSCodeWindows.isFullScreen(ax),
                  !VSCodeWindows.isArranged(ax, width: width), let before = VSCodeWindows.frame(ax),
                  !stuck.contains(where: { CFEqual($0.window, ax) && $0.frame == before }) else { continue }
            VSCodeWindows.place(ax, width: width, restore: false)
            stuck.removeAll { CFEqual($0.window, ax) }
            if !VSCodeWindows.isArranged(ax, width: width), let after = VSCodeWindows.frame(ax) {
                stuck.append((ax, after))
            }
        }
        updateVisibility()
    }

    func setUpShortcut() {
        HotKey.shared.action = { [weak self] in self?.bringToFront() }
        // While recording, the old shortcut is off and the bar takes key presses.
        recorder.onStart = { [weak self] in
            HotKey.shared.register(nil)
            NSApp.activate()
            self?.panel.makeKey()
        }
        recorder.onEnd = { [weak self] in self?.applyHotKey() }
        recorder.onRecord = { [weak self] spec in self?.setHotKey(spec) }
        applyHotKey()
    }

    func setHotKey(_ spec: HotKeySpec?) {
        settings.hotKey = spec
        applyHotKey()
    }

    func applyHotKey() {
        if !HotKey.shared.register(settings.hotKey) {
            recorder.error = "macOS refused this shortcut. Try another."
        }
    }

    // The shortcut: VS Code's active window and the bar come to the front.
    func bringToFront() {
        VSCodeWindows.activateApp()
        panel.orderFrontRegardless()
    }

    func pick(_ row: Row) {
        model.activeId = row.id
        // Recolor the cover in the same step as the switch, so the old
        // window's color does not flash.
        coverRowId = row.id
        coverFocused = true
        recolorCover()
        VSCodeWindows.focus(row.window, width: width)
    }

    func move(_ from: String, _ to: String) {
        settings.move(from, to: to, visible: model.rows.map(\.key))
        model.rows = settings.ordered(model.rows)
    }

    func arrangeAll() {
        VSCodeWindows.arrangeAll(width: width)
    }

    // Hide VS Code. The bar hides with it.
    func hideAll() {
        if model.settingsOpen { toggleSettings() }
        hideUntil = Date().addingTimeInterval(1.5)
        VSCodeWindows.hideApp()
        updateVisibility()
    }

    func resetLayout() {
        settings.resetLayout()
        model.rows = settings.ordered(loadRows())
    }

    // Settings need focus (color picker, drag and drop, shortcut keys).
    // On close, focus goes back to VS Code.
    func toggleSettings() {
        let opening = !model.settingsOpen
        if opening {
            loginItem.refresh()
            NSApp.activate()
            panel.makeKey()
        } else {
            recorder.stop()
            VSCodeWindows.activateApp()
        }
        withAnimation(.easeInOut(duration: 0.2)) { model.settingsOpen = opening }
    }

    func tick() {
        model.trusted = AXIsProcessTrusted()
        watcher.update()
        // The folder appears when the extension first runs.
        if windowFiles == nil {
            windowFiles = FolderWatcher(path: statusDir() + "/windows") { [weak self] in self?.windowFilesChanged() }
        }
        model.rows = settings.ordered(loadRows())
        ticks += 1
        if ticks % 3 == 1 { refreshArrangedRows() }
        updateActive()
        updateVisibility()
    }

    // A window file changed, for example new title bar colors while a VS
    // Code modal opens. Recolor the cover at once, then check the rest.
    func windowFilesChanged() {
        model.rows = settings.ordered(loadRows())
        recolorCoverNow()
        updateSoon()
    }

    var vscodeInFront: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == vscodeBundleId
    }

    // The cover's color from what the bar already knows. No calls to VS Code.
    func recolorCover() {
        guard cover.isVisible, let id = coverRowId,
              let w = model.rows.first(where: { $0.id == id })?.window,
              let hex = coverFocused ? w.titleBarColor : w.titleBarInactiveColor ?? w.titleBarColor else { return }
        let color = hexColor(hex)
        if cover.backgroundColor != color { cover.backgroundColor = color }
    }

    // Recolor, and put it on screen now, before the slower full update.
    func recolorCoverNow() {
        recolorCover()
        cover.displayIfNeeded()
        CATransaction.flush()
    }

    // The full update, after a quick recolor is on screen.
    func updateSoon() {
        guard !updatePending else { return }
        updatePending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updatePending = false
                self.updateActive()
                self.updateVisibility()
            }
        }
    }

    // Each VS Code window next to the bar and its row, for quick recolors.
    func refreshArrangedRows() {
        guard model.trusted, let app = VSCodeWindows.app() else {
            arrangedRows = [:]
            return
        }
        var map: [AXKey: String] = [:]
        for ax in VSCodeWindows.windows(app) where VSCodeWindows.isArranged(ax, width: width) {
            if let id = row(for: ax)?.id { map[AXKey(ax)] = id }
        }
        arrangedRows = map
    }

    // Highlight the row of the focused VS Code window.
    func updateActive() {
        guard model.trusted,
              let app = VSCodeWindows.app(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              let ax = VSCodeWindows.focusedWindow(app) else { return }
        model.activeId = row(for: ax)?.id
    }

    // The row that best matches a VS Code window.
    func row(for ax: AXUIElement) -> Row? {
        model.rows
            .map { ($0, VSCodeWindows.score(ax, $0.window)) }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }?.0
    }

    // Where the bar windows go. Quick: no calls to VS Code.
    enum Stacking: Equatable {
        case off
        // Over all windows, while VS Code or the bar is in front.
        case floating
        // Just above this VS Code window, while another app is in front, so
        // that app's windows can cover the bar like they cover VS Code.
        case above(Int)
    }

    var stacking: Stacking {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier == vscodeBundleId
            || front?.processIdentifier == ProcessInfo.processInfo.processIdentifier { return .floating }
        if let app = VSCodeWindows.app(), let n = VSCodeWindows.frontWindowNumber(app) { return .above(n) }
        return .off
    }

    // Each window goes just above the one before it.
    func stack(_ windows: [NSPanel], _ stacking: Stacking) {
        for (i, w) in windows.enumerated() {
            switch stacking {
            case .off:
                if w.isVisible { w.orderOut(nil) }
            case .floating:
                if !w.isVisible || w.level != .floating {
                    w.level = .floating
                    w.orderFrontRegardless()
                }
            case .above(let n):
                if w.level != .normal { w.level = .normal }
                w.order(.above, relativeTo: i == 0 ? n : windows[i - 1].windowNumber)
            }
        }
    }

    // Show the bar while VS Code (or the bar itself) is in front, or while a
    // VS Code window is on screen behind another app. At least one VS Code
    // window must not be minimized.
    func updateVisibility() {
        var stacking = self.stacking
        if Date() < hideUntil { stacking = .off }
        // Without Accessibility access, keep the bar so it can ask for it.
        if stacking != .off, model.trusted, let app = VSCodeWindows.app(), !VSCodeWindows.hasVisibleWindow(app) {
            stacking = .off
        }
        stack([panel, corners], stacking)
        // The cover goes just above the corner strip.
        if case .above = stacking { stacking = .above(corners.windowNumber) }
        updateCover(stacking)
    }

    // The cover goes over the window buttons of the front VS Code window
    // next to the bar. Its color is that window's title bar color, worked out
    // by the extension from its theme and settings (shaded while a VS Code
    // modal is open): the focused color, or the other one while something
    // else has focus.
    func updateCover(_ stacking: Stacking) {
        var frame: NSRect?
        var color = barNSColor
        if stacking != .off, model.trusted, let app = VSCodeWindows.app(),
           let ax = VSCodeWindows.frontArranged(app, width: width), let buttons = VSCodeWindows.buttonsFrame(ax) {
            frame = VSCodeWindows.coverFrame(width: width, buttons: buttons)
            let match = row(for: ax)
            let window = match?.window
            let focused = VSCodeWindows.isFocused(ax, app)
            coverRowId = match?.id
            coverFocused = focused
            if let id = match?.id { arrangedRows[AXKey(ax)] = id }
            if let hex = focused ? window?.titleBarColor : window?.titleBarInactiveColor ?? window?.titleBarColor {
                color = hexColor(hex)
            }
        }
        if let frame {
            if cover.backgroundColor != color { cover.backgroundColor = color }
            if cover.frame != frame { cover.setFrame(frame, display: true) }
            stack([cover], stacking)
        } else if cover.isVisible {
            cover.orderOut(nil)
        }
    }

    // The bar at the set width, and the corner strip just right of it.
    func layoutPanels(width w: CGFloat) {
        panel.setFrame(VSCodeWindows.barFrame(width: w), display: true)
        corners.setFrame(VSCodeWindows.cornerFrame(width: w), display: true)
    }

    // VS Code came to the front or went behind: the window under the cover
    // gains or loses focus. Restack at once, before the slower full update,
    // so VS Code's own buttons do not show as its windows come to the front.
    // Also on a Space change.
    @objc func appChanged() {
        coverFocused = vscodeInFront
        let shown: [NSPanel] = [panel, corners, cover]
        stack(shown.filter(\.isVisible), stacking)
        recolorCoverNow()
        updateSoon()
    }

    @objc func appsChanged() {
        watcher.update()
    }

    // Also when a screen is connected or disconnected: the bar can move to
    // another screen, and the windows go with it.
    @objc func screensChanged() {
        layoutPanels(width: width)
        arrangeAll()
        updateVisibility()
    }
}
