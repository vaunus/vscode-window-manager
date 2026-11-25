import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The bar across the top of the screen, with one tab per VSCode window.
// BarView.swift has the bar down the left side, and the parts both share.

// Height of the bar across the top of the VSCode windows: the space above
// the tabs, and room for a tab's lines.
func barHeight(lines: Int) -> CGFloat { 16 + 16 * CGFloat(lines) }
// Room under the bar for the settings while they are open.
let settingsHeight: CGFloat = 400
// Space between the top of the bar and the tabs.
let tabTop: CGFloat = 4
// Each tab gets an equal share of the bar, within these widths. Past the
// minimum, the tabs scroll.
let minTabWidth: CGFloat = 110
let maxTabWidth: CGFloat = 220
// The top bar's shape: rounded on top, square where it meets VSCode.
let topBarShape = UnevenRoundedRectangle(topLeadingRadius: windowRadius, topTrailingRadius: windowRadius, style: .circular)

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

// The selected tab's outline: the top of a rounded rectangle, joined to
// the VSCode window's border by a rounded inner corner on the left and the
// right. The window starts at the bottom edge of the rect. The inner
// corners go outside the rect: left of it, right of it, and 1 pt down,
// over the window's border. The lines are 1 pt wide, on whole points.
// fill: the area inside the outline, down to the bottom of the border.
struct TopTabShape: Shape {
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

// One VSCode window as a tab, with the same lines as a side row. The
// folders are in the tooltip.
struct TopRowView: View {
    let row: Row
    // The tab color (0xRRGGBB) of the selected row. Nil for other rows.
    let tab: Int?
    let color: Color?
    let editing: Bool
    let showBranch: Bool
    let showChanges: Bool
    let showStatus: Bool
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

            RowLines(row: row, showBranch: showBranch, showChanges: showChanges, showStatus: showStatus,
                     editing: editing, pickColor: { picking = true }, paletteHovering: $paletteHovering)
            Spacer(minLength: 0)
        }
        .padding(.leading, rowLeading)
        .padding(.trailing, 6)
        // Room under the color line across the top.
        .padding(.top, 4)
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

    // The selected tab is part of its VSCode window, like an index tab: down
    // to the bottom of the bar, where it joins the window with rounded inner
    // corners. A line in the window border color goes around it, so the tab
    // shows when the window is the same color as the bar. The parts over the
    // window's border are outside the bar. The corner strip draws them.
    private var background: some View {
        ZStack(alignment: .top) {
            if let tab {
                TopTabShape(fill: true).fill(Color(nsColor: hexColor(tab)))
                TopTabShape().stroke(borderColor, lineWidth: 1)
            } else {
                // The tab under the mouse is a little lighter.
                UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6, style: .circular)
                    .fill(Color.white.opacity(hovering ? 0.06 : 0))
            }
            // A tab's color is only this line, across its top.
            if let color {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .frame(height: 3)
                    .padding(.horizontal, 5)
                    .padding(.top, 2)
                    .opacity(row.asleep ? 0.5 : 1)
            }
        }
    }
}

struct TopBarView: View {
    @ObservedObject var model: BarModel
    @ObservedObject var settings: Settings
    @ObservedObject var recorder: ShortcutRecorder
    @ObservedObject var loginItem: LoginItem
    let actions: BarActions
    @State private var dragging: String?
    @State private var tabFrame: CGRect?
    @State private var listFrame = CGRect.zero

    private var height: CGFloat { barHeight(lines: settings.lines) }

    var body: some View {
        // The bar on top. While the settings are open, the panel is taller
        // and they show under the bar, on the right, below the gear button.
        // Not in an HStack: there, the drawer's divider turns vertical.
        VStack(spacing: 0) {
            bar
            if model.settingsOpen {
                SettingsDrawer(settings: settings, recorder: recorder, loginItem: loginItem, actions: actions)
                    .card()
                    .frame(width: 180)
                    .fixedSize(horizontal: false, vertical: true)
                    // Clear of the corner piece at VSCode's top-right corner.
                    .padding(.trailing, windowRadius + 4)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            Spacer(minLength: 0)
        }
        .cursorRoot()
        .onChange(of: joinSpan, initial: true) { _, span in model.join.topSpan = span }
    }

    private var bar: some View {
        HStack(spacing: 0) {
            // Same look as the buttons on a macOS window.
            WindowButtons(close: actions.close, minimize: actions.hideAll, small: true)
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
                                .frame(height: height - tabTop)
                        }
                        Button(action: actions.newWindow) {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(IconButtonStyle())
                        .frame(height: height - tabTop)
                        .help("Open a new VSCode window. Then pick a folder on its Welcome page.")
                    }
                    // Room for the selected tab's inner corners at the ends.
                    .padding(.horizontal, tabJoinRadius)
                    .frame(height: height, alignment: .bottom)
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
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
        .background(barColor)
        .clipShape(topBarShape)
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
    private var joinSpan: TabJoin.TopSpan? {
        guard let tabFrame, let row = model.rows.first(where: { $0.id == model.activeId }),
              tabFrame.maxX + tabJoinRadius > listFrame.minX, tabFrame.minX - tabJoinRadius < listFrame.maxX else { return nil }
        return TabJoin.TopSpan(left: tabFrame.minX, right: tabFrame.maxX, listLeft: listFrame.minX, listRight: listFrame.maxX,
                            color: tabColor(row.window, focused: model.focused))
    }

    @ViewBuilder
    private func rowView(_ row: Row, width: CGFloat) -> some View {
        let active = row.id == model.activeId
        let item = TopRowView(
            row: row,
            tab: active ? tabColor(row.window, focused: model.focused) : nil,
            color: row.window.empty ? nil : rowColor(settings.colors[row.key]),
            // An empty window has no saved place or color, so it stays a
            // normal tab while the settings are open.
            editing: model.settingsOpen && !row.window.empty,
            showBranch: settings.showBranch,
            showChanges: settings.showChanges,
            showStatus: settings.showStatus,
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
        .frame(width: width, height: height - tabTop)
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

// Solid bar color in the gaps outside VSCode's rounded top corners.
// The selected tab goes on over the VSCode window's 1 pt border, so it
// looks like part of the window. Its inner corners join that border.
struct TopCornerPieces: View {
    let radius: CGFloat
    @ObservedObject var join: TabJoin

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                TopCornerPiece(left: true).frame(width: radius, height: radius)
                Spacer(minLength: 0)
                TopCornerPiece(left: false).frame(width: radius, height: radius)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if let span = join.topSpan {
                Canvas { ctx, size in
                    // Only where the tab shows in the list, like in the bar.
                    ctx.clip(to: Path(CGRect(x: span.listLeft, y: 0, width: span.listRight - span.listLeft, height: size.height)))
                    // The tab's rect ends at the window's edge, y = 0 here.
                    let rect = CGRect(x: span.left, y: -100, width: span.right - span.left, height: 100)
                    ctx.fill(TopTabShape(fill: true).path(in: rect), with: .color(Color(nsColor: hexColor(span.color))))
                    ctx.stroke(TopTabShape().path(in: rect), with: .color(borderColor), lineWidth: 1)
                }
            }
        }
    }
}

// A square minus a quarter circle: the gap outside one rounded corner.
// A line on its outer edge joins the bar's border to VSCode's.
struct TopCornerPiece: View {
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
