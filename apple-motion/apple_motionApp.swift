import SwiftUI

private class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            // NSApp.windows includes NSStatusBarWindow (the host for the MenuBarExtra
            // label). Closing it would destroy the status bar icon, so we filter it out
            // along with any NSPanel instances used by the popup.
            NSApp.windows
                .filter { !($0 is NSPanel) }
                .filter { !$0.className.contains("StatusBar") }
                .forEach { $0.close() }
        }
    }

    // Prevent macOS from auto-reopening a window when the Dock icon is clicked
    // while no windows are visible — the MenuBarExtra is the intended entry point.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        return flag
    }
}

@main
struct apple_motionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var sensorManager = SensorManager()

    var body: some Scene {
        // MenuBarExtra is declared first so SwiftUI treats it as the primary scene
        // and does not auto-open the Dashboard window at launch.
        MenuBarExtra {
            StatusBarPopupView()
                .environmentObject(sensorManager)
        } label: {
            StatusBarLabelView()
                .environmentObject(sensorManager)
                .onAppear { sensorManager.start() }
        }
        .menuBarExtraStyle(.window)

        // Window (not WindowGroup) is a single-instance scene that does NOT
        // auto-open at launch — it must be opened explicitly via openWindow(id:).
        Window("Dashboard", id: "main") {
            ContentView()
                .environmentObject(sensorManager)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 900, height: 620)
    }
}
