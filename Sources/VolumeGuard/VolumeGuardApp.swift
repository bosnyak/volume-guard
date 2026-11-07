import AppKit
import SwiftUI

final class VolumeGuardApplication: NSApplication {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .systemDefined && event.subtype.rawValue == 8 {
            if MediaKeyInterceptor.shared.handleSystemDefinedEvent(event) {
                return
            }
        }
        super.sendEvent(event)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let manager = OutputPriorityManager.shared
    private var eventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        setupPopover()

        manager.onStateChanged = { [weak self] in
            DispatchQueue.main.async {
                self?.updateStatusButtonIcon()
            }
        }

        manager.start()
        updateStatusButtonIcon()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        manager.stopAndRestoreSystemOutput()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.action = #selector(togglePopover(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateStatusButtonIcon()
    }

    private func setupPopover() {
        popover.contentSize = NSSize(width: 330, height: 390)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(manager: manager)
        )

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, self.popover.isShown else { return }
            self.popover.performClose(nil)
        }
    }

    private func updateStatusButtonIcon() {
        guard let button = statusItem.button else { return }
        let icon = MenuBarIconRenderer.makeIcon(
            volume: manager.volume,
            isMuted: manager.isMuted,
            isEnabled: manager.isEnabled
        )
        button.image = icon
        button.alphaValue = manager.isEnabled ? 1.0 : 0.55

        if !manager.isEnabled {
            button.toolTip = "VolumeGuard (\(LocalizationManager.shared.statusDisabled))"
        } else if let active = manager.activeDevice {
            let pct = manager.isMuted ? 0 : Int(round(manager.volume * 100))
            button.toolTip = "VolumeGuard (\(active.name)) • \(pct)%"
        } else {
            button.toolTip = "VolumeGuard"
        }
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            manager.refreshDeviceList()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

@main
struct VolumeGuardMain {
    static func main() {
        let app = VolumeGuardApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
