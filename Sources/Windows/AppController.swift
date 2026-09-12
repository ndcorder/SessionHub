import SwiftUI
import AppKit

final class SessionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
@Observable
final class AppController {
    let store: SessionStore
    private(set) var shortcutError: String?
    @ObservationIgnored private var panel: NSWindow?
    @ObservationIgnored private var settingsWindow: NSWindow?
    @ObservationIgnored private var helpWindow: NSWindow?
    @ObservationIgnored private let hotKey = GlobalHotKey()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(demo: Bool = false) {
        let defaults = demo ? (UserDefaults(suiteName: "com.sessionhub.preview.preferences") ?? UserDefaults()) : .standard
        let preferences = AppPreferences(defaults: defaults)
        store = SessionStore(service: demo ? DemoSessionService() : ITerm2Bridge(), preferences: preferences)
        preferences.pollingChanged = { [weak self] in self?.restartPolling() }
        preferences.shortcutChanged = { [weak self] in self?.configureShortcut() }
        hotKey.action = { [weak self] in self?.togglePanel() }
        // The demo must not steal the production app's shortcut.
        if !demo { configureShortcut() }
        restartPolling()
        if demo { Task { @MainActor [weak self] in self?.togglePanel() } }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.store.stopPolling() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.store.reconnect() }
        })
    }

    func restartPolling() { store.startPolling(interval: store.preferences.refreshInterval) }
    func configureShortcut() {
        guard !store.isDemo else { return }
        hotKey.unregister()
        shortcutError = nil
        if store.preferences.shortcutEnabled && !hotKey.register() {
            shortcutError = "⌃⌥⌘Space is already in use. You can still open the panel from the menu bar."
        }
    }

    func togglePanel() {
        if let panel, panel.isVisible { panel.orderOut(nil); return }
        if panel == nil {
            let frame = NSRect(x: 0, y: 0, width: 390, height: 580)
            let window: NSWindow
            if store.isDemo {
                NSApplication.shared.setActivationPolicy(.regular)
                window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            } else {
                let floating = SessionPanel(contentRect: frame, styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
                floating.hidesOnDeactivate = false
                window = floating
            }
            window.title = store.isDemo ? "SessionHub Demo" : "SessionHub"
            window.level = .floating
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.contentMinSize = NSSize(width: 350, height: 320)
            window.contentMaxSize = NSSize(width: 650, height: 1000)
            window.contentView = NSHostingView(rootView: content(isPanel: true))
            if !window.setFrameUsingName(store.isDemo ? "DemoPanel" : "SessionPanel") { window.center() }
            window.setFrameAutosaveName(store.isDemo ? "DemoPanel" : "SessionPanel")
            panel = window
        }
        if store.isDemo { NSApplication.shared.activate(ignoringOtherApps: true) }
        panel?.makeKeyAndOrderFront(nil)
        store.refresh()
    }

    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = window(title: "SessionHub Settings", size: NSSize(width: 480, height: 580),
                                    content: SettingsView(controller: self))
        }
        present(settingsWindow)
    }
    func showHelp() {
        if helpWindow == nil {
            helpWindow = window(title: "SessionHub Guide", size: NSSize(width: 500, height: 560), content: HelpView(store: store))
        }
        present(helpWindow)
    }
    private func window<Content: View>(title: String, size: NSSize, content: Content) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        window.center()
        return window
    }
    private func present(_ window: NSWindow?) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    func content(isPanel: Bool = false) -> some View {
        MenuBarView(store: store, isPanel: isPanel, openPanel: { [weak self] in self?.togglePanel() },
                    openSettings: { [weak self] in self?.showSettings() }, openHelp: { [weak self] in self?.showHelp() })
    }
}
