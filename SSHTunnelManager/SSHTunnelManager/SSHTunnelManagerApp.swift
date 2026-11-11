import SwiftUI
import Darwin
import UserNotifications

/// Entry point. ssh re-invokes this executable as its askpass program for
/// password-authenticated tunnels (see AskpassHelper); that case must be
/// answered before any app state exists — TunnelManager's init kills the
/// PIDs recorded by the running instance, i.e. the live tunnels.
@main
enum AppMain {
    static func main() {
        AskpassHelper.runIfInvoked()
        SSHTunnelManagerApp.main()
    }
}

struct SSHTunnelManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Menu Bar
        MenuBarExtra {
            MenuBarView()
                .environment(appDelegate.tunnelManager)
        } label: {
            MenuBarIcon(tunnelManager: appDelegate.tunnelManager)
        }
        .menuBarExtraStyle(.window)

        // Main Settings Window
        Window("SSH Tunnel Manager", id: "main") {
            ContentView()
                .environment(appDelegate.tunnelManager)
                .frame(minWidth: 600, minHeight: 400)
        }
        .windowStyle(.automatic)
        .windowResizability(.contentSize)
        .defaultSize(width: 800, height: 600)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Tunnel") {
                    appDelegate.tunnelManager.addTunnel()
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}

/// The menu bar icon. Plain symbol while nothing is connected; once any tunnel
/// is up it switches to a filled badge with the symbol cut out of it, so the
/// state is readable at a glance. Both are template images, so the system
/// colors them for a light or dark menu bar.
///
/// A separate View (rather than inline in the Scene) so it re-renders through
/// Observation when the manager's connection state changes.
struct MenuBarIcon: View {
    let tunnelManager: TunnelManager

    static let symbolName = "point.3.connected.trianglepath.dotted"

    var body: some View {
        if tunnelManager.hasConnectedTunnel {
            Image(nsImage: Self.connectedImage)
        } else {
            Image(systemName: Self.symbolName)
        }
    }

    /// Drawn by hand because a MenuBarExtra label ignores SwiftUI styling
    /// (background, opacity, foreground color) — only the image itself counts.
    static let connectedImage: NSImage = {
        let size = NSSize(width: 26, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4.5, yRadius: 4.5).fill()

            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else { return true }
            let origin = NSPoint(
                x: rect.midX - symbol.size.width / 2,
                y: rect.midY - symbol.size.height / 2
            )
            // Punch the symbol out of the badge instead of painting over it.
            symbol.draw(
                in: NSRect(origin: origin, size: symbol.size),
                from: .zero,
                operation: .destinationOut,
                fraction: 1
            )
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "SSH Tunnel Manager — connected"
        return image
    }()
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    let tunnelManager = TunnelManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Make app accessory - no dock icon, proper focus handling
        NSApp.setActivationPolicy(.accessory)
        // Disable Sudden Termination - ensures cleanup handlers run
        ProcessInfo.processInfo.disableSuddenTermination()

        // Deliver connect/disconnect notifications as banners even while the app
        // is the active app (otherwise the system suppresses foreground alerts).
        UNUserNotificationCenter.current().delegate = self

        // Register for additional termination signals
        setupSignalHandlers()

        // Register for workspace notifications (logout, shutdown, restart)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceWillPowerOff),
            name: NSWorkspace.willPowerOffNotification,
            object: nil
        )

        // Observe window closing to return focus to previous app
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowClose),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    @objc private func handleWindowClose(_ notification: Notification) {
        // When Settings window closes, hide app to return focus to previous app
        // Small delay to ensure window is fully closed
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Only hide if no windows are visible
            if NSApp.windows.filter({ $0.isVisible && $0.className != "NSStatusBarWindow" }).isEmpty {
                NSApp.hide(nil)
            }
        }
    }

    @objc private func workspaceWillPowerOff(_ notification: Notification) {
        tunnelManager.disconnectAll()
    }

    private func setupSignalHandlers() {
        // Handle common termination signals
        let signals: [Int32] = [SIGTERM, SIGINT, SIGHUP]

        for sig in signals {
            signal(sig) { _ in
                // Signal handlers must be synchronous and non-blocking
                // Use the sync version that reads PIDs from file
                if let delegate = NSApplication.shared.delegate as? AppDelegate {
                    delegate.tunnelManager.disconnectAllSync()
                }
                exit(0)
            }
        }
    }

    // Show notifications as banners even when this app is frontmost.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    func applicationWillTerminate(_ notification: Notification) {
        tunnelManager.disconnectAll()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Cleanup before termination is confirmed
        tunnelManager.disconnectAll()
        return .terminateNow
    }
}
