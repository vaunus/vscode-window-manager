import AppKit
import Carbon
import ServiceManagement
import SwiftUI

// Saved settings, open at login, the global shortcut, and the shortcut recorder.

struct HotKeySpec: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32   // Carbon modifier flags
    let label: String       // for example "⌃⌥Space"
}

struct RowColor: Identifiable {
    let name: String
    let color: Color
    var id: String { name }
}

let rowColors: [RowColor] = [
    RowColor(name: "red", color: .red), RowColor(name: "orange", color: .orange),
    RowColor(name: "yellow", color: .yellow), RowColor(name: "green", color: .green),
    RowColor(name: "mint", color: .mint), RowColor(name: "teal", color: .teal),
    RowColor(name: "blue", color: .blue), RowColor(name: "indigo", color: .indigo),
    RowColor(name: "purple", color: .purple), RowColor(name: "pink", color: .pink),
    RowColor(name: "brown", color: .brown), RowColor(name: "gray", color: .gray),
]

func rowColor(_ name: String?) -> Color? {
    rowColors.first { $0.name == name }?.color
}

@MainActor
final class Settings: ObservableObject {
    static let minWidth: Double = 120
    static let maxWidth: Double = 300
    static let widthStep: Double = 10
    static let defaultHotKey = HotKeySpec(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | optionKey), label: "⌥⌘V")

    @Published var width: Double { didSet { UserDefaults.standard.set(width, forKey: "barWidth") } }
    // UUID of the screen for the bar. nil: the main screen.
    @Published var screen: String? { didSet { UserDefaults.standard.set(screen, forKey: "screen") } }
    // Row keys (folder paths) in the saved order.
    @Published var order: [String] { didSet { UserDefaults.standard.set(order, forKey: "order") } }
    // Row key -> color name.
    @Published var colors: [String: String] { didSet { UserDefaults.standard.set(colors, forKey: "colors") } }
    @Published var hotKey: HotKeySpec? {
        didSet {
            if let hotKey, let data = try? JSONEncoder().encode(hotKey) {
                UserDefaults.standard.set(data, forKey: "hotKey")
            } else {
                // Empty data means "no shortcut", so the default does not come back.
                UserDefaults.standard.set(Data(), forKey: "hotKey")
            }
        }
    }

    init() {
        let d = UserDefaults.standard
        let w = d.double(forKey: "barWidth")
        width = w == 0 ? 220 : min(max(w, Self.minWidth), Self.maxWidth)
        screen = d.string(forKey: "screen")
        order = d.stringArray(forKey: "order") ?? []
        colors = d.dictionary(forKey: "colors") as? [String: String] ?? [:]
        hotKey = d.object(forKey: "hotKey") == nil
            ? Self.defaultHotKey
            : d.data(forKey: "hotKey").flatMap { try? JSONDecoder().decode(HotKeySpec.self, from: $0) }
    }

    // Empty windows first, oldest first. Then the rows in the saved order.
    // Rows not in it go last, by name.
    func ordered(_ rows: [Row]) -> [Row] {
        let empty = rows.filter(\.window.empty).sorted {
            ($0.window.startedAt ?? .distantFuture, $0.id) < ($1.window.startedAt ?? .distantFuture, $1.id)
        }
        var index: [String: Int] = [:]
        for (i, key) in order.enumerated() where index[key] == nil { index[key] = i }
        return empty + rows.filter { !$0.window.empty }.sorted { a, b in
            switch (index[a.key], index[b.key]) {
            case let (x?, y?): return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return a.name.localizedCompare(b.name) == .orderedAscending
            }
        }
    }

    // Move a row to the place of another row, and save the order.
    func move(_ key: String, to target: String, visible: [String]) {
        var keys = visible
        guard key != target, let from = keys.firstIndex(of: key), let to = keys.firstIndex(of: target) else { return }
        keys.remove(at: from)
        keys.insert(key, at: to)
        order = keys + order.filter { !keys.contains($0) }
    }

    func resetLayout() {
        order = []
        colors = [:]
    }
}

// "Open at login", with the system login items. macOS keeps this setting,
// so it is read again each time the settings open.
@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var needsApproval = false
    @Published private(set) var error: String?

    init() { refresh() }

    func refresh() {
        let status = SMAppService.mainApp.status
        enabled = status == .enabled
        needsApproval = status == .requiresApproval
    }

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = on ? "macOS did not add the login item." : "macOS did not remove the login item."
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
    var m: UInt32 = 0
    if flags.contains(.command) { m |= UInt32(cmdKey) }
    if flags.contains(.option) { m |= UInt32(optionKey) }
    if flags.contains(.control) { m |= UInt32(controlKey) }
    if flags.contains(.shift) { m |= UInt32(shiftKey) }
    return m
}

func shortcutLabel(_ event: NSEvent, _ flags: NSEvent.ModifierFlags) -> String {
    var s = ""
    if flags.contains(.control) { s += "⌃" }
    if flags.contains(.option) { s += "⌥" }
    if flags.contains(.shift) { s += "⇧" }
    if flags.contains(.command) { s += "⌘" }
    let special: [UInt16: String] = [
        49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
    return s + (special[event.keyCode] ?? (event.charactersIgnoringModifiers ?? "?").uppercased())
}

// One global shortcut, with the Carbon hot key API. Needs no extra permission.
@MainActor
final class HotKey {
    static let shared = HotKey()
    var action: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var installed = false

    // Returns false if macOS refuses the shortcut (for example, it is in use).
    @discardableResult
    func register(_ spec: HotKeySpec?) -> Bool {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        guard let spec else { return true }
        install()
        let id = EventHotKeyID(signature: OSType(0x5653_574D), id: 1)  // "VSWM"
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(spec.keyCode, spec.modifiers, id, GetApplicationEventTarget(), 0, &newRef)
        ref = newRef
        return status == noErr
    }

    private func install() {
        guard !installed else { return }
        installed = true
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.shared.action?() } }
            return noErr
        }, 1, &type, nil, nil)
    }
}

// Records the next key press with a modifier. Esc cancels.
@MainActor
final class ShortcutRecorder: ObservableObject {
    @Published var recording = false
    @Published var error: String?
    var onStart: (() -> Void)?
    var onEnd: (() -> Void)?
    var onRecord: ((HotKeySpec) -> Void)?
    private var monitor: Any?

    func start() {
        guard !recording else { return }
        recording = true
        error = nil
        onStart?()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return nil
        }
    }

    func stop() {
        guard recording else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        onEnd?()
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 {
            stop()
            return
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.intersection([.command, .option, .control]).isEmpty else {
            error = "Add ⌘, ⌥ or ⌃"
            return
        }
        let spec = HotKeySpec(keyCode: UInt32(event.keyCode), modifiers: carbonModifiers(flags), label: shortcutLabel(event, flags))
        stop()
        onRecord?(spec)
    }
}
