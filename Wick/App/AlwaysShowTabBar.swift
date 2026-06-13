import SwiftUI
import AppKit

/// Pins the native macOS window tab bar (the `贵州茅台 / +` strip) visible even
/// when only a single stock tab is open.
///
/// By default AppKit auto-HIDES the OS tab bar whenever a window drops to one
/// tab, which made the bar flicker in and out ("有时出现有时不出现") and broke
/// the deliberate `toolbar → tab-bar → content` layout band: with one stock the
/// middle band vanished and content slid up. There is no public "always show at
/// 1 tab" flag — the OS exposes only `toggleTabBar(_:)` — so we show it once on
/// window adoption and re-show it via KVO whenever the OS flips it back off
/// (e.g. closing tabs down to one). The guard in `ensureVisible` makes the
/// toggle idempotent, so we never accidentally hide an already-visible bar.
///
/// Drop this as a zero-size `.background(...)` on the window's root view; it
/// reaches the hosting `NSWindow` through the view hierarchy.
///
/// `title` is mirrored onto `window.title` so the native tab label tracks the
/// current route (stock name / 市场 / 投资组合 / 旺财) instead of every tab
/// reading a static "Wick". The title-bar text itself stays hidden
/// (`titleVisibility = .hidden`) so this doesn't reintroduce a title strip — the
/// tab bar reads `window.title` regardless of title-bar visibility.
struct AlwaysShowTabBar: NSViewRepresentable {
    var title: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        let title = title
        // `view.window` is nil until the view is mounted in a window, so defer.
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            context.coordinator.attach(to: window)
            context.coordinator.apply(title: title, to: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // The `.id(appLanguage)` rebuild (and first mount) can re-run this; the
        // coordinator no-ops if it's already bound to the same window.
        let title = title
        DispatchQueue.main.async { [weak nsView] in
            guard let window = nsView?.window else { return }
            context.coordinator.attach(to: window)
            context.coordinator.apply(title: title, to: window)
        }
    }

    @MainActor
    final class Coordinator {
        private weak var boundWindow: NSWindow?
        private var observation: NSKeyValueObservation?

        /// Set the per-route window/tab title. Hides the title-bar text so only
        /// the tab shows it; idempotent so SwiftUI's frequent re-applies are cheap.
        func apply(title: String, to window: NSWindow) {
            window.titleVisibility = .hidden
            if window.title != title { window.title = title }
        }

        func attach(to window: NSWindow) {
            guard boundWindow !== window else { return }
            boundWindow = window
            // Sibling stock windows should open AS tabs in this group.
            window.tabbingMode = .preferred
            ensureVisible(window)
            installObserver(on: window)
        }

        /// Re-show the tab bar whenever the OS hides it. `tabGroup` exists once
        /// the window participates in tabbing; if it's not ready yet, retry on
        /// the next runloop so a late-forming group still gets the observer.
        private func installObserver(on window: NSWindow) {
            guard let group = window.tabGroup else {
                DispatchQueue.main.async { [weak self, weak window] in
                    guard let self, let window, self.boundWindow === window else { return }
                    self.installObserver(on: window)
                }
                return
            }
            observation = group.observe(\.isTabBarVisible, options: [.new]) { [weak self] _, _ in
                // KVO for an AppKit window property fires on the main thread.
                MainActor.assumeIsolated {
                    guard let self, let window = self.boundWindow else { return }
                    self.ensureVisible(window)
                }
            }
        }

        /// Idempotent: only toggles when the bar is currently hidden, so the KVO
        /// re-entry that our own toggle triggers settles immediately.
        private func ensureVisible(_ window: NSWindow) {
            if let group = window.tabGroup {
                if !group.isTabBarVisible { window.toggleTabBar(nil) }
            } else {
                // No group yet — toggling forms one with the bar shown.
                window.toggleTabBar(nil)
            }
        }
    }
}
