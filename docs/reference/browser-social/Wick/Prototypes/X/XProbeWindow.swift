import SwiftUI

/// Dev-only window wiring for `XProbeView`, mirroring `XueqiuProbeWindow`. Split
/// out from `WickApp` so the `@Environment(\.openWindow)`-driven menu button
/// (which can only live in a `View`, not in the `App`'s `body` directly) has a
/// tidy home, and so the whole probe stays self-contained under
/// `Wick/Prototypes/X/`.
///
/// Everything here is compiled only in DEBUG (the `App`-side scene + command
/// that reference it are `#if DEBUG`), so it carries no Release weight.
enum XProbeWindow {
    /// Stable scene identifier the Developer-menu command opens.
    static let id = "wick.dev.x-probe"
}

/// The "Developer › X (Twitter) 数据可达性 Probe…" menu item. A tiny view rather
/// than an inline `Button` in `WickApp` because opening a window requires the
/// `openWindow` environment action, which is only available inside a `View`.
struct XProbeMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("X (Twitter) 数据可达性 Probe…") {
            openWindow(id: XProbeWindow.id)
        }
    }
}
