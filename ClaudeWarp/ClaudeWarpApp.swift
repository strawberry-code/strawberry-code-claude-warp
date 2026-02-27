import SwiftUI
import AppKit

/// Shared controller che gestisce server e stato, accessibile sia dall'App che dal delegate.
@Observable
final class AppController {
    let state = AppState()
    private(set) var server: ProxyServer?

    func startServer() {
        guard server == nil else { return }
        let s = ProxyServer(state: state)
        s.start()
        server = s
    }

    func stopServer() {
        server?.stop()
        server = nil
    }

    func restartServer() {
        stopServer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            startServer()
        }
    }
}

/// Crea l'icona menubar con emoji torii gate.
func makeMenuBarIcon(running: Bool) -> NSImage {
    let emoji = running ? "⛩️" : "⛩️"
    let font = NSFont.systemFont(ofSize: 16)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
    ]
    let str = NSAttributedString(string: emoji, attributes: attrs)
    let size = str.size()
    let img = NSImage(size: size, flipped: false) { rect in
        str.draw(in: rect)
        return true
    }
    img.isTemplate = false
    return img
}

/// AppDelegate: gestisce NSStatusItem con icona gialla + popover + auto-start.
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let controller = AppController()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var observation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Status item nella menubar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon()

        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Popover con la vista SwiftUI
        popover = NSPopover()
        popover.contentViewController = NSHostingController(rootView:
            MenuBarView(
                state: controller.state,
                onStart: { [weak self] in self?.controller.startServer(); self?.updateIcon() },
                onStop: { [weak self] in self?.controller.stopServer(); self?.updateIcon() },
                onRestart: { [weak self] in self?.controller.restartServer(); self?.scheduleIconUpdate() },
                onQuit: { NSApplication.shared.terminate(nil) }
            )
        )
        popover.behavior = .transient
        popover.delegate = self

        // Osserva cambiamenti di stato per aggiornare l'icona
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateIcon()
        }

        // Auto-start
        if controller.state.autoStart {
            controller.startServer()
        }
    }

    func updateIcon() {
        statusItem?.button?.image = makeMenuBarIcon(running: controller.state.isRunning)
    }

    private func scheduleIconUpdate() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.updateIcon()
        }
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

@main
struct ClaudeWarpApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Settings {
            SettingsView(state: delegate.controller.state, onRestart: { delegate.controller.restartServer() })
        }
    }
}
