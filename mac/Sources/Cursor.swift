import AppKit
import SwiftUI

// Cursor handling. Views that want a cursor say so on hover. The bar root
// sets the wanted cursor, or the arrow, on each mouse move. This also
// clears a resize cursor left over from the edge of a VS Code window.
@MainActor
final class CursorState {
    static let shared = CursorState()
    var owner: UUID?
    var cursor: NSCursor?
}

struct CursorModifier: ViewModifier {
    let cursor: NSCursor
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content.onContinuousHover { phase in
            let state = CursorState.shared
            switch phase {
            case .active:
                state.owner = token
                state.cursor = cursor
                cursor.set()
            case .ended:
                if state.owner == token {
                    state.owner = nil
                    state.cursor = nil
                    NSCursor.arrow.set()
                }
            }
        }
    }
}

extension View {
    // Shows this cursor while the mouse is over the view.
    func cursor(_ cursor: NSCursor) -> some View {
        modifier(CursorModifier(cursor: cursor))
    }

    // For the bar root: the wanted cursor, else the arrow.
    func cursorRoot() -> some View {
        onContinuousHover { phase in
            switch phase {
            case .active:
                (CursorState.shared.cursor ?? NSCursor.arrow).set()
            case .ended:
                CursorState.shared.owner = nil
                CursorState.shared.cursor = nil
            }
        }
    }
}

// macOS only lets the front app change the cursor. VS Code is usually in
// front while the bar is used, so allow it from the background. There is no
// public API for this. If the private call is missing, this does nothing.
func allowBackgroundCursor() {
    typealias MainConnection = @convention(c) () -> Int32
    typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
    guard let handle = dlopen(nil, RTLD_NOW),
          let connSym = dlsym(handle, "CGSMainConnectionID"),
          let setSym = dlsym(handle, "CGSSetConnectionProperty") else { return }
    let conn = unsafeBitCast(connSym, to: MainConnection.self)()
    _ = unsafeBitCast(setSym, to: SetProperty.self)(conn, conn, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
}
