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
    // VSCode anything. VSCode answers slowly while it redraws for a switch.
    var coverRowId: String?
    // The selected row shows the same title bar color as the cover.
    var coverFocused: Bool {
        get { model.focused }
        set { if model.focused != newValue { model.focused = newValue } }
    }
    // VSCode windows next to the bar, and their row ids.
    var arrangedRows: [AXKey: String] = [:]
    // Empty VSCode windows and their row ids. Empty windows all look the
    // same, so the bar learns which is which: see linkEmptyWindow().
    var emptyRows: [AXKey: String] = [:]
    // When the focused VSCode window last changed.
    var focusChangedAt = Date.distantPast
    var ticks = 0
    var panel: BarPanel!
    var corners: NSPanel!
    var cover: NSPanel!
    // The bar's size: its height on top, its width on the left.
    var barSize: CGFloat { VSCodeWindows.onTop ? barHeight(lines: settings.lines) : CGFloat(settings.width) }
    // The tip under a tab. See BarModel.tip.
    var tipPanel: NSPanel!
    var timer: Timer?
    // Keeps the bar hidden while VSCode hides.
    var hideUntil = Date.distantPast
    // Windows that moved or changed size, to put back next to the bar.
    var changed: [AXUIElement] = []
    // Of those, the windows that the user moved or resized. The group
    // follows them.
    var moved: [AXUIElement] = []
    // When each new window opened. VSCode sets its saved size just after,
    // and that is not the user's move.
    var createdAt: [AXKey: Date] = [:]
    // When each window was last in full screen. As it leaves full screen,
    // it moves and changes size, and that is not the user's move.
    var fullScreenAt: [AXKey: Date] = [:]
    // The size of the group when it last did not fill its screen. A drag
    // of a group that fills its screen gives it this size again.
    var freeSize: CGSize?
    // The last group frame for which Rectangle was asked to repeat, and when.
    var lastRepeat: (frame: CGRect, at: Date)?
    var animation: GroupAnimation?
    var animationLink: CADisplayLink?
    // True while the user drags a VSCode window. The bar moves with it (see
    // LiveDrag). If it cannot, it hides until the drag ends.
    var dragging = false
    var liveDrag: LiveDrag?
    var dragLink: CADisplayLink?
    // Where the last left click went down, in AX coordinates. A move drag
    // of a VSCode window starts there. Kept only while the app runs.
    var mouseDownAt: CGPoint?
    // Mouse moves left to check, after a click in the title bar of the
    // window next to the bar. 0: the click cannot start a drag.
    var armedMoves = 0
    // Only the last scheduled snap back runs.
    var snapGeneration = 0
    // Windows that did not fit next to the bar (for example with Stage
    // Manager on), and the frame they stayed at. The bar does not try such a
    // window again until its frame changes, so it does not fight the window.
    var stuck: [(window: AXUIElement, frame: CGRect)] = []
    var cancellables: Set<AnyCancellable> = []
    // For auto sleep: when the bar started, and when the bar woke each
    // window (by key).
    let launchedAt = Date()
    var wokenAt: [String: Date] = [:]
    // The "done" time of each Claude tab that a click already showed, by
    // session id. A next click on the same "done" shows only the window.
    var shownDone: [String: Date] = [:]
    // Sleeping windows that the bar asked VSCode to open, by key.
    var waking: [String: Date] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        allowBackgroundCursor()
        // Shows the system prompt once if access is missing.
        model.trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        VSCodeWindows.screenId = settings.screen
        VSCodeWindows.onTop = settings.layout == .top
        VSCodeWindows.group = settings.group.flatMap { VSCodeWindows.fit($0) }

        // Non-activating: a click on a row does not take focus from VSCode,
        // so one click is enough to switch windows.
        panel = BarPanel(contentRect: VSCodeWindows.barFrame(size: barSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        // Transient: macOS hides the bar when it shows the desktop (a click
        // on the wallpaper) and in Mission Control, like the VSCode windows.
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        // Clear, so the bar can draw its own rounded corners.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The bar color is fixed dark, so keep text and controls dark-mode.
        panel.appearance = NSAppearance(named: .darkAqua)
        // No shadow, so no gradient falls on the corner pieces.
        panel.hasShadow = false

        // Clear strip above VSCode with solid pieces in its rounded corner gaps.
        // Above VSCode, so VSCode's shadow can't tint them. Clicks pass through.
        corners = NSPanel(contentRect: VSCodeWindows.cornerFrame(size: barSize), styleMask: [.borderless], backing: .buffered, defer: false)
        corners.level = .floating
        corners.collectionBehavior = [.canJoinAllSpaces, .transient]
        corners.isOpaque = false
        corners.backgroundColor = .clear
        corners.hasShadow = false
        corners.ignoresMouseEvents = true
        corners.hidesOnDeactivate = false
        setCornerPieces()

        // Solid box over the close, minimize and zoom buttons of the VSCode
        // window. It takes their clicks. The bar has its own buttons.
        cover = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        cover.level = .floating
        cover.collectionBehavior = [.canJoinAllSpaces, .transient]
        cover.backgroundColor = barNSColor
        cover.hasShadow = false
        cover.hidesOnDeactivate = false

        let actions = BarActions(
            close: { NSApp.terminate(nil) },
            pick: { [weak self] row in self?.pick(row) },
            closeWindow: { [weak self] row in self?.closeWindow(row) },
            sleep: { [weak self] row in self?.sleep(row) },
            canSleep: { [weak self] row in self?.canSleep(row) ?? false },
            newWindow: { VSCodeWindows.newWindow() },
            move: { [weak self] from, to in self?.move(from, to) },
            toggleSettings: { [weak self] in self?.toggleSettings() },
            arrangeAll: { [weak self] in self?.arrangeAll() },
            hideAll: { [weak self] in self?.hideAll() },
            resetOrder: { [weak self] in self?.resetOrder() },
            clearHotKey: { [weak self] in self?.setHotKey(nil) }
        )
        let host = FirstMouseHostingView(rootView: BarRoot(
            model: model, settings: settings, recorder: recorder, loginItem: loginItem, actions: actions))
        // The bar sets the panel's size. Else SwiftUI sets the panel's minimum
        // size from the content. With the settings open, that is taller than
        // the screen, and the settings go below the bottom of the screen.
        host.sizingOptions = []
        panel.contentView = host

        // Resize the bar and the VSCode windows when the width changes.
        // The new value is in settings only after a sink runs, so wait a turn.
        settings.$width.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.barChanged() } }
        }
        .store(in: &cancellables)
        // Move the bar to the top or the left, and the windows with it.
        settings.$layout.dropFirst().removeDuplicates().sink { [weak self] layout in
            VSCodeWindows.onTop = layout == .top
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.barChanged() } }
        }
        .store(in: &cancellables)
        // The top bar's height follows the lines in a tab.
        for line in [settings.$showBranch, settings.$showStatus] {
            line.dropFirst().removeDuplicates().sink { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { if VSCodeWindows.onTop { self?.barChanged() } } }
            }
            .store(in: &cancellables)
        }

        // Above the bar and the corner strip. Clicks pass through.
        tipPanel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        tipPanel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        tipPanel.collectionBehavior = [.canJoinAllSpaces, .transient]
        tipPanel.isOpaque = false
        tipPanel.backgroundColor = .clear
        tipPanel.hasShadow = true
        tipPanel.ignoresMouseEvents = true
        tipPanel.hidesOnDeactivate = false
        tipPanel.appearance = NSAppearance(named: .darkAqua)
        model.$tip.removeDuplicates().sink { [weak self] tip in self?.showTip(tip) }
            .store(in: &cancellables)

        setUpShortcut()
        setUpWatcher()
        // Clicks and drags in other apps only. For an event with no window,
        // its location is on the screen.
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            let p = event.locationInWindow
            MainActor.assumeIsolated { self?.mouseDown(at: VSCodeWindows.flip(p)) }
        }
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDragged() }
        }

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
            self.focusChangedAt = Date()
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
        // Once per VSCode run: when the bar opens, or when VSCode starts later.
        watcher.onAttach = { [weak self] _ in self?.arrangeAll() }
        watcher.update()
    }

    // A new VSCode window goes next to the bar right away. Place it again a
    // moment later, in case VSCode sets its saved size after it opens.
    func arrangeNew(_ ax: AXUIElement) {
        guard VSCodeWindows.isStandard(ax) else { return }
        createdAt[AXKey(ax)] = Date()
        VSCodeWindows.place(ax, size: barSize, restore: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                VSCodeWindows.place(ax, size: self.barSize, restore: false)
                self.updateVisibility()
            }
        }
    }

    // A VSCode window moved or changed size: by a drag, the Window menu,
    // macOS tiling or a shortcut. If the user did it, the bar and the other
    // windows follow it. If VSCode or macOS did it, it goes back next to the
    // bar.
    func windowChanged(_ ax: AXUIElement) {
        if !changed.contains(where: { CFEqual($0, ax) }) { changed.append(ax) }
        if VSCodeWindows.isFullScreen(ax) { fullScreenAt[AXKey(ax)] = Date() }
        if userInput, !VSCodeWindows.placedByBar(ax), !isNew(ax), !wasFullScreen(ax) {
            moved.removeAll { CFEqual($0, ax) }
            moved.append(ax)
            // A drag that mouseDragged() did not see start.
            if NSEvent.pressedMouseButtons != 0, !dragging { startDrag() }
        }
        scheduleSnapBack()
    }

    // The bar, the corner strip and the cover move with the dragged window
    // on each screen refresh, until the drag ends and the group follows.
    // The other windows move at the end. They are behind, and moving them
    // all the time would make VSCode slow.
    struct LiveDrag {
        // Where the windows are next to the bar, in AX coordinates.
        let from: CGRect
        let startedAt = Date()
        // The cover's place on the window, from its top-left corner.
        let cover: CGRect?
        // Where the mouse went down, in AX coordinates. Only when it went
        // down on the window next to the bar, so a move can follow the mouse.
        let grab: CGPoint?
        // The dragged window, once it is found, and where the bar put it last.
        var number: CGWindowID?
        var last: CGRect?
        // nil until it is known. A resize follows the window server, not the mouse.
        var resizing: Bool?
        // The last mouse move that moved the bar, and the mouse's speed
        // then, in points per second (AX coordinates).
        var mouseAt = Date.distantPast
        var mouse: (point: CGPoint, time: TimeInterval)?
        var velocity = CGVector.zero
    }

    // A click in the title bar of the window next to the bar can start a
    // move drag. mouseDragged() checks the next few mouse moves.
    func mouseDown(at p: CGPoint) {
        mouseDownAt = p
        armedMoves = 0
        guard !dragging, let from = VSCodeWindows.targetFrame(size: barSize), from.contains(p), p.y - from.minY < 50
        else { return }
        armedMoves = 10
    }

    // In a live drag, the bar follows the mouse. Before it, a mouse move
    // that moves the front VSCode window starts the drag. That is sooner
    // than macOS tells about the window's move.
    func mouseDragged() {
        if liveDrag != nil {
            dragMoved()
            return
        }
        guard armedMoves > 0, !dragging, let app = VSCodeWindows.app(), let from = VSCodeWindows.targetFrame(size: barSize)
        else { return }
        armedMoves -= 1
        // Only a move: a resize does not start here.
        guard let n = VSCodeWindows.movingWindowNumber(app, from: from), let b = VSCodeWindows.windowBounds(n),
              abs(b.width - from.width) < 1, abs(b.height - from.height) < 1 else { return }
        armedMoves = 0
        startDrag(number: n)
        if liveDrag != nil { dragMoved() }
        // The window that moves: the one the user clicked, which has the
        // focus now. macOS tells about its move later, too.
        if let ax = VSCodeWindows.focusedWindow(app), VSCodeWindows.isStandard(ax) {
            if !changed.contains(where: { CFEqual($0, ax) }) { changed.append(ax) }
            if !moved.contains(where: { CFEqual($0, ax) }) { moved.append(ax) }
        }
    }

    // Without a bar on screen, the bar stays hidden until the drag ends.
    // number: the dragged window, if known. It moves, and its size is the same.
    func startDrag(number: CGWindowID? = nil) {
        // A drag during a slide: the slide ends at once.
        finishAnimation()
        dragging = true
        // Ends the drag after the mouse is up, also if macOS tells nothing.
        scheduleSnapBack()
        guard panel.isVisible, let from = VSCodeWindows.targetFrame(size: barSize) else {
            updateVisibility()
            return
        }
        let place = cover.isVisible ? VSCodeWindows.flip(cover.frame).offsetBy(dx: -from.minX, dy: -from.minY) : nil
        let grab = mouseDownAt.flatMap { from.contains($0) ? $0 : nil }
        liveDrag = LiveDrag(from: from, cover: place, grab: grab, number: number, resizing: number == nil ? nil : false)
        let link = panel.displayLink(target: self, selector: #selector(dragStep))
        link.add(to: .main, forMode: .common)
        dragLink = link
    }

    // Each mouse move in a move drag. macOS moves the window by the same
    // amount as the mouse, so the bar moves at once. It does not wait to
    // see the window's new place, which comes a frame or more later.
    func dragMoved() {
        guard var drag = liveDrag, let grab = drag.grab else { return }
        findDraggedWindow(&drag)
        guard drag.resizing == false else {
            liveDrag = drag
            return
        }
        let m = VSCodeWindows.flip(NSEvent.mouseLocation)
        let t = ProcessInfo.processInfo.systemUptime
        if let last = drag.mouse, t - last.time > 0.001 {
            let dt = t - last.time
            let v = CGVector(dx: (m.x - last.point.x) / dt, dy: (m.y - last.point.y) / dt)
            // Smoothed, so one quick event does not make the cover jump.
            drag.velocity = CGVector(dx: (drag.velocity.dx + v.dx) / 2, dy: (drag.velocity.dy + v.dy) / 2)
        }
        drag.mouse = (m, t)
        var f = drag.from.offsetBy(dx: m.x - grab.x, dy: m.y - grab.y)
        // macOS keeps the title bar below the menu bar.
        if let s = VSCodeWindows.screen(at: m) { f.origin.y = max(f.minY, VSCodeWindows.visibleFrame(s).minY) }
        drag.mouseAt = Date()
        drag.last = f
        movePanels(window: f, drag: drag)
        liveDrag = drag
    }

    // On each screen refresh: the window's place from the window server.
    // It moves the bar in a resize, after the mouse stops, and after the
    // drop (macOS can tile the window then). It also corrects the bar when
    // macOS holds the window back from the mouse.
    @objc func dragStep(_ link: CADisplayLink) {
        guard var drag = liveDrag else { return }
        findDraggedWindow(&drag)
        // Not found: perhaps the user drags a window that is not in front.
        // Then the bar hides until the drag ends.
        if drag.number == nil && Date().timeIntervalSince(drag.startedAt) > 0.25 {
            stopDrag(restore: true)
            updateVisibility()
            return
        }
        let mouseMoves = drag.grab != nil && drag.resizing == false && NSEvent.pressedMouseButtons != 0
            && Date().timeIntervalSince(drag.mouseAt) < 0.05
        if !mouseMoves && drag.velocity != .zero {
            // The mouse stopped: the cover goes back to its drag size.
            drag.velocity = .zero
            drag.mouse = nil
            if let f = drag.last { movePanels(window: f, drag: drag) }
        }
        // Less than a point off is from rounding. Moving the bar for it makes it shake.
        if !mouseMoves, let n = drag.number, let f = VSCodeWindows.windowBounds(n),
           drag.last.map({ abs(f.minX - $0.minX) >= 1 || abs(f.minY - $0.minY) >= 1 || f.size != $0.size }) ?? true {
            drag.last = f
            movePanels(window: f, drag: drag)
        }
        liveDrag = drag
    }

    // The dragged window, and if the drag is a move or a resize. The window
    // changed before the drag started here, so its size tells which.
    func findDraggedWindow(_ drag: inout LiveDrag) {
        if drag.number == nil, let app = VSCodeWindows.app() {
            drag.number = VSCodeWindows.movingWindowNumber(app, from: drag.from)
        }
        if drag.resizing == nil, let n = drag.number, let f = VSCodeWindows.windowBounds(n) {
            drag.resizing = abs(f.width - drag.from.width) >= 1 || abs(f.height - drag.from.height) >= 1
        }
    }

    // The cover first: its gap shows VSCode's window buttons.
    func movePanels(window f: CGRect, drag: LiveDrag) {
        if let r = drag.cover {
            cover.setFrame(VSCodeWindows.flip(dragCover(r, drag.velocity).offsetBy(dx: f.minX, dy: f.minY)), display: true)
        }
        let g = VSCodeWindows.group(around: f, size: barSize)
        let bar = VSCodeWindows.barFrame(size: barSize, group: g)
        let p = panelFrame(bar)
        // Redraw only when the size changes. A move needs no redraw.
        panel.setFrame(p, display: p.size != panel.frame.size)
        corners.setFrame(VSCodeWindows.cornerFrame(bar: bar), display: false)
    }

    // The cover in a drag, on the window (AX coordinates, from its top-left
    // corner). The cover can be a frame or two behind the window, so it is
    // bigger: taller, to the edges of the title bar, and wider, into the
    // empty title bar on the right. It also grows toward where the window
    // moves, by as far as the window moves in 2 frames.
    func dragCover(_ r: CGRect, _ v: CGVector) -> CGRect {
        // The buttons are in the middle of the title bar. Below 4 pt from
        // the top, the cover would show outside the window's rounded corner.
        let top: CGFloat = 4, bottom = r.midY * 2 - 1
        var c = CGRect(x: r.minX, y: top, width: r.width + 32, height: max(bottom - top, r.height))
        let lead = 2 / CGFloat(panel.screen?.maximumFramesPerSecond ?? 60)
        let dx = min(max(v.dx * lead, -120), 120), dy = min(max(v.dy * lead, -120), 120)
        if dx > 0 { c.size.width += dx } else { c.origin.x += dx; c.size.width -= dx }
        if dy > 0 { c.size.height += dy } else { c.origin.y += dy; c.size.height -= dy }
        return c
    }

    // restore: the bar goes back to the group's place. Not when the group
    // follows the window: the bar then goes from the drag's end to the new
    // place, with no jump back between.
    func stopDrag(restore: Bool) {
        dragLink?.invalidate()
        dragLink = nil
        if liveDrag != nil {
            liveDrag = nil
            if restore { layoutPanels() }
        }
    }

    // True while a mouse button is down, or just after a click or a key
    // press. Then a window that moves is moved by the user.
    var userInput: Bool {
        NSEvent.pressedMouseButtons != 0
            || CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .leftMouseUp) < 1
            || CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown) < 1
    }

    func isNew(_ ax: AXUIElement) -> Bool {
        createdAt[AXKey(ax)].map { Date().timeIntervalSince($0) < 3 } ?? false
    }

    func wasFullScreen(_ ax: AXUIElement) -> Bool {
        fullScreenAt[AXKey(ax)].map { Date().timeIntervalSince($0) < 2 } ?? false
    }

    // Runs when the windows stop changing for a moment, so a resize or a
    // tile is done first.
    func scheduleSnapBack() {
        snapGeneration += 1
        let generation = snapGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.snapGeneration == generation else { return }
                self.snapBack()
            }
        }
    }

    // Waits while a mouse button is down, so a drag ends first, and a moment
    // after: macOS tiles a window dropped at the screen's edge just after
    // the drop. Our own place() also sends move and resize events. Those
    // windows are already next to the bar, so nothing happens.
    func snapBack() {
        // A slide sends move and resize events too. Wait until it ends.
        if NSEvent.pressedMouseButtons != 0 || animation != nil
            || CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .leftMouseUp) < 0.3 {
            scheduleSnapBack()
            return
        }
        let windows = changed
        let userMoved = moved
        changed = []
        moved = []
        dragging = false
        let now = Date()
        createdAt = createdAt.filter { now.timeIntervalSince($0.value) < 3 }
        fullScreenAt = fullScreenAt.filter { now.timeIntervalSince($0.value) < 2 }
        // A closed window has no frame.
        stuck.removeAll { VSCodeWindows.frame($0.window) == nil }
        if let ax = userMoved.last(where: { canFollow($0) && !wasFullScreen($0) }) {
            stopDrag(restore: false)
            follow(ax)
            return
        }
        stopDrag(restore: true)
        for ax in windows {
            guard VSCodeWindows.isStandard(ax), !VSCodeWindows.isMinimized(ax), !VSCodeWindows.isFullScreen(ax),
                  !VSCodeWindows.isArranged(ax, size: barSize), let before = VSCodeWindows.frame(ax),
                  !stuck.contains(where: { CFEqual($0.window, ax) && $0.frame == before }) else { continue }
            VSCodeWindows.place(ax, size: barSize, restore: false)
            stuck.removeAll { CFEqual($0.window, ax) }
            if !VSCodeWindows.isArranged(ax, size: barSize), let after = VSCodeWindows.frame(ax) {
                stuck.append((ax, after))
            }
        }
        updateVisibility()
    }

    // A window the group can follow: a normal window, not next to the bar now.
    func canFollow(_ ax: AXUIElement) -> Bool {
        VSCodeWindows.isStandard(ax) && !VSCodeWindows.isMinimized(ax) && !VSCodeWindows.isFullScreen(ax)
            && VSCodeWindows.frame(ax) != nil && !VSCodeWindows.isArranged(ax, size: barSize)
    }

    // The user moved or resized a VSCode window, or macOS tiled it. The bar
    // goes on the window's top or left, and the other windows go on top of
    // it. A tile is the place for the whole group, so the window gets
    // smaller to make room for the bar.
    func follow(_ ax: AXUIElement) {
        guard let w = VSCodeWindows.frame(ax), let old = VSCodeWindows.targetFrame(size: barSize),
              // The screen with the window's title bar. In a drag, the mouse is there.
              let screen = VSCodeWindows.screen(at: CGPoint(x: w.midX, y: w.minY + 10)) ?? VSCodeWindows.screen(for: w)
        else {
            applyGroup()
            return
        }
        let v = VSCodeWindows.visibleFrame(screen)
        // A shortcut, not the mouse: the last key press is after the last click.
        let up = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .leftMouseUp)
        let key = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
        let byKeyboard = NSEvent.pressedMouseButtons == 0 && key < 1.5 && key < up
        if byKeyboard && repeatRectangle(ax, w) { return }
        let resized = abs(w.width - old.width) >= 2 || abs(w.height - old.height) >= 2
        let distance = hypot(w.minX - old.minX, w.minY - old.minY)
        var g = VSCodeWindows.group(around: w, size: barSize)
        if resized && VSCodeWindows.isTile(w, on: v, parts: byKeyboard ? VSCodeWindows.thirds : VSCodeWindows.halves) {
            g = w
        } else if resized && VSCodeWindows.onTop && g.minY < v.minY {
            // Its top edge went too high for the bar. Its bottom edge stays.
            g = CGRect(x: w.minX, y: v.minY, width: w.width, height: w.maxY - v.minY)
        } else if resized && !VSCodeWindows.onTop && g.minX < v.minX {
            // Its left edge went too far left for the bar. Its right edge stays.
            g = CGRect(x: v.minX, y: w.minY, width: w.maxX - v.minX, height: w.height)
        } else if !resized, distance >= 40, let before = VSCodeWindows.groupFrame, VSCodeWindows.isFill(before) {
            // A drag of a group that fills its screen makes it smaller, like
            // a tiled macOS window. A short drag puts it back.
            g.size = freeSize ?? CGSize(width: v.width * 2 / 3, height: v.height * 3 / 4)
        }
        saveGroup(VSCodeWindows.fit(g, on: screen), animating: ax)
    }

    // Rectangle remembers the frame it gave a window. A repeated command
    // (Right Half again, to go to the next screen) works only while the
    // window still has that frame. The bar makes the window smaller, so
    // Rectangle forgets, and the repeat puts the window on the same half
    // again: the whole group's frame. Then ask Rectangle for the command
    // once more. Now the frame is the one it remembers, so it does what a
    // repeat does, with the user's Rectangle settings.
    func repeatRectangle(_ ax: AXUIElement, _ w: CGRect) -> Bool {
        guard let g = VSCodeWindows.groupFrame,
              abs(w.minX - g.minX) < 2, abs(w.minY - g.minY) < 2, abs(w.width - g.width) < 2, abs(w.height - g.height) < 2,
              !NSRunningApplication.runningApplications(withBundleIdentifier: "com.knollsoft.Rectangle").isEmpty,
              let s = VSCodeWindows.screen(for: g),
              let name = VSCodeWindows.rectangleCommand(g, on: VSCodeWindows.visibleFrame(s)),
              let url = URL(string: "rectangle://execute-action?name=\(name)") else { return false }
        // Once per place: if the repeat leaves the window there, do not ask again.
        if let last = lastRepeat, last.frame == g, Date().timeIntervalSince(last.at) < 2 { return false }
        lastRepeat = (g, Date())
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.open(url, configuration: config)
        // If Rectangle does nothing, the window goes back next to the bar.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let f = VSCodeWindows.frame(ax), abs(f.minX - g.minX) < 2, abs(f.minY - g.minY) < 2,
                      abs(f.width - g.width) < 2, abs(f.height - g.height) < 2 else { return }
                self.applyGroup(animating: ax)
            }
        }
        return true
    }

    // The user put the group in a new place. nil: it fills the bar's screen.
    // The bar's screen is the screen with the group.
    func saveGroup(_ g: CGRect?, animating ax: AXUIElement? = nil) {
        if let g, !VSCodeWindows.isFill(g) { freeSize = g.size }
        settings.group = g
        if let g, let id = VSCodeWindows.screen(for: g)?.displayUUID {
            settings.screen = id
            VSCodeWindows.screenId = id
        }
        applyGroup(animating: ax)
    }

    // The bar and the windows go to the saved place, fitted to the screens
    // connected now. If its screen is not connected, the group fills the
    // main screen until that screen comes back. animating: this window and
    // the bar slide there. The others go at once: they are behind it.
    func applyGroup(animating ax: AXUIElement? = nil) {
        finishAnimation()
        let oldBar = barStrip
        VSCodeWindows.group = settings.group.flatMap { VSCodeWindows.fit($0) }
        let newBar = VSCodeWindows.barFrame(size: barSize)
        guard let ax, let app = VSCodeWindows.app(), let from = VSCodeWindows.frame(ax),
              let to = VSCodeWindows.targetFrame(size: barSize),
              !VSCodeWindows.isMinimized(ax), !VSCodeWindows.isFullScreen(ax),
              differs(from, to) || (panel.isVisible && differs(oldBar, newBar)),
              let screen = VSCodeWindows.screen(for: to) ?? NSScreen.screens.first
        else {
            layoutPanels()
            VSCodeWindows.arrangeAll(size: barSize)
            updateVisibility()
            return
        }
        for w in VSCodeWindows.windows(app) where !CFEqual(w, ax) {
            VSCodeWindows.place(w, size: barSize, restore: false)
        }
        animation = GroupAnimation(
            window: ax, fromWindow: from, toWindow: to,
            // A hidden bar (after a drag it could not follow) shows at its new place.
            fromBar: panel.isVisible ? oldBar : newBar, toBar: newBar,
            cover: cover.isVisible ? VSCodeWindows.buttonsFrame(ax)?.insetBy(dx: -3, dy: -3) : nil)
        // The screen's display link, so it runs while the bar is hidden too.
        let link = screen.displayLink(target: self, selector: #selector(animationStep))
        link.add(to: .main, forMode: .common)
        animationLink = link
        animationStep(nil)
        updateVisibility()
    }

    func differs(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) >= 1 || abs(a.minY - b.minY) >= 1 || abs(a.width - b.width) >= 1 || abs(a.height - b.height) >= 1
    }

    // A slide of one window and the bar, for example after Rectangle fills
    // the screen with the window: the window gets smaller at the top or the
    // left, and the bar goes into the space.
    struct GroupAnimation {
        static let duration: TimeInterval = 0.2
        let window: AXUIElement
        let fromWindow: CGRect
        let toWindow: CGRect
        let fromBar: NSRect
        let toBar: NSRect
        // The cover's place on the window, from its top-left corner.
        let cover: CGRect?
        let start = ProcessInfo.processInfo.systemUptime
    }

    @objc func animationStep(_ link: CADisplayLink?) {
        guard let a = animation else { return }
        let t = min(1, (ProcessInfo.processInfo.systemUptime - a.start) / GroupAnimation.duration)
        // Ease out: fast at first, slow at the end.
        let e = 1 - pow(1 - t, 3)
        func mix(_ p: CGRect, _ q: CGRect) -> CGRect {
            CGRect(x: p.minX + (q.minX - p.minX) * e, y: p.minY + (q.minY - p.minY) * e,
                   width: p.width + (q.width - p.width) * e, height: p.height + (q.height - p.height) * e)
        }
        let w = mix(a.fromWindow, a.toWindow)
        if let r = a.cover { cover.setFrame(VSCodeWindows.flip(r.offsetBy(dx: w.minX, dy: w.minY)), display: true) }
        VSCodeWindows.setFrame(a.window, w)
        let bar = mix(a.fromBar, a.toBar)
        panel.setFrame(panelFrame(bar), display: true)
        corners.setFrame(VSCodeWindows.cornerFrame(bar: bar), display: true)
        if t >= 1 { finishAnimation() }
    }

    // Ends a slide now, with all at the new place.
    func finishAnimation() {
        guard let a = animation else { return }
        animationLink?.invalidate()
        animationLink = nil
        animation = nil
        VSCodeWindows.place(a.window, size: barSize, restore: false)
        layoutPanels()
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

    // The shortcut: VSCode's active window and the bar come to the front.
    func bringToFront() {
        VSCodeWindows.activateApp()
        panel.orderFrontRegardless()
    }

    // The tip goes just under its tab, on the screen with the bar.
    func showTip(_ tip: BarModel.Tip?) {
        guard let tip, panel.isVisible else {
            tipPanel.orderOut(nil)
            return
        }
        let host = NSHostingView(rootView: TipView(text: tip.text))
        let size = host.fittingSize
        var x = panel.frame.minX + tip.frame.minX
        if let s = panel.screen { x = min(x, s.visibleFrame.maxX - size.width - 4) }
        let top = panel.frame.maxY - tip.frame.maxY - 6
        tipPanel.contentView = host
        tipPanel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
        tipPanel.orderFrontRegardless()
    }

    func pick(_ row: Row) {
        if row.asleep {
            wake(row)
            return
        }
        model.activeId = row.id
        // Recolor the cover in the same step as the switch, so the old
        // window's color does not flash.
        coverRowId = row.id
        coverFocused = true
        recolorCover()
        if let ax = window(for: row) {
            VSCodeWindows.focus(ax, size: barSize)
        } else if let app = VSCodeWindows.app(), !row.window.empty {
            VSCodeWindows.openWithCLI(app, row.window)
        }
        // A Claude tab waits for you: its window brings that tab to the
        // front on each click. A "done" tab comes to the front once.
        if let session = row.tabSession {
            if row.state == .needsInput {
                requestTab(session, in: row.window)
            } else if row.state == .done, let at = row.tabSessionAt, shownDone[session] != at {
                shownDone[session] = at
                requestTab(session, in: row.window)
            }
        }
        restoreCursor()
    }

    // A VSCode window that comes to the front sets its own cursor, for
    // example the resize cursor of its edge, though the mouse is on the bar.
    // The bar sets its cursor again only when the mouse moves. So set it
    // again a few times while VSCode changes windows (focus() raises the
    // window again after 0.1 s).
    func restoreCursor() {
        for delay in [0.05, 0.15, 0.3, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.panel.isVisible, self.panel.frame.contains(NSEvent.mouseLocation) else { return }
                    (CursorState.shared.cursor ?? NSCursor.arrow).set()
                }
            }
        }
    }

    // Close a VSCode window. A sleeping row goes away.
    func closeWindow(_ row: Row) {
        if row.asleep {
            settings.sleeping.removeAll { $0.key == row.key }
            model.rows = allRows()
        } else {
            closeVSCodeWindow(row, show: true)
        }
    }

    // The window can stay behind another window. If it is still open a
    // moment later, it is probably asking to save files. show: then it comes
    // to the front to show the question.
    @discardableResult
    func closeVSCodeWindow(_ row: Row, show: Bool) -> Bool {
        guard let ax = window(for: row), VSCodeWindows.close(ax) else { return false }
        // Another VSCode window gets the focus.
        restoreCursor()
        if show {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, VSCodeWindows.frame(ax) != nil else { return }
                    self.pick(row)
                }
            }
        }
        return true
    }

    // A sleeping window: VSCode closed it to free its memory, and its row
    // stays. Not the last open window, because the bar hides while VSCode
    // has no windows. Then there is no row to click to wake the others.
    func canSleep(_ row: Row) -> Bool {
        !row.asleep && row.window.canReopen && model.rows.contains { $0.id != row.id && !$0.asleep }
    }

    // auto: the bar does it by itself, so a save question stays behind.
    func sleep(_ row: Row, auto: Bool = false) {
        guard canSleep(row), closeVSCodeWindow(row, show: !auto) else { return }
        settings.sleeping = settings.sleeping.filter { $0.key != row.key } + [SleepingWindow(row.window, at: Date())]
    }

    // VSCode opens the folder again, with the tabs it had.
    func wake(_ row: Row) {
        guard let s = settings.sleeping.first(where: { $0.key == row.key }), let target = s.target else { return }
        waking[s.key] = Date()
        wokenAt[s.key] = Date()
        VSCodeWindows.open(target)
        model.rows = allRows()
    }

    // Auto sleep: close the windows where nothing changed for the set time.
    // Not the window in use, and not a window with unsaved files, something that
    // runs in a terminal or a task, or a Claude session that works or waits
    // for you. A window from an old extension does not say, so it stays.
    // The bar finds a window by its title, so two windows with the same name
    // can be mixed up. They stay too, so the wrong one does not close.
    func autoSleep(now: Date = Date()) {
        wokenAt = wokenAt.filter { key, _ in model.rows.contains { $0.key == key } }
        guard settings.sleepAfterHours > 0, model.trusted, let active = model.activeId,
              model.rows.contains(where: { $0.id == active }) else { return }
        let limit = TimeInterval(settings.sleepAfterHours * 3600)
        let awake = model.rows.filter { !$0.asleep }
        for row in awake where row.id != active && row.window.unsaved == false && row.window.busy == false
            && row.state < .working && now.timeIntervalSince(lastUse(row)) >= limit
            && !awake.contains(where: { $0.id != row.id && $0.name == row.name }) {
            sleep(row, auto: true)
        }
    }

    // When the window was last used: the time its row shows. That is when
    // something changed in it (the extension keeps it from before the bar
    // started) or a Claude session had news. A focus with no change does not
    // count. Also when the bar woke it, so it does not sleep again at once.
    // A window not used for the set time before the bar started sleeps soon
    // after the bar starts. If none of these is known: when the window or
    // the bar started, whichever is later.
    func lastUse(_ row: Row) -> Date {
        let known = [row.window.activeAt, row.lastActivity, wokenAt[row.key]]
            .compactMap { $0 }
        return known.max() ?? max(row.window.startedAt ?? launchedAt, launchedAt)
    }

    // The rows of the open windows and of the sleeping ones, in the saved order.
    func allRows(now: Date = Date()) -> [Row] {
        let live = loadRows(now: now, idleAfter: settings.idleAfter)
        // A sleeping window is awake when VSCode opened it after its sleep.
        // A window still open 10 s after its sleep did not close (the user
        // said no to a save question), so it is awake too.
        let sleeping = settings.sleeping.filter { s in
            !live.contains { $0.key == s.key && (($0.window.startedAt ?? .distantPast) > s.sleptAt || now.timeIntervalSince(s.sleptAt) > 10) }
        }
        if sleeping != settings.sleeping { settings.sleeping = sleeping }
        waking = waking.filter { key, t in now.timeIntervalSince(t) < 30 && sleeping.contains { $0.key == key } }
        // While a window closes, its open row shows.
        let liveKeys = Set(live.map(\.key))
        let asleep = sleeping.filter { !liveKeys.contains($0.key) }.map { $0.row(waking: waking[$0.key] != nil, now: now) }
        return settings.ordered(live + asleep)
    }

    // Empty windows have no saved place.
    func move(_ from: String, _ to: String) {
        settings.move(from, to: to, visible: model.rows.filter { !$0.window.empty }.map(\.key))
        model.rows = settings.ordered(model.rows)
    }

    func arrangeAll() {
        VSCodeWindows.arrangeAll(size: barSize)
    }

    // Hide VSCode. The bar hides with it.
    func hideAll() {
        if model.settingsOpen { toggleSettings() }
        hideUntil = Date().addingTimeInterval(1.5)
        VSCodeWindows.hideApp()
        updateVisibility()
    }

    func resetOrder() {
        settings.resetOrder()
        model.rows = allRows()
    }

    // Settings need focus (color picker, drag and drop, shortcut keys).
    // On close, focus goes back to VSCode. The panel grows down to hold
    // the settings under the bar.
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
        if VSCodeWindows.onTop {
            model.settingsOpen = opening
            layoutPanels()
        } else {
            // On the left, the settings slide up inside the bar.
            withAnimation(.easeInOut(duration: 0.2)) { model.settingsOpen = opening }
        }
    }

    func tick() {
        model.trusted = AXIsProcessTrusted()
        watcher.update()
        // The folder appears when the extension first runs.
        if windowFiles == nil {
            windowFiles = FolderWatcher(path: statusDir() + "/windows") { [weak self] in self?.windowFilesChanged() }
        }
        model.rows = allRows()
        linkEmptyWindow()
        ticks += 1
        if ticks % 3 == 1 { refreshArrangedRows() }
        updateActive()
        // Often, so windows not used for the set time sleep soon after the bar starts.
        if ticks % 5 == 0 { autoSleep() }
        updateVisibility()
    }

    // A window file changed, for example new title bar colors while a VS
    // Code modal opens. Recolor the cover at once, then check the rest.
    func windowFilesChanged() {
        model.rows = allRows()
        linkEmptyWindow()
        recolorCoverNow()
        updateSoon()
    }

    var vscodeInFront: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == vscodeBundleId
    }

    // The cover's color from what the bar already knows. No calls to VSCode.
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

    // Each VSCode window next to the bar and its row, for quick recolors.
    func refreshArrangedRows() {
        guard model.trusted, let app = VSCodeWindows.app() else {
            arrangedRows = [:]
            return
        }
        var map: [AXKey: String] = [:]
        for ax in VSCodeWindows.windows(app) where VSCodeWindows.isArranged(ax, size: barSize) {
            if let id = row(for: ax)?.id { map[AXKey(ax)] = id }
        }
        arrangedRows = map
    }

    // Highlight the row of the focused VSCode window.
    func updateActive() {
        guard model.trusted,
              let app = VSCodeWindows.app(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              let ax = VSCodeWindows.focusedWindow(app) else { return }
        model.activeId = row(for: ax)?.id
    }

    // The row of a VSCode window: a known empty window, or the folder row
    // that best matches it.
    func row(for ax: AXUIElement) -> Row? {
        if let id = emptyRows[AXKey(ax)], let row = model.rows.first(where: { $0.id == id }) { return row }
        return folderRow(for: ax)
    }

    func folderRow(for ax: AXUIElement) -> Row? {
        model.rows
            .filter { !$0.window.empty && !$0.asleep }
            .map { ($0, VSCodeWindows.score(ax, $0.window)) }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }?.0
    }

    // The VSCode window of a row. For an empty row that the bar does not
    // know yet: a window that no other row has.
    func window(for row: Row) -> AXUIElement? {
        guard !row.asleep, let app = VSCodeWindows.app() else { return nil }
        guard row.window.empty else { return VSCodeWindows.find(app, row.window) }
        if let key = emptyRows.first(where: { $0.value == row.id })?.key { return key.element }
        guard let ax = VSCodeWindows.windows(app).first(where: { self.row(for: $0) == nil }) else { return nil }
        emptyRows[AXKey(ax)] = row.id
        return ax
    }

    // The extension in an empty window says when its window gets the focus.
    // Then the focused VSCode window is that row's window. Only news from
    // after the last focus change counts, so an old focus does not link the
    // wrong window. The tolerance is for the order of the two messages.
    func linkEmptyWindow() {
        let rows = model.rows
        // Forget rows and windows that are gone.
        emptyRows = emptyRows.filter { key, id in
            rows.contains { $0.id == id && $0.window.empty } && VSCodeWindows.frame(key.element) != nil
        }
        guard model.trusted, vscodeInFront,
              let row = rows.filter({ $0.window.empty && $0.window.focusedAt != nil })
                  .max(by: { $0.window.focusedAt! < $1.window.focusedAt! }),
              row.window.focusedAt! > focusChangedAt.addingTimeInterval(-0.5),
              let app = VSCodeWindows.app(), let ax = VSCodeWindows.focusedWindow(app),
              VSCodeWindows.isStandard(ax), folderRow(for: ax) == nil else { return }
        emptyRows = emptyRows.filter { $0.value != row.id }
        emptyRows[AXKey(ax)] = row.id
    }

    // Where the bar windows go. Quick: no calls to VSCode.
    enum Stacking: Equatable {
        case off
        // Over all windows, while VSCode or the bar is in front.
        case floating
        // Just above this VSCode window, while another app is in front, so
        // that app's windows can cover the bar like they cover VSCode.
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

    // Show the bar while VSCode (or the bar itself) is in front, or while a
    // VSCode window is on screen behind another app. At least one VSCode
    // window must not be minimized.
    func updateVisibility() {
        var stacking = self.stacking
        if Date() < hideUntil || (dragging && liveDrag == nil) { stacking = .off }
        // Without Accessibility access, keep the bar so it can ask for it.
        if stacking != .off, model.trusted, let app = VSCodeWindows.app(), !VSCodeWindows.hasVisibleWindow(app) {
            stacking = .off
        }
        // A VSCode window in full screen, for example in Zen Mode, has all of
        // the screen. The bar hides until it leaves full screen.
        if stacking != .off, model.trusted, vscodeInFront, let app = VSCodeWindows.app(),
           let ax = VSCodeWindows.focusedWindow(app), VSCodeWindows.fillsScreen(ax) {
            stacking = .off
        }
        stack([panel, corners], stacking)
        // The cover goes just above the corner strip.
        if case .above = stacking { stacking = .above(corners.windowNumber) }
        // In a live drag or a slide, the cover moves with the window. Do not put it back.
        if liveDrag != nil || animation != nil {
            if cover.isVisible { stack([cover], stacking) }
            return
        }
        updateCover(stacking)
    }

    // The cover goes over the window buttons of the front VSCode window
    // next to the bar. Its color is that window's title bar color, worked out
    // by the extension from its theme and settings (shaded while a VSCode
    // modal is open): the focused color, or the other one while something
    // else has focus.
    func updateCover(_ stacking: Stacking) {
        var frame: NSRect?
        var color = barNSColor
        if stacking != .off, model.trusted, let app = VSCodeWindows.app(),
           let ax = VSCodeWindows.frontArranged(app, size: barSize), let buttons = VSCodeWindows.buttonsFrame(ax) {
            frame = VSCodeWindows.coverFrame(size: barSize, buttons: buttons)
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

    // The bar's size or place changed: the bar and the windows go to their new place.
    func barChanged() {
        model.tip = nil
        setCornerPieces()
        layoutPanels()
        VSCodeWindows.arrangeAll(size: barSize)
        updateVisibility()
    }

    // The corner strip's pieces for the bar's place.
    func setCornerPieces() {
        corners.contentView = VSCodeWindows.onTop
            ? NSHostingView(rootView: AnyView(TopCornerPieces(radius: windowRadius, join: model.join)))
            : NSHostingView(rootView: AnyView(CornerPieces(radius: windowRadius, join: model.join)))
    }

    // The bar across the top or down the left of the group, and the corner strip next to it.
    func layoutPanels() {
        let bar = VSCodeWindows.barFrame(size: barSize)
        panel.setFrame(panelFrame(bar), display: true)
        corners.setFrame(VSCodeWindows.cornerFrame(bar: bar), display: true)
    }

    // The panel for a bar frame. On top: the bar, and room under it for the
    // settings while they are open. The empty part is clear, and clicks on
    // it go through to VSCode. On the left, the settings are in the bar.
    func panelFrame(_ bar: NSRect) -> NSRect {
        guard VSCodeWindows.onTop, model.settingsOpen else { return bar }
        return NSRect(x: bar.minX, y: bar.minY - settingsHeight, width: bar.width, height: bar.height + settingsHeight)
    }

    // The bar's part of the panel, without the settings.
    var barStrip: NSRect {
        let f = panel.frame
        guard VSCodeWindows.onTop else { return f }
        return NSRect(x: f.minX, y: f.maxY - barSize, width: f.width, height: barSize)
    }

    // VSCode came to the front or went behind: the window under the cover
    // gains or loses focus. Restack at once, before the slower full update,
    // so VSCode's own buttons do not show as its windows come to the front.
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
        applyGroup()
    }
}
