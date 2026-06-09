import SwiftUI

/// Dev-only window wiring for `XueqiuProbeView`. Split out from `WickApp` so
/// the `@Environment(\.openWindow)`-driven menu button (which can only live in
/// a `View`, not in the `App`'s `body` directly) has a tidy home, and so the
/// whole probe stays self-contained under `Wick/Prototypes/Xueqiu/`.
///
/// Everything here is compiled only in DEBUG (the `App`-side scene + command
/// that reference it are `#if DEBUG`), so it carries no Release weight.
enum XueqiuProbeWindow {
    /// Stable scene identifier the Developer-menu command opens.
    static let id = "wick.dev.xueqiu-probe"
}

/// The "Developer › 雪球 BYO-Cookie Probe…" menu item. A tiny view rather than
/// an inline `Button` in `WickApp` because opening a window requires the
/// `openWindow` environment action, which is only available inside a `View`.
struct XueqiuProbeMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("雪球 BYO-Cookie Probe…") {
            openWindow(id: XueqiuProbeWindow.id)
        }
    }
}
