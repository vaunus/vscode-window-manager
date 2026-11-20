import Foundation

// Reads the status files written by the hook and the VSCode extension.
// Same rules as lib/state.js: a Claude tab belongs to the window that runs
// it, else longest folder match. Most urgent state wins.

enum ClaudeState: Int, Comparable {
    case none = 0, idle, done, working, needsInput

    init(_ raw: String?) {
        switch raw {
        case "needs_input": self = .needsInput
        case "working": self = .working
        case "done": self = .done
        case "idle": self = .idle
        default: self = .none
        }
    }

    static func < (a: ClaudeState, b: ClaudeState) -> Bool { a.rawValue < b.rawValue }
}

struct VSWindow {
    let id: String
    let pid: Int32
    let name: String
    let folders: [String]      // real paths, for matching
    let rawFolders: [String]   // as written, for the code CLI
    let workspaceFile: String?
    let titleBarColor: Int?            // 0xRRGGBB, focused, from the window's color theme
    let titleBarInactiveColor: Int?    // 0xRRGGBB, not focused
    // Uncommitted changes, like the number on VSCode's Source Control icon.
    let changes: Int
    // Unsaved files, and something that runs in a terminal or a task. Nil
    // when not known. Auto sleep needs both to be false.
    let unsaved: Bool?
    let busy: Bool?
    // When something last changed in the window: an edit, a save, a file,
    // git, or a terminal command. Also from before the bar started.
    let activeAt: Date?
    // A command (not Claude Code) runs in a terminal, or a task runs.
    let running: Bool?
    // No folder and no workspace, for example a new window on the Welcome page.
    let empty: Bool
    let startedAt: Date?
    // Empty windows only: when the window got the focus. Nil while it does not have it.
    let focusedAt: Date?

    // Stable key for saved order and color. Window ids change on restart.
    // An empty window has no saved order or color.
    var key: String { workspaceFile ?? rawFolders.first ?? id }

    // VSCode can open it again: a workspace file or one folder. A
    // multi-folder window without a workspace file is not saved anywhere.
    var canReopen: Bool { !empty && (workspaceFile != nil || rawFolders.count == 1) }
}

// A VSCode window that the bar closed to free its memory. Its row stays,
// and a click opens it again. Saved, so it stays after a restart.
struct SleepingWindow: Codable, Equatable {
    let key: String
    let name: String
    let rawFolders: [String]
    let workspaceFile: String?
    let sleptAt: Date

    init(_ w: VSWindow, at date: Date) {
        key = w.key
        name = w.name
        rawFolders = w.rawFolders
        workspaceFile = w.workspaceFile
        sleptAt = date
    }

    // What "code" opens to wake it.
    var target: String? { workspaceFile ?? rawFolders.first }

    var window: VSWindow {
        VSWindow(id: "asleep:" + key, pid: 0, name: name, folders: rawFolders.map(realPath), rawFolders: rawFolders,
                 workspaceFile: workspaceFile, titleBarColor: nil, titleBarInactiveColor: nil, changes: 0,
                 unsaved: nil, busy: nil, activeAt: nil, running: nil, empty: false,
                 startedAt: nil, focusedAt: nil)
    }

    // waking: the bar asked VSCode to open it a moment ago.
    func row(waking: Bool, now: Date) -> Row {
        Row(window: window, state: .none,
            text: waking ? "waking…" : "asleep · \(formatAge(now.timeIntervalSince(sleptAt)))",
            quiet: false, branch: rawFolders.first.flatMap(gitBranch), sleptAt: sleptAt)
    }
}

struct Session {
    let id: String
    let path: String           // real path of projectDir, else cwd
    let state: ClaudeState
    let reason: String?
    let detail: String?
    let updatedAt: Date?
    // A tab of the Claude extension, not a terminal. Same as TAB_ENTRYPOINT in lib/state.js.
    let inTab: Bool
    // Tabs only: the pid of the window's extension host. Nil when not known.
    let hostPid: Int32?
}

struct Row: Identifiable {
    let window: VSWindow
    let state: ClaudeState
    let text: String
    let quiet: Bool            // no update for a while: working may be stopped, done is old
    let branch: String?
    // The last update of its Claude sessions that got a prompt.
    var lastActivity: Date? = nil
    // When the bar closed the window to free its memory. Nil while awake.
    var sleptAt: Date? = nil
    // The window's own work shows instead of a Claude session's status.
    var activity: WindowActivity = .none
    // The shown session's id, when it is a Claude tab in this window. A
    // click on "needs you" shows that tab. A "done" tick shows it once.
    var tabSession: String? = nil
    // When that session last changed. A new time is a new "done".
    var tabSessionAt: Date? = nil
    var asleep: Bool { sleptAt != nil }
    var id: String { window.id }
    var key: String { window.key }
    var name: String { window.name }
}

func statusDir() -> String {
    if let dir = ProcessInfo.processInfo.environment["VSCODE_WINDOW_MANAGER_DIR"], !dir.isEmpty { return dir }
    return (NSHomeDirectory() as NSString).appendingPathComponent(".claude/window-status")
}

// Calls back when a folder's list of files changes. The window files are
// written to a temp file, then renamed, so each write changes the list.
final class FolderWatcher {
    private let source: DispatchSourceFileSystemObject

    init?(path: String, onChange: @escaping @MainActor () -> Void) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { onChange() } }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { source.cancel() }
}

// Parsed *.json files in a sub dir, as (id from file name, object).
func readStatusDir(_ sub: String) -> [(String, [String: Any])] {
    let dir = (statusDir() as NSString).appendingPathComponent(sub)
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
    var out: [(String, [String: Any])] = []
    for name in names where name.hasSuffix(".json") {
        let path = (dir as NSString).appendingPathComponent(name)
        guard let data = FileManager.default.contents(atPath: path),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
        out.append((String(name.dropLast(5)), obj))
    }
    return out
}

func realPath(_ p: String) -> String {
    guard let r = realpath(p, nil) else { return (p as NSString).standardizingPath }
    defer { free(r) }
    return String(cString: r)
}

// True if p equals folder or is below it.
func isInside(_ p: String, _ folder: String) -> Bool {
    if p == folder { return true }
    return p.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
}

// Ask the extension in a window to show a Claude tab. It checks that the
// session is a tab in that window, then deletes the file.
func requestTab(_ sessionId: String, in window: VSWindow) {
    let dir = (statusDir() as NSString).appendingPathComponent("requests")
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let request: [String: Any] = ["sessionId": sessionId, "at": f.string(from: Date())]
    guard let data = try? JSONSerialization.data(withJSONObject: request) else { return }
    // Atomic: the extension reads the file when its name shows up.
    let file = (dir as NSString).appendingPathComponent(window.id + ".json")
    try? data.write(to: URL(fileURLWithPath: file), options: .atomic)
}

func isAlive(_ pid: Int32) -> Bool {
    guard pid > 0 else { return false }
    return kill(pid, 0) == 0 || errno == EPERM
}

func parseDate(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: s)
}

// Short age text: 12s, 3m, 2h, 1d.
func formatAge(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds))
    if s < 60 { return "\(s)s" }
    let m = s / 60
    if m < 60 { return "\(m)m" }
    let h = m / 60
    if h < 24 { return "\(h)h" }
    return "\(h / 24)d"
}

// Stop does not fire when the engineer presses stop, so a "working"
// session with no update for this long may be stopped. Long replies
// with no tool call also send no updates, so keep this generous.
let quietAfter: TimeInterval = 5 * 60

func isQuiet(_ s: Session?, now: Date) -> Bool {
    guard let s, s.state == .working, let t = s.updatedAt else { return false }
    return now.timeIntervalSince(t) > quietAfter
}

// The "done" tick is green for the idle time (a setting), then grey.
func isOldDone(_ s: Session?, now: Date, idleAfter: TimeInterval) -> Bool {
    guard let s, s.state == .done, let t = s.updatedAt else { return false }
    return now.timeIntervalSince(t) > idleAfter
}

// A quiet session ranks below a fresh "working" one, above "done".
func sortRank(_ s: Session, now: Date) -> Double {
    isQuiet(s, now: now) ? Double(ClaudeState.working.rawValue) - 0.5 : Double(s.state.rawValue)
}

func sessionText(_ s: Session?, now: Date) -> String {
    guard let s else { return "" }
    switch s.state {
    case .needsInput: return "needs you · \(s.detail ?? s.reason ?? "input")"
    case .working:
        if isQuiet(s, now: now), let t = s.updatedAt {
            return "working? · quiet \(formatAge(now.timeIntervalSince(t)))"
        }
        return "working"
    case .done: return s.updatedAt.map { "done · \(formatAge(now.timeIntervalSince($0)))" } ?? "done"
    // Since the session started, or since /clear.
    case .idle: return s.updatedAt.map { "idle · \(formatAge(now.timeIntervalSince($0)))" } ?? "idle"
    case .none: return ""
    }
}

// Current git branch of a folder, read from .git/HEAD. Nil if not in a repo.
func gitBranch(_ folder: String) -> String? {
    let fm = FileManager.default
    let home = NSHomeDirectory()
    var dir = folder
    while dir != home {
        let dotGit = (dir as NSString).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dotGit, isDirectory: &isDir) {
            return headBranch(isDir.boolValue ? dotGit : gitDirFromFile(dotGit, base: dir))
        }
        let parent = (dir as NSString).deletingLastPathComponent
        if parent == dir || parent.isEmpty { return nil }
        dir = parent
    }
    return nil
}

// Worktrees and submodules: ".git" is a file with "gitdir: <path>".
private func gitDirFromFile(_ file: String, base: String) -> String? {
    guard let text = try? String(contentsOfFile: file, encoding: .utf8),
          let line = text.split(separator: "\n").first, line.hasPrefix("gitdir:") else { return nil }
    let p = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
    return p.hasPrefix("/") ? p : (base as NSString).appendingPathComponent(p)
}

private func headBranch(_ gitDir: String?) -> String? {
    guard let gitDir,
          let head = try? String(contentsOfFile: (gitDir as NSString).appendingPathComponent("HEAD"), encoding: .utf8)
    else { return nil }
    let h = head.trimmingCharacters(in: .whitespacesAndNewlines)
    if h.hasPrefix("ref: refs/heads/") { return String(h.dropFirst("ref: refs/heads/".count)) }
    if h.hasPrefix("ref: ") { return String(h.dropFirst("ref: ".count)) }
    // Detached HEAD: short commit id.
    return h.isEmpty ? nil : String(h.prefix(7))
}

// "#RRGGBB" as 0xRRGGBB. Nil for anything else.
func parseHex(_ s: String?) -> Int? {
    guard let s, s.count == 7, s.hasPrefix("#") else { return nil }
    return Int(s.dropFirst(), radix: 16)
}

// One row per live VSCode window, sorted by name.
// idleAfter: the idle time (a setting). See withWindowActivity and isOldDone.
func loadRows(now: Date = Date(), idleAfter: TimeInterval) -> [Row] {
    let windows: [VSWindow] = readStatusDir("windows").compactMap { id, o in
        let pid = Int32((o["pid"] as? NSNumber)?.intValue ?? 0)
        guard isAlive(pid) else { return nil }
        let raw = (o["folders"] as? [Any] ?? []).compactMap { $0 as? String }
        let empty = (o["empty"] as? Bool) == true
        return VSWindow(
            id: id,
            pid: pid,
            name: empty ? "Empty window" : (o["name"] as? String) ?? id,
            folders: raw.map(realPath),
            rawFolders: raw,
            workspaceFile: o["workspaceFile"] as? String,
            titleBarColor: parseHex(o["titleBarColor"] as? String),
            titleBarInactiveColor: parseHex(o["titleBarInactiveColor"] as? String),
            changes: max(0, (o["changes"] as? NSNumber)?.intValue ?? 0),
            unsaved: o["unsaved"] as? Bool,
            busy: o["busy"] as? Bool,
            activeAt: (o["activeAt"] as? String).flatMap(parseDate),
            running: o["running"] as? Bool,
            empty: empty,
            startedAt: (o["startedAt"] as? String).flatMap(parseDate),
            focusedAt: (o["focusedAt"] as? String).flatMap(parseDate)
        )
    }

    let sessions: [Session] = readStatusDir("sessions").compactMap { id, o in
        guard let p = (o["projectDir"] as? String) ?? (o["cwd"] as? String), !p.isEmpty else { return nil }
        return Session(
            id: id,
            path: realPath(p),
            state: ClaudeState(o["state"] as? String),
            reason: o["reason"] as? String,
            detail: o["detail"] as? String,
            updatedAt: (o["updatedAt"] as? String).flatMap(parseDate),
            inTab: (o["entrypoint"] as? String) == "claude-vscode",
            hostPid: (o["hostPid"] as? NSNumber).map { Int32($0.intValue) }
        )
    }

    var groups: [String: [Session]] = [:]
    for s in sessions {
        if let host = s.hostPid, let w = windows.first(where: { $0.pid == host }) {
            groups[w.id, default: []].append(s)
            continue
        }
        var best: VSWindow?
        var bestLen = -1
        for w in windows {
            for f in w.folders where f.count > bestLen && isInside(s.path, f) {
                best = w
                bestLen = f.count
            }
        }
        if let best { groups[best.id, default: []].append(s) }
    }

    return windows.map { w in
        // Most urgent first, then oldest first: the one that waits longest.
        // For "done", newest first: the tick and its age are for the last
        // session to finish, and so are the changes after it.
        let list = (groups[w.id] ?? []).sorted { a, b in
            let ra = sortRank(a, now: now)
            let rb = sortRank(b, now: now)
            if ra != rb { return ra > rb }
            // A session with no time goes last.
            if a.state == .done {
                return (a.updatedAt ?? .distantPast) > (b.updatedAt ?? .distantPast)
            }
            return (a.updatedAt ?? .distantFuture) < (b.updatedAt ?? .distantFuture)
        }
        let top = list.first
        let tab = top.flatMap { $0.inTab && $0.hostPid == w.pid ? $0 : nil }
        // Idle sessions never got a prompt.
        let active = list.filter { $0.state > .idle }
        let row = Row(
            window: w,
            state: top?.state ?? .none,
            text: sessionText(top, now: now),
            quiet: isQuiet(top, now: now) || isOldDone(top, now: now, idleAfter: idleAfter),
            branch: w.rawFolders.first.flatMap(gitBranch),
            // Not idle sessions: VSCode starts them again when it opens.
            lastActivity: active.compactMap(\.updatedAt).max(),
            tabSession: tab?.id,
            tabSessionAt: tab?.updatedAt
        )
        return withWindowActivity(row, claudeAt: top?.updatedAt, now: now, idleAfter: idleAfter)
    }
    .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
}

// What the window itself does, shown instead of the Claude status.
enum WindowActivity {
    case none
    // Something changed in the idle time (a setting).
    case editing
    // A command runs in a terminal, or a task runs.
    case terminal
}

// Claude's own changes can reach the bar some seconds after its "done":
// git loads its status after the files change. Later changes are yours.
let claudeChangesFor: TimeInterval = 30

// While no Claude session works or waits for you, the row shows, in order:
// 1. A green "done" tick, if you changed nothing after it.
// 2. "working" with a terminal icon while a command runs.
// 3. "working" for the idle time (a setting) after a change.
// 4. A grey "done" tick, if you changed nothing after it.
// 5. "idle" and the time since the last change.
// A new Claude session that got no prompt yet (for example one that VSCode
// started again) does not stop the idle time.
func withWindowActivity(_ row: Row, claudeAt: Date?, now: Date, idleAfter: TimeInterval) -> Row {
    let w = row.window
    guard row.state < .working else { return row }
    let changedAfterDone = w.activeAt.map { $0 > (claudeAt ?? .distantPast) + claudeChangesFor } == true
    let showsDone = row.state == .done && !changedAfterDone
    func working(_ activity: WindowActivity) -> Row {
        Row(window: w, state: row.state, text: "working", quiet: false,
            branch: row.branch, lastActivity: row.lastActivity, activity: activity)
    }
    if showsDone && !row.quiet { return row }
    if w.running == true { return working(.terminal) }
    // With a done tick, the changes are Claude's or older than it.
    if !showsDone, let at = w.activeAt, now.timeIntervalSince(at) < idleAfter { return working(.editing) }
    if showsDone { return row }
    if let at = w.activeAt {
        return Row(window: w, state: .idle, text: "idle · \(formatAge(now.timeIntervalSince(at)))", quiet: false,
                   branch: row.branch, lastActivity: row.lastActivity)
    }
    return row
}
