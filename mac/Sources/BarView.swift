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
// Space between the rows and the sides of the bar.
let rowInset: CGFloat = 6
// Space between two rows.
let rowSpacing: CGFloat = 2
// Space left of a row's status dot. It has room for the color line.
let rowLeading: CGFloat = 9
// Radius of the inner corners where the selected row joins the VSCode
// window. Not more than rowInset, so they stay clear of the other rows.
let tabJoinRadius: CGFloat = 6

// The bar's shape: rounded on the left, square where it meets VSCode.
let barShape = UnevenRoundedRectangle(topLeadingRadius: windowRadius, bottomLeadingRadius: windowRadius, style: .circular)

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
    // The tip under the tab the mouse rests on, in the top bar. The app
    // shows it in its own panel: .help() tooltips do not show in the bar's panel.
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
    // In the bar window (top-left origin): the row's top and bottom, and the
    // top and bottom of the list, where the row shows. Then the color.
    struct Span: Equatable {
        let top: CGFloat
        let bottom: CGFloat
        let listTop: CGFloat
        let listBottom: CGFloat
        let color: Int
    }

    @Published var span: Span?

    // The same for the top bar: the tab's left and right, and the left and
    // right of the list.
    struct TopSpan: Equatable {
        let left: CGFloat
        let right: CGFloat
        let listLeft: CGFloat
        let listRight: CGFloat
        let color: Int
    }

    @Published var topSpan: TopSpan?
}

// The selected row's outline: the left side of a rounded rectangle, joined
// to the VSCode window's border by a rounded inner corner at the top and
// the bottom. The window starts at the right edge of the rect. The inner
// corners go outside the rect: above it, below it, and 1 pt to the right,
// over the window's border. The lines are 1 pt wide, on whole points.
// fill: the area inside the outline, out to the right side of the border.
struct TabShape: Shape {
    var fill = false

    func path(in rect: CGRect) -> Path {
        let r = tabJoinRadius
        // The outer corner radius at the center of the line.
        let c: CGFloat = 5.5
        // Line centers: the window's border, and the row's left, top and bottom.
        let e = rect.maxX + 0.5, l = rect.minX + 0.5, t = rect.minY + 0.5, b = rect.maxY - 0.5
        var p = Path()
        p.move(to: CGPoint(x: e, y: t - r))
        p.addArc(tangent1End: CGPoint(x: e, y: t), tangent2End: CGPoint(x: l, y: t), radius: r)
        p.addArc(tangent1End: CGPoint(x: l, y: t), tangent2End: CGPoint(x: l, y: b), radius: c)
        p.addArc(tangent1End: CGPoint(x: l, y: b), tangent2End: CGPoint(x: e, y: b), radius: c)
        p.addArc(tangent1End: CGPoint(x: e, y: b), tangent2End: CGPoint(x: e, y: b + r), radius: r)
        if fill {
            p.addLine(to: CGPoint(x: e + 0.5, y: b + r))
            p.addLine(to: CGPoint(x: e + 0.5, y: t - r))
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

struct RowView: View {
    let row: Row
    // The tab color (0xRRGGBB) of the selected row. Nil for other rows.
    let tab: Int?
    let color: Color?
    let editing: Bool
    @Binding var colorName: String?
    let onPick: () -> Void
    @State private var picking = false
    // The mouse is on the color button.
    @State private var paletteHovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 7) {
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

            VStack(alignment: .leading, spacing: 4) {
                Text(row.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                // Branch and status lines are always there, so all rows have the same height.
                HStack(spacing: 3) {
                    if row.window.empty {
                        Image(systemName: "folder").font(.system(size: 8))
                        Text("no folder")
                    } else {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 8))
                        Text(row.branch ?? "no repo").lineLimit(1).truncationMode(.middle)
                        if row.window.changes > 0 {
                            ChangesBadge(count: row.window.changes).padding(.leading, 1)
                        }
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(Color.secondary)
                .opacity(row.branch == nil ? 0.5 : 1)
                statusText
                    .font(.system(size: 10))
                    .foregroundStyle(row.state == .needsInput ? claudeOrange : Color.secondary)
                    .opacity(row.text.isEmpty ? 0.5 : 1)
                    .lineLimit(1)
                    // Settings open: the color button in the row's bottom-left
                    // corner, in line with this line, under the drag handle.
                    .overlay(alignment: .leading) {
                        if editing { paletteButton }
                    }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        // Room for the color line on all rows, so the text of all rows lines up.
        .padding(.leading, rowLeading)
        .padding(.trailing, 6)
        // A sleeping window's row is dim. Its color line is dim too: see background.
        .opacity(row.asleep ? 0.5 : 1)
        // Dark text on a light tab.
        .environment(\.colorScheme, tab.map(isLight) == true ? .light : .dark)
        .background { background }
        // Out to the bar's edge, so a click there goes to the row.
        .contentShape(RowHitShape())
        // The drag hand while the settings are open, but not on the color
        // button. The row's cursor wins over the button's own cursor.
        .cursor(editing && !paletteHovering ? .openHand : .pointingHand)
        // Settings open: a click picks a color. Closed: a click goes to the window.
        .onTapGesture {
            if editing { picking = true } else { onPick() }
        }
        .popover(isPresented: $picking, arrowEdge: .trailing) {
            ColorGrid(selected: $colorName, close: { picking = false })
        }
        .help(editing
            ? "Drag to reorder. Click to set a color."
            : ([row.name] + row.window.rawFolders + [row.branch ?? "", row.text, row.asleep ? "Click to wake." : ""])
                .filter { !$0.isEmpty }.joined(separator: "\n"))
    }

    // For example "done · 5m". A running command shows a terminal icon in
    // place of a time, because it does not end by itself.
    private var statusText: Text {
        if row.text.isEmpty { return Text(verbatim: "no session") }
        if row.activity == .terminal {
            return Text("\(row.text) · \(Image(systemName: "terminal"))")
        }
        return Text(verbatim: row.text)
    }

    // Its center is on the center of the drag handle's column: 12 pt wide,
    // then 7 pt to the text. The button is 16 pt wide.
    private var paletteButton: some View {
        Button { picking = true } label: {
            Image(systemName: "paintpalette").font(.system(size: 10))
        }
        .buttonStyle(RowIconButtonStyle())
        .onHover { paletteHovering = $0 }
        .help("Set a color")
        .offset(x: -(7 + 12 / 2) - 16 / 2)
    }

    // The selected row is a tab of its VSCode window, like an index tab: out
    // to the edge of the bar, where it joins the window with rounded inner
    // corners. A line in the window border color goes around it, so the tab
    // shows when the window is the same color as the bar. The parts over the
    // window's border are outside the bar. The corner strip draws them.
    private var background: some View {
        ZStack(alignment: .leading) {
            if let tab {
                TabShape(fill: true).fill(Color(nsColor: hexColor(tab)))
                TabShape().stroke(borderColor, lineWidth: 1)
            } else {
                Color.clear
            }
            // A row's color is only this line.
            if let color {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .frame(width: 3)
                    .padding(.vertical, 4)
                    .padding(.leading, 2)
                    .opacity(row.asleep ? 0.5 : 1)
            }
        }
        .padding(.trailing, tab == nil ? 0 : -rowInset)
    }
}

// A row's rect, out to the bar's edge on the right.
struct RowHitShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width + rowInset, height: rect.height))
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
                Text("Tabs").font(.system(size: 11))
                Picker("Tabs", selection: $settings.layout) {
                    Text("Left").tag(TabLayout.side)
                    Text("Top").tag(TabLayout.top)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
            }

            // The top bar has a fixed height.
            if settings.layout == .side {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Width").font(.system(size: 11))
                    StepperRow(value: "\(Int(settings.width)) px",
                               canDecrease: settings.width > Settings.minWidth,
                               canIncrease: settings.width < Settings.maxWidth,
                               decrease: { changeWidth(by: -Settings.widthStep) },
                               increase: { changeWidth(by: Settings.widthStep) },
                               decreaseHelp: "Narrower", increaseHelp: "Wider")
                }
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
        .background(barColor)
        .overlay(alignment: .top) { Divider() }
    }

    private func changeWidth(by delta: Double) {
        settings.width = min(max(settings.width + delta, Settings.minWidth), Settings.maxWidth)
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

extension View {
    // In the top bar, the settings are a card under the bar. The bar color
    // covers the drawer's divider line.
    func card() -> some View {
        overlay(alignment: .top) { barColor.frame(height: 1) }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(borderColor, lineWidth: 1))
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
            .popover(isPresented: $showing, arrowEdge: .trailing) {
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

// A value between − and + buttons.
struct StepperRow: View {
    let value: String
    let canDecrease: Bool
    let canIncrease: Bool
    let decrease: () -> Void
    let increase: () -> Void
    let decreaseHelp: String
    let increaseHelp: String

    var body: some View {
        HStack(spacing: 0) {
            Button(action: decrease) {
                Image(systemName: "minus")
            }
            .buttonStyle(IconButtonStyle())
            .disabled(!canDecrease)
            .help(decreaseHelp)
            Spacer()
            Text(value)
                .font(.system(size: 11).monospacedDigit())
            Spacer()
            Button(action: increase) {
                Image(systemName: "plus")
            }
            .buttonStyle(IconButtonStyle())
            .disabled(!canIncrease)
            .help(increaseHelp)
        }
    }
}

// The bar down the left side or across the top, as set in the settings.
struct BarRoot: View {
    @ObservedObject var model: BarModel
    @ObservedObject var settings: Settings
    @ObservedObject var recorder: ShortcutRecorder
    @ObservedObject var loginItem: LoginItem
    let actions: BarActions

    var body: some View {
        if settings.layout == .top {
            TopBarView(model: model, settings: settings, recorder: recorder, loginItem: loginItem, actions: actions)
        } else {
            BarView(model: model, settings: settings, recorder: recorder, loginItem: loginItem, actions: actions)
        }
    }
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
        VStack(spacing: 0) {
            // Same place and size as the buttons on a macOS window.
            WindowButtons(close: actions.close, minimize: actions.hideAll)
                .padding(.leading, 11)
                .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .leading)

            ScrollView {
                VStack(alignment: .leading, spacing: rowSpacing) {
                    if !model.trusted {
                        Button("Allow Accessibility") {
                            let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
                        }
                        .font(.system(size: 11))
                        .padding(.bottom, 6)
                    }
                    ForEach(model.rows) { row in
                        rowView(row)
                    }
                    if model.rows.isEmpty {
                        Text("No VSCode windows").font(.system(size: 11)).foregroundStyle(Color.secondary)
                    }
                    // The space above the button is the same as the space on
                    // its left, between the bar's edge and the button.
                    AddWindowButton(action: actions.newWindow)
                        .padding(.top, rowInset - rowSpacing)
                }
                // Room for the selected row's inner corners at the ends.
                .padding(.vertical, tabJoinRadius)
                .padding(.horizontal, rowInset)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { listFrame = $0 }
            .onPreferenceChange(TabFrameKey.self) { tabFrame = $0 }

            if model.settingsOpen {
                SettingsDrawer(settings: settings, recorder: recorder, loginItem: loginItem, actions: actions)
                    .transition(.move(edge: .bottom))
            } else {
                HStack {
                    Button(action: actions.toggleSettings) {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(IconButtonStyle())
                    .help("Settings")
                    Spacer()
                }
                .padding(8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(barColor)
        .clipShape(barShape)
        // Border on the left, top and bottom. The right edge of the stroke
        // falls outside the bar, where it joins VSCode.
        .overlay {
            barShape.strokeBorder(borderColor, lineWidth: 1).padding(.trailing, -1)
        }
        .contentShape(Rectangle())
        .cursorRoot()
        .contextMenu { BarMenuItems(actions: actions) }
        .onChange(of: joinSpan, initial: true) { _, span in model.join.span = span }
    }

    // Where the selected row meets the VSCode window. Nil while the row and
    // its inner corners are scrolled out of the list.
    private var joinSpan: TabJoin.Span? {
        guard let tabFrame, let row = model.rows.first(where: { $0.id == model.activeId }),
              tabFrame.maxY + tabJoinRadius > listFrame.minY, tabFrame.minY - tabJoinRadius < listFrame.maxY else { return nil }
        return TabJoin.Span(top: tabFrame.minY, bottom: tabFrame.maxY, listTop: listFrame.minY, listBottom: listFrame.maxY,
                            color: tabColor(row.window, focused: model.focused))
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        let active = row.id == model.activeId
        let item = RowView(
            row: row,
            tab: active ? tabColor(row.window, focused: model.focused) : nil,
            color: row.window.empty ? nil : rowColor(settings.colors[row.key]),
            // An empty window has no saved place or color, so it stays a
            // normal row while the settings are open.
            editing: model.settingsOpen && !row.window.empty,
            colorName: Binding(
                get: { settings.colors[row.key] },
                set: { settings.colors[row.key] = $0 }
            ),
            onPick: { actions.pick(row) }
        )
        .background {
            if active {
                GeometryReader { g in
                    Color.clear.preference(key: TabFrameKey.self, value: g.frame(in: .global))
                }
            }
        }
        // A row's menu replaces the bar's menu. It has only the row's items.
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

// Under the rows: opens a new, empty VSCode window. The plus is in the
// status dot's column, and the text is in line with the window names.
struct AddWindowButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 12, height: 15)
                Text("Add window")
                    .font(.system(size: 12))
                Spacer(minLength: 0)
            }
            .foregroundStyle(hovering ? Color.primary : Color.secondary)
            .padding(.vertical, 5)
            .padding(.leading, rowLeading)
            .padding(.trailing, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(hovering ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .cursor(.pointingHand)
        .help("Open a new VSCode window. Then pick a folder on its Welcome page.")
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
    // Smaller, for the slim top bar.
    var small = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: small ? 8 : 9) {
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
            .frame(width: small ? 12 : 14, height: small ? 12 : 14)
            .overlay {
                if hovering {
                    Image(systemName: symbol)
                        .font(.system(size: small ? 8 : 9, weight: .black))
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

// Solid bar color in the gaps outside VSCode's rounded left corners.
// The selected row goes on over the VSCode window's 1 pt border, so it
// looks like part of the window. Its inner corners join that border.
struct CornerPieces: View {
    let radius: CGFloat
    @ObservedObject var join: TabJoin

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                CornerPiece(top: true).frame(width: radius, height: radius)
                Spacer(minLength: 0)
                CornerPiece(top: false).frame(width: radius, height: radius)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            if let span = join.span {
                Canvas { ctx, size in
                    // Only where the row shows in the list, like in the bar.
                    ctx.clip(to: Path(CGRect(x: 0, y: span.listTop, width: size.width, height: span.listBottom - span.listTop)))
                    // The row's rect ends at the window's edge, x = 0 here.
                    let rect = CGRect(x: -100, y: span.top, width: 100, height: span.bottom - span.top)
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
    let top: Bool

    var body: some View {
        Canvas { ctx, size in
            let square = CGRect(origin: .zero, size: size)
            // The corner's circle center is inside the VSCode window, to the right.
            let circle = CGRect(x: 0, y: top ? 0 : -size.height, width: size.width * 2, height: size.height * 2)
            var path = Path(square)
            path.addEllipse(in: circle)
            ctx.clip(to: Path(square))
            ctx.fill(path, with: .color(barColor), style: FillStyle(eoFill: true))
            ctx.fill(Path(CGRect(x: 0, y: top ? 0 : size.height - 1, width: size.width, height: 1)), with: .color(borderColor))
        }
    }
}

// Lets the first click on an inactive bar reach the row.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
