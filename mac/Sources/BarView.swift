import AppKit
import SwiftUI
import UniformTypeIdentifiers

// An sRGB color from a hex value, for example 0x181818.
func hexColor(_ hex: Int) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

// Bar background, like VS Code's dark theme.
let barNSColor = hexColor(0x181818)
let barColor = Color(nsColor: barNSColor)
// Selected row, like VS Code's dark theme.
let selectedColor = Color(nsColor: hexColor(0x363636))
// Window border, like macOS in dark mode.
let borderColor = Color(nsColor: hexColor(0x464646))
// Claude's brand orange, for the working spinner.
let claudeOrange = Color(nsColor: hexColor(0xD97757))

// The bar's shape: rounded on the left, square where it meets VS Code.
let barShape = UnevenRoundedRectangle(topLeadingRadius: windowRadius, bottomLeadingRadius: windowRadius, style: .circular)

@MainActor
final class BarModel: ObservableObject {
    @Published var rows: [Row] = []
    @Published var activeId: String?
    @Published var trusted = AXIsProcessTrusted()
    @Published var settingsOpen = false
}

struct BarActions {
    let close: () -> Void
    let pick: (Row) -> Void
    let move: (String, String) -> Void
    let toggleSettings: () -> Void
    let arrangeAll: () -> Void
    let hideAll: () -> Void
    let resetLayout: () -> Void
    let clearHotKey: () -> Void
}

// A 2/3 circle.
struct Arc: View {
    var color = Color.primary

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.67)
            .stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
    }
}

// The arc turns once per second, like VS Code's loading icon.
struct Spinner: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Arc(color: claudeOrange).rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 1) * 360))
        }
        .frame(width: 10, height: 10)
    }
}

struct StatusDot: View {
    let state: ClaudeState
    var quiet = false

    var body: some View {
        switch state {
        case .needsInput:
            Circle().fill(Color.blue).frame(width: 9, height: 9)
        case .working:
            if quiet {
                Arc().opacity(0.4).frame(width: 10, height: 10)
            } else {
                Spinner()
            }
        case .done:
            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.green)
        case .idle, .none:
            Circle().stroke(Color.secondary, lineWidth: 1).frame(width: 9, height: 9)
        }
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
                        .overlay(Circle().stroke(Color.primary, lineWidth: selected == c.name ? 2 : 0))
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
    let active: Bool
    let color: Color?
    let editing: Bool
    @Binding var colorName: String?
    let onPick: () -> Void
    @State private var picking = false

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Group {
                if editing {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                } else {
                    StatusDot(state: row.state, quiet: row.quiet)
                }
            }
            .frame(width: 12, height: 15)

            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                // Branch and status lines are always there, so all rows have the same height.
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 8))
                    Text(row.branch ?? "no repo").lineLimit(1).truncationMode(.middle)
                }
                .font(.system(size: 10))
                .foregroundStyle(Color.secondary)
                .opacity(row.branch == nil ? 0.5 : 1)
                Text(row.text.isEmpty ? "no session" : row.text + (row.extraCount > 0 ? " +\(row.extraCount)" : ""))
                    .font(.system(size: 10))
                    .foregroundStyle(row.state == .needsInput ? Color.blue : Color.secondary)
                    .opacity(row.text.isEmpty ? 0.5 : 1)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .padding(.leading, color == nil ? 6 : 9)
        .padding(.trailing, 6)
        .background { background }
        .contentShape(Rectangle())
        .cursor(editing ? .openHand : .pointingHand)
        // Settings open: a click picks a color. Closed: a click goes to the window.
        .onTapGesture {
            if editing { picking = true } else { onPick() }
        }
        .popover(isPresented: $picking, arrowEdge: .trailing) {
            ColorGrid(selected: $colorName, close: { picking = false })
        }
        .help(editing
            ? "Drag to reorder. Click to set a color."
            : ([row.name] + row.window.rawFolders + [row.branch ?? "", row.text]).filter { !$0.isEmpty }.joined(separator: "\n"))
    }

    private var background: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6).fill(fill)
            if let color {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .frame(width: 3)
                    .padding(.vertical, 4)
                    .padding(.leading, 2)
            }
        }
    }

    private var fill: Color {
        if active { return selectedColor }
        return color?.opacity(0.12) ?? Color.clear
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

            VStack(alignment: .leading, spacing: 2) {
                Text("Width").font(.system(size: 11))
                HStack(spacing: 0) {
                    Button { changeWidth(by: -Settings.widthStep) } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(IconButtonStyle())
                    .disabled(settings.width <= Settings.minWidth)
                    .help("Narrower")
                    Spacer()
                    Text("\(Int(settings.width)) px")
                        .font(.system(size: 11).monospacedDigit())
                    Spacer()
                    Button { changeWidth(by: Settings.widthStep) } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(IconButtonStyle())
                    .disabled(settings.width >= Settings.maxWidth)
                    .help("Wider")
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Screen").font(.system(size: 11))
                // Shows the screen the bar is on now. That is the main screen
                // while the saved one is not connected.
                Picker("Screen", selection: Binding(
                    get: { NSScreen.bar(settings.screen)?.displayUUID ?? "" },
                    set: { settings.screen = $0 }
                )) {
                    ForEach(NSScreen.screens.filter { $0.displayUUID != nil }, id: \.displayUUID) { s in
                        Text(s.localizedName).tag(s.displayUUID ?? "")
                    }
                }
                .labelsHidden()
                .controlSize(.small)
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

            Text("Drag rows to reorder. Click a row to set its color.")
                .font(.system(size: 10))
                .foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Button("Arrange windows", action: actions.arrangeAll)
                Button("Reset order", action: actions.resetLayout)
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
}

struct BarView: View {
    @ObservedObject var model: BarModel
    @ObservedObject var settings: Settings
    @ObservedObject var recorder: ShortcutRecorder
    @ObservedObject var loginItem: LoginItem
    let actions: BarActions
    @State private var dragging: String?

    var body: some View {
        VStack(spacing: 0) {
            // Same place and size as the buttons on a macOS window.
            WindowButtons(close: actions.close, minimize: actions.hideAll)
                .padding(.leading, 11)
                .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .leading)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
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
                        Text("No VS Code windows").font(.system(size: 11)).foregroundStyle(Color.secondary)
                    }
                }
                .padding(.top, 4)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

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
        // falls outside the bar, where it joins VS Code.
        .overlay {
            barShape.strokeBorder(borderColor, lineWidth: 1).padding(.trailing, -1)
        }
        .contentShape(Rectangle())
        .cursorRoot()
        .contextMenu {
            Button("Arrange All Windows", action: actions.arrangeAll)
            Button("Hide All VS Code Windows", action: actions.hideAll)
            Divider()
            Button("Quit VS Code Window Manager") { NSApp.terminate(nil) }
        }
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        let item = RowView(
            row: row,
            active: row.id == model.activeId,
            color: rowColor(settings.colors[row.key]),
            editing: model.settingsOpen,
            colorName: Binding(
                get: { settings.colors[row.key] },
                set: { settings.colors[row.key] = $0 }
            ),
            onPick: { actions.pick(row) }
        )
        if model.settingsOpen {
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

// Close and minimize, like the buttons on a macOS window. The symbols show
// while the mouse is over the buttons.
struct WindowButtons: View {
    let close: () -> Void
    let minimize: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Button(action: close) { light(0xFF5F57, "xmark") }
                .help("Close the bar. VS Code windows stay open.")
            Button(action: minimize) { light(0xFEBC2E, "minus") }
                .help("Hide all VS Code windows. Click VS Code in the Dock to bring them back.")
        }
        .buttonStyle(WindowButtonStyle())
        .onHover { hovering = $0 }
    }

    private func light(_ hex: Int, _ symbol: String) -> some View {
        Circle()
            .fill(Color(nsColor: hexColor(hex)))
            .frame(width: 14, height: 14)
            .overlay {
                if hovering {
                    Image(systemName: symbol)
                        .font(.system(size: 9, weight: .black))
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

// Solid bar color in the gaps outside VS Code's rounded left corners.
struct CornerPieces: View {
    let radius: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            CornerPiece(top: true).frame(width: radius, height: radius)
            Spacer(minLength: 0)
            CornerPiece(top: false).frame(width: radius, height: radius)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

// A square minus a quarter circle: the gap outside one rounded corner.
// A line on its outer edge joins the bar's border to VS Code's.
struct CornerPiece: View {
    let top: Bool

    var body: some View {
        Canvas { ctx, size in
            let square = CGRect(origin: .zero, size: size)
            // The corner's circle center is inside the VS Code window, to the right.
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
