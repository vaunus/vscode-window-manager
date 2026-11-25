import AppKit
import SwiftUI
import UniformTypeIdentifiers

// An sRGB color from a hex value, for example 0x181818.
func hexColor(_ hex: Int) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

// Bar background, like VSCode's dark theme.
let barHex = 0x181818
let barNSColor = hexColor(barHex)
let barColor = Color(nsColor: barNSColor)
// Window border, like macOS in dark mode.
let borderColor = Color(nsColor: hexColor(0x464646))
// Claude's brand orange, for the working spinner and the "needs you" text.
let claudeOrange = Color(nsColor: hexColor(0xD97757))
// VSCode's badge blue, as on the Source Control icon.
let badgeBlue = Color(nsColor: hexColor(0x0078D4))
// Height of the bar across the top of the VSCode windows. Small, so the
// windows keep most of the screen.
let barHeight: CGFloat = 30
// Room under the bar for the settings while they are open.
let settingsHeight: CGFloat = 340
// Space between the top of the bar and the tabs.
let tabTop: CGFloat = 4
// Each tab gets an equal share of the bar, within these widths. Past the
// minimum, the tabs scroll.
let minTabWidth: CGFloat = 110
let maxTabWidth: CGFloat = 220
// Space between two tabs.
let rowSpacing: CGFloat = 2
// Space left of a tab's status dot. It has room for the color line.
let rowLeading: CGFloat = 9
// Radius of the inner corners where the selected tab joins the VSCode
// window. The tabs have this much room at the ends of the list.
let tabJoinRadius: CGFloat = 6

// The bar's shape: rounded on top, square where it meets VSCode.
let barShape = UnevenRoundedRectangle(topLeadingRadius: windowRadius, topTrailingRadius: windowRadius, style: .circular)

// The bar's border: left, top and right. The bottom is open, where the bar
// joins VSCode. The lines are 1 pt wide, inside the rect.
struct BarOutline: Shape {
    func path(in rect: CGRect) -> Path {
        let r = windowRadius - 0.5
        let l = rect.minX + 0.5, t = rect.minY + 0.5, rr = rect.maxX - 0.5, b = rect.maxY
        var p = Path()
        p.move(to: CGPoint(x: l, y: b))
        p.addArc(tangent1End: CGPoint(x: l, y: t), tangent2End: CGPoint(x: rr, y: t), radius: r)
        p.addArc(tangent1End: CGPoint(x: rr, y: t), tangent2End: CGPoint(x: rr, y: b), radius: r)
        p.addLine(to: CGPoint(x: rr, y: b))
        return p
    }
}

// The selected row's color: the title bar color of its window, focused or
// not, the same as the box over the window buttons. VSCode uses this color
// at the window's edges too, so the row looks like part of the window.
// The bar color for a window with no title bar color.
func tabColor(_ w: VSWindow, focused: Bool) -> Int {
    (focused ? w.titleBarColor : w.titleBarInactiveColor ?? w.titleBarColor) ?? barHex
}

// True for a light color, which needs dark text.
func isLight(_ hex: Int) -> Bool {
    let r = Double((hex >> 16) & 0xFF), g = Double((hex >> 8) & 0xFF), b = Double(hex & 0xFF)
    return (0.299 * r + 0.587 * g + 0.114 * b) / 255 > 0.6
}

@MainActor
final class BarModel: ObservableObject {
    @Published var rows: [Row] = []
    @Published var activeId: String?
    // True while the window under the cover has the focus. Then its title
    // bar shows the focused color.
    @Published var focused = false
    @Published var trusted = AXIsProcessTrusted()
    @Published var settingsOpen = false
    // The tip under the tab the mouse rests on. The app shows it in its own
    // panel: .help() tooltips do not show in the bar's panel.
    @Published var tip: Tip?
    let join = TabJoin()

    struct Tip: Equatable {
        let rowId: String
        let text: String
        // The tab, in the bar window (top-left origin).
        let frame: CGRect
    }
}

// The part of the selected row that goes over the VSCode window's border.
// Its own object, so the bar does not redraw when only this changes.
@MainActor
final class TabJoin: ObservableObject {
    // In the bar window (top-left origin): the tab's left and right, and the
    // left and right of the list, where the tab shows. Then the color.
    struct Span: Equatable {
        let left: CGFloat
        let right: CGFloat
        let listLeft: CGFloat
        let listRight: CGFloat
        let color: Int
    }

    @Published var span: Span?
}

// The selected tab's outline: the top of a rounded rectangle, joined to
// the VSCode window's border by a rounded inner corner on the left and the
// right. The window starts at the bottom edge of the rect. The inner
// corners go outside the rect: left of it, right of it, and 1 pt down,
// over the window's border. The lines are 1 pt wide, on whole points.
// fill: the area inside the outline, down to the bottom of the border.
struct TabShape: Shape {
    var fill = false

    func path(in rect: CGRect) -> Path {
        let r = tabJoinRadius
        // The outer corner radius at the center of the line.
        let c: CGFloat = 5.5
        // Line centers: the window's border, and the tab's left, right and top.
        let e = rect.maxY + 0.5, l = rect.minX + 0.5, rr = rect.maxX - 0.5, t = rect.minY + 0.5
        var p = Path()
        p.move(to: CGPoint(x: l - r, y: e))
        p.addArc(tangent1End: CGPoint(x: l, y: e), tangent2End: CGPoint(x: l, y: t), radius: r)
        p.addArc(tangent1End: CGPoint(x: l, y: t), tangent2End: CGPoint(x: rr, y: t), radius: c)
        p.addArc(tangent1End: CGPoint(x: rr, y: t), tangent2End: CGPoint(x: rr, y: e), radius: c)
        p.addArc(tangent1End: CGPoint(x: rr, y: e), tangent2End: CGPoint(x: rr + r, y: e), radius: r)
        if fill {
            p.addLine(to: CGPoint(x: rr + r, y: e + 0.5))
            p.addLine(to: CGPoint(x: l - r, y: e + 0.5))
            p.closeSubpath()
        }
        return p
    }
}

// The selected row's frame in the bar window.
struct TabFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = value ?? nextValue()
    }
}

struct BarActions {
    let close: () -> Void
    let pick: (Row) -> Void
    let closeWindow: (Row) -> Void
    let sleep: (Row) -> Void
    let canSleep: (Row) -> Bool
    let newWindow: () -> Void
    let move: (String, String) -> Void
    let toggleSettings: () -> Void
    let arrangeAll: () -> Void
    let hideAll: () -> Void
    let resetOrder: () -> Void
    let clearHotKey: () -> Void
}

// One star glyph, centered in the status dot's space. At 16 pt it is as
// wide as that space. fixedSize keeps the frame from cutting it.
struct Star: View {
    let glyph: String
    var color = Color.primary

    var body: some View {
        Text(glyph).font(.system(size: 16, weight: .bold)).foregroundStyle(color)
            .fixedSize()
            .frame(width: 10, height: 10)
    }
}

// The star grows and shrinks, like Claude Code's spinner in the terminal.
// The same glyphs, out and back. Slower than the terminal, which is
// too busy for a small icon: one step each 200 ms.
struct Spinner: View {
    static let frames: [String] = {
        let grow = ["·", "✢", "✳", "✶", "✻", "✽"]
        return grow + grow.reversed()
    }()
    static let step = 0.2

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.step)) { context in
            let n = Int(context.date.timeIntervalSinceReferenceDate / Self.step)
            Star(glyph: Self.frames[n % Self.frames.count], color: claudeOrange)
        }
    }
}

struct StatusDot: View {
    let state: ClaudeState
    var quiet = false
    var activity = WindowActivity.none

    var body: some View {
        if activity != .none {
            // The window's own work: like the idle dot, but solid and bright.
            Circle().fill(Color.primary).frame(width: 6, height: 6)
                .frame(width: 9, height: 9)
        } else {
            claudeDot
        }
    }

    @ViewBuilder
    private var claudeDot: some View {
        switch state {
        case .needsInput:
            Circle().fill(Color.blue).frame(width: 9, height: 9)
        case .working:
            if quiet {
                Star(glyph: "✻").opacity(0.4)
            } else {
                Spinner()
            }
        case .done:
            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                .foregroundStyle(quiet ? Color.secondary : Color.green)
        case .idle, .none:
            // A small faint dot. The outer frame keeps the same space as the other states.
            Circle().fill(Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                .frame(width: 9, height: 9)
        }
    }
}

// The number of uncommitted changes: white on a blue circle, like the
// number on VSCode's Source Control icon. A pill for two digits or more.
struct ChangesBadge: View {
    let count: Int

    var body: some View {
        Text(label)
            .font(.system(size: 9).monospacedDigit())
            .foregroundStyle(Color.white)
            .padding(.horizontal, 4)
            .frame(minWidth: 8, minHeight: 8)
            .background(Capsule().fill(badgeBlue))
            .fixedSize()
            // 1 pt above and below the line, so the row keeps its height.
            .padding(.vertical, -1)
    }

    // Like VSCode: 1K, 1K+ and so on above 999.
    private var label: String {
        guard count > 999 else { return "\(count)" }
        let k = count / 1000
        return k > 99 ? "99K+" : count % 1000 == 0 ? "\(k)K" : "\(k)K+"
    }
}

struct ColorGrid: View {
    @Binding var selected: String?
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(18), spacing: 6), count: 6), spacing: 6) {
                ForEach(rowColors) { c in
                    Circle()
                        .fill(c.color)
                        .frame(width: 18, height: 18)
                        // Just outside the swatch, so it shows on the white one too.
                        .overlay(Circle().strokeBorder(Color.primary, lineWidth: selected == c.name ? 1.5 : 0).padding(-3))
                        .contentShape(Circle())
                        .cursor(.pointingHand)
                        .onTapGesture {
                            selected = c.name
                            close()
                        }
                        .help(c.name)
                }
            }
            Button("No color") {
                selected = nil
                close()
            }
            .font(.system(size: 11))
        }
        .padding(10)
    }
}

// One VSCode window as a tab: status, name and change count on one line.
// The branch and the Claude status are in the tooltip.
struct RowView: View {
    let row: Row
    // The tab color (0xRRGGBB) of the selected row. Nil for other rows.
    let tab: Int?
    let color: Color?
    let editing: Bool
    @Binding var colorName: String?
    let onPick: () -> Void
    // Shows or hides this tab's tip.
    let showTip: (BarModel.Tip?) -> Void
    @State private var picking = false
    @State private var hovering = false
    @State private var frame = CGRect.zero
    // The mouse is on the color button.
    @State private var paletteHovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Group {
                if editing {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                } else if row.asleep {
                    Image(systemName: "moon.zzz").font(.system(size: 11))
                        .foregroundStyle(Color.secondary)
                } else {
                    StatusDot(state: row.state, quiet: row.quiet, activity: row.activity)
                }
            }
            .frame(width: 12, height: 15)

            Text(row.name)
                .font(.system(size: 12))
                .foregroundStyle(row.state == .needsInput ? claudeOrange : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if editing {
                paletteButton
            } else if row.window.changes > 0 {
                ChangesBadge(count: row.window.changes)
            }
        }
        .padding(.leading, rowLeading)
        .padding(.trailing, 6)
        .frame(maxHeight: .infinity)
        // A sleeping window's tab is dim. Its color line is dim too: see background.
        .opacity(row.asleep ? 0.5 : 1)
        // Dark text on a light tab.
        .environment(\.colorScheme, tab.map(isLight) == true ? .light : .dark)
        .background { background }
        .contentShape(Rectangle())
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        .onHover { h in
            hovering = h
            guard h else {
                showTip(nil)
                return
            }
            // A short wait, like a tooltip, so a mouse that only passes over does not open it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if hovering, !picking { showTip(BarModel.Tip(rowId: row.id, text: tipText, frame: frame)) }
            }
        }
        // The drag hand while the settings are open, but not on the color
        // button. The tab's cursor wins over the button's own cursor.
        .cursor(editing && !paletteHovering ? .openHand : .pointingHand)
        // Settings open: a click picks a color. Closed: a click goes to the window.
        .onTapGesture {
            showTip(nil)
            if editing { picking = true } else { onPick() }
        }
        .popover(isPresented: $picking, arrowEdge: .bottom) {
            ColorGrid(selected: $colorName, close: { picking = false })
        }
    }

    private var tipText: String {
        if editing { return "Drag to reorder. Click to set a color." }
        let branch = row.window.empty ? "no folder" : row.branch.map { "Branch: \($0)" } ?? "no repo"
        let changes = row.window.changes > 0 ? "\(row.window.changes) uncommitted changes" : ""
        return ([row.name] + row.window.rawFolders + [branch, changes, statusHelp, row.asleep ? "Click to wake." : ""])
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    // For example "done · 5m". A running command says so, because it does
    // not end by itself.
    private var statusHelp: String {
        if row.text.isEmpty { return "no session" }
        return row.activity == .terminal ? "\(row.text) · terminal" : row.text
    }

    private var paletteButton: some View {
        Button { picking = true } label: {
            Image(systemName: "paintpalette").font(.system(size: 10))
        }
        .buttonStyle(RowIconButtonStyle())
        .onHover { paletteHovering = $0 }
        .help("Set a color")
    }

    // The selected tab is part of its VSCode window, like an index tab: down
    // to the bottom of the bar, where it joins the window with rounded inner
    // corners. A line in the window border color goes around it, so the tab
    // shows when the window is the same color as the bar. The parts over the
    // window's border are outside the bar. The corner strip draws them.
    private var background: some View {
        ZStack(alignment: .leading) {
            if let tab {
                TabShape(fill: true).fill(Color(nsColor: hexColor(tab)))
                TabShape().stroke(borderColor, lineWidth: 1)
            } else {
                // The tab under the mouse is a little lighter.
                UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6, style: .circular)
                    .fill(Color.white.opacity(hovering ? 0.06 : 0))
            }
            // A row's color is only this line.
            if let color {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .frame(width: 3)
                    .padding(.vertical, 5)
                    .padding(.leading, 2)
                    .opacity(row.asleep ? 0.5 : 1)
            }
        }
    }
}

// Reorders rows while one is dragged over another.
struct ReorderDrop: DropDelegate {
    let target: String
    @Binding var dragging: String?
    let move: (String, String) -> Void

    func dropEntered(info: DropInfo) {
        if let d = dragging, d != target { move(d, target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

struct SettingsDrawer: View {
    @ObservedObject var settings: Settings
    @ObservedObject var recorder: ShortcutRecorder
    @ObservedObject var loginItem: LoginItem
    let actions: BarActions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Settings").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(action: actions.toggleSettings) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(IconButtonStyle())
                .help("Close settings")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Bring to front").font(.system(size: 11))
                HStack(spacing: 4) {
                    Button(recorder.recording ? "Press keys…" : (settings.hotKey?.label ?? "Set shortcut")) {
                        recorder.recording ? recorder.stop() : recorder.start()
                    }
                    .controlSize(.small)
                    if settings.hotKey != nil && !recorder.recording {
                        Button(action: actions.clearHotKey) {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.secondary)
                        .cursor(.pointingHand)
                        .help("Remove shortcut")
                    }
                }
                if let error = recorder.error {
                    Text(error).font(.system(size: 10)).foregroundStyle(Color.red)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Open at login", isOn: Binding(
                    get: { loginItem.enabled || loginItem.needsApproval },
                    set: { loginItem.set($0) }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .controlSize(.small)
                if loginItem.needsApproval {
                    Button("Allow in System Settings", action: loginItem.openSystemSettings)
                        .buttonStyle(.link)
                        .font(.system(size: 10))
                }
                if let error = loginItem.error {
                    Text(error).font(.system(size: 10)).foregroundStyle(Color.red)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                titleWithInfo("Tabs idle after",
                              info: "After a change, a tab shows working for this time, then idle. A green done tick turns grey after this time too.")
                choicePicker("Window idle after", Settings.idleChoices, $settings.idleAfterMinutes) { durationLabel(minutes: $0) }
            }

            VStack(alignment: .leading, spacing: 4) {
                titleWithInfo("Tabs sleep after",
                              info: "Closes idle VSCode windows to free system memory. Active terminals or Claude sessions prevent windows from sleeping.")
                choicePicker("Sleep windows after", Settings.sleepChoices, $settings.sleepAfterHours) { durationLabel(minutes: $0 * 60) }
            }

            VStack(alignment: .leading, spacing: 4) {
                Button("Reset tab order", action: actions.resetOrder)
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(barColor))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(borderColor, lineWidth: 1))
    }

    // A setting's title, and an info icon that shows the explanation on hover.
    private func titleWithInfo(_ title: String, info: String) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 11))
            InfoIcon(text: info)
        }
    }

    // A dropdown with a list of times.
    private func choicePicker(_ title: String, _ choices: [Int], _ value: Binding<Int>, label: @escaping (Int) -> String) -> some View {
        Picker(title, selection: value) {
            ForEach(choices, id: \.self) { Text(label($0)).tag($0) }
        }
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
    }
}

// An info icon. Its text shows in a popover while the mouse is on the icon.
// Not .help(): those tooltips do not show in the bar's panel.
struct InfoIcon: View {
    let text: String
    @State private var hovering = false
    @State private var showing = false

    var body: some View {
        Image(systemName: "info.circle")
            .font(.system(size: 10))
            .foregroundStyle(hovering ? Color.primary : Color.secondary)
            .contentShape(Rectangle())
            .onHover { h in
                hovering = h
                guard h else {
                    showing = false
                    return
                }
                // A short wait, like a tooltip, so a mouse that only passes over does not open it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if hovering { showing = true }
                }
            }
            .popover(isPresented: $showing, arrowEdge: .leading) {
                Text(text)
                    .font(.system(size: 11))
                    .frame(width: 200, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    // In a shorter popover, macOS joins the point to the
                    // rounded corners, so it looks large and round. At this
                    // height it is small and sharp, like the color picker's.
                    .frame(minHeight: 60)
            }
    }
}

// A time for a setting: 5m, 4h, 1d. 0 is "Never".
func durationLabel(minutes m: Int) -> String {
    if m == 0 { return "Never" }
    if m % (24 * 60) == 0 { return "\(m / (24 * 60))d" }
    if m % 60 == 0 { return "\(m / 60)h" }
    return "\(m)m"
}

struct BarView: View {
    @ObservedObject var model: BarModel
    @ObservedObject var settings: Settings
    @ObservedObject var recorder: ShortcutRecorder
    @ObservedObject var loginItem: LoginItem
    let actions: BarActions
    @State private var dragging: String?
    @State private var tabFrame: CGRect?
    @State private var listFrame = CGRect.zero

    var body: some View {
        // The bar on top. While the settings are open, the panel is taller
        // and they show under the bar, on the right, below the gear button.
        VStack(spacing: 0) {
            bar
            if model.settingsOpen {
                HStack {
                    Spacer(minLength: 0)
                    SettingsDrawer(settings: settings, recorder: recorder, loginItem: loginItem, actions: actions)
                        .frame(width: 250)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Clear of the corner piece at VSCode's top-right corner.
                .padding(.trailing, windowRadius + 4)
            }
            Spacer(minLength: 0)
        }
        .cursorRoot()
        .onChange(of: joinSpan, initial: true) { _, span in model.join.span = span }
    }

    private var bar: some View {
        HStack(spacing: 0) {
            // Same look as the buttons on a macOS window.
            WindowButtons(close: actions.close, minimize: actions.hideAll)
                .padding(.leading, 12)
                .padding(.trailing, 8)

            if !model.trusted {
                Button("Allow Accessibility") {
                    let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                    if let u = URL(string: url) { NSWorkspace.shared.open(u) }
                }
                .font(.system(size: 11))
                .controlSize(.small)
                .padding(.trailing, 8)
            }

            GeometryReader { g in
                let w = tabWidth(available: g.size.width)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: rowSpacing) {
                        ForEach(model.rows) { row in
                            rowView(row, width: w)
                        }
                        if model.rows.isEmpty {
                            Text("No VSCode windows").font(.system(size: 11)).foregroundStyle(Color.secondary)
                                .frame(height: barHeight - tabTop)
                        }
                        Button(action: actions.newWindow) {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(IconButtonStyle())
                        .frame(height: barHeight - tabTop)
                        .help("Open a new VSCode window. Then pick a folder on its Welcome page.")
                    }
                    // Room for the selected tab's inner corners at the ends.
                    .padding(.horizontal, tabJoinRadius)
                    .frame(height: barHeight, alignment: .bottom)
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { listFrame = $0 }
            .onPreferenceChange(TabFrameKey.self) { tabFrame = $0 }

            Button(action: actions.toggleSettings) {
                Image(systemName: model.settingsOpen ? "xmark" : "gearshape")
            }
            .buttonStyle(IconButtonStyle())
            .help(model.settingsOpen ? "Close settings" : "Settings")
            .padding(.leading, 4)
            .padding(.trailing, 8)
        }
        .frame(maxWidth: .infinity, minHeight: barHeight, maxHeight: barHeight)
        .background(barColor)
        .clipShape(barShape)
        .overlay { BarOutline().stroke(borderColor, lineWidth: 1) }
        .contentShape(Rectangle())
        .contextMenu { BarMenuItems(actions: actions) }
    }

    // An equal share of the list for each tab, within the set widths. The
    // add button takes 24 pt.
    private func tabWidth(available: CGFloat) -> CGFloat {
        let n = CGFloat(max(model.rows.count, 1))
        let room = available - 2 * tabJoinRadius - 24 - rowSpacing * n
        return min(max(room / n, minTabWidth), maxTabWidth)
    }

    // Where the selected tab meets the VSCode window. Nil while the tab and
    // its inner corners are scrolled out of the list.
    private var joinSpan: TabJoin.Span? {
        guard let tabFrame, let row = model.rows.first(where: { $0.id == model.activeId }),
              tabFrame.maxX + tabJoinRadius > listFrame.minX, tabFrame.minX - tabJoinRadius < listFrame.maxX else { return nil }
        return TabJoin.Span(left: tabFrame.minX, right: tabFrame.maxX, listLeft: listFrame.minX, listRight: listFrame.maxX,
                            color: tabColor(row.window, focused: model.focused))
    }

    @ViewBuilder
    private func rowView(_ row: Row, width: CGFloat) -> some View {
        let active = row.id == model.activeId
        let item = RowView(
            row: row,
            tab: active ? tabColor(row.window, focused: model.focused) : nil,
            color: row.window.empty ? nil : rowColor(settings.colors[row.key]),
            // An empty window has no saved place or color, so it stays a
            // normal tab while the settings are open.
            editing: model.settingsOpen && !row.window.empty,
            colorName: Binding(
                get: { settings.colors[row.key] },
                set: { settings.colors[row.key] = $0 }
            ),
            onPick: { actions.pick(row) },
            showTip: { tip in
                // A hide only for this tab's own tip: the next tab's can already show.
                if let tip { model.tip = tip } else if model.tip?.rowId == row.id { model.tip = nil }
            }
        )
        .frame(width: width, height: barHeight - tabTop)
        .background {
            if active {
                GeometryReader { g in
                    Color.clear.preference(key: TabFrameKey.self, value: g.frame(in: .global))
                }
            }
        }
        // A tab's menu replaces the bar's menu. It has only the tab's items.
        .contextMenu {
            if row.asleep {
                Button("Wake Window") { actions.pick(row) }
                Button("Remove") { actions.closeWindow(row) }
            } else {
                if row.window.canReopen {
                    Button("Sleep Window") { actions.sleep(row) }
                        .disabled(!actions.canSleep(row))
                }
                Button("Close Window") { actions.closeWindow(row) }
            }
        }
        if model.settingsOpen && !row.window.empty {
            item
                .onDrag {
                    dragging = row.key
                    return NSItemProvider(object: row.key as NSString)
                }
                .onDrop(of: [UTType.text], delegate: ReorderDrop(target: row.key, dragging: $dragging) { from, to in
                    withAnimation(.easeInOut(duration: 0.15)) { actions.move(from, to) }
                })
        } else {
            item
        }
    }
}

// The bar's right-click menu.
struct BarMenuItems: View {
    let actions: BarActions

    var body: some View {
        Button("Arrange All Windows", action: actions.arrangeAll)
        Button("Hide All VSCode Windows", action: actions.hideAll)
        Divider()
        Button("Quit VSCode Window Manager") { NSApp.terminate(nil) }
    }
}

// Close and minimize, like the buttons on a macOS window. The symbols show
// while the mouse is over the buttons.
struct WindowButtons: View {
    let close: () -> Void
    let minimize: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: close) { light(0xFF5F57, "xmark") }
                .help("Close the bar. VSCode windows stay open.")
            Button(action: minimize) { light(0xFEBC2E, "minus") }
                .help("Hide all VSCode windows. Click VSCode in the Dock to bring them back.")
        }
        .buttonStyle(WindowButtonStyle())
        .onHover { hovering = $0 }
    }

    private func light(_ hex: Int, _ symbol: String) -> some View {
        Circle()
            .fill(Color(nsColor: hexColor(hex)))
            .frame(width: 12, height: 12)
            .overlay {
                if hovering {
                    Image(systemName: symbol)
                        .font(.system(size: 8, weight: .black))
                        .foregroundStyle(Color.black.opacity(0.65))
                }
            }
    }
}

// Darker while pressed, like the macOS window buttons.
struct WindowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(Circle().fill(Color.black.opacity(configuration.isPressed ? 0.25 : 0)))
            .contentShape(Circle())
    }
}

// Icon button: 24x24 click area, lighter rounded square on hover.
// Disabled: dim, no hover square, arrow cursor.
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration)
    }

    private struct IconButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            let hot = hovering && isEnabled
            configuration.label
                .font(.system(size: 13))
                .foregroundStyle(hot ? Color.primary : Color.secondary)
                .opacity(isEnabled ? 1 : 0.35)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.white.opacity(configuration.isPressed && isEnabled ? 0.16 : hot ? 0.09 : 0))
                )
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .cursor(isEnabled ? .pointingHand : .arrow)
        }
    }
}

// The color button in a row's bottom-left corner: small, like the x on a
// VSCode editor tab.
// Primary colors, so they show on light and dark tabs.
struct RowIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowIconButtonBody(configuration: configuration)
    }

    private struct RowIconButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .frame(width: 16, height: 16)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.2 : hovering ? 0.12 : 0))
                )
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .cursor(.pointingHand)
        }
    }
}

// Solid bar color in the gaps outside VSCode's rounded top corners.
// The selected tab goes on over the VSCode window's 1 pt border, so it
// looks like part of the window. Its inner corners join that border.
struct CornerPieces: View {
    let radius: CGFloat
    @ObservedObject var join: TabJoin

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                CornerPiece(left: true).frame(width: radius, height: radius)
                Spacer(minLength: 0)
                CornerPiece(left: false).frame(width: radius, height: radius)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if let span = join.span {
                Canvas { ctx, size in
                    // Only where the tab shows in the list, like in the bar.
                    ctx.clip(to: Path(CGRect(x: span.listLeft, y: 0, width: span.listRight - span.listLeft, height: size.height)))
                    // The tab's rect ends at the window's edge, y = 0 here.
                    let rect = CGRect(x: span.left, y: -100, width: span.right - span.left, height: 100)
                    ctx.fill(TabShape(fill: true).path(in: rect), with: .color(Color(nsColor: hexColor(span.color))))
                    ctx.stroke(TabShape().path(in: rect), with: .color(borderColor), lineWidth: 1)
                }
            }
        }
    }
}

// A square minus a quarter circle: the gap outside one rounded corner.
// A line on its outer edge joins the bar's border to VSCode's.
struct CornerPiece: View {
    let left: Bool

    var body: some View {
        Canvas { ctx, size in
            let square = CGRect(origin: .zero, size: size)
            // The corner's circle center is inside the VSCode window, below.
            let circle = CGRect(x: left ? 0 : -size.width, y: 0, width: size.width * 2, height: size.height * 2)
            var path = Path(square)
            path.addEllipse(in: circle)
            ctx.clip(to: Path(square))
            ctx.fill(path, with: .color(barColor), style: FillStyle(eoFill: true))
            ctx.fill(Path(CGRect(x: left ? 0 : size.width - 1, y: 0, width: 1, height: size.height)), with: .color(borderColor))
        }
    }
}

// The tab tip: a small dark box with the window's details.
struct TipView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Color.primary)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(barColor))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(borderColor, lineWidth: 1))
    }
}

// Lets the first click on an inactive bar reach the row.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
