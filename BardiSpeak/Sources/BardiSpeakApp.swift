import SwiftUI
import WidgetKit

@main
struct BardiSpeakApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var app

    var body: some Scene {
        MenuBarExtra {
            MenuView(store: app.store, portal: app.portal, recorder: app.recorder)
        } label: {
            MenuBarIcon(portal: app.portal)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Owns the app's state and the "Preset Audio Player" window.
/// The window is plain AppKit so we decide when it opens: on every launch you start
/// yourself, and when you open the app again while it is running.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) weak var shared: AppDelegate?

    let store = PresetStore()
    let portal = Portal()
    let recorder = Recorder()
    private(set) lazy var widgetSync = WidgetSync(store: store, portal: portal)
    private var managerWindow: NSWindow?
    private var openedByLink = false

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = widgetSync
        // build_app.sh relaunches with --background, so rebuilds stay in the menu bar.
        // A widget link may arrive just after launch; it plays a preset, so don't open the window then.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
            if !CommandLine.arguments.contains("--background") && !openedByLink { showManager() }
        }
    }

    // bardispeak://play?id=… from the widget, when the app was not running.
    func application(_ application: NSApplication, open urls: [URL]) {
        openedByLink = true
        urls.forEach(widgetSync.handle)
    }

    func applicationWillTerminate(_ notification: Notification) {
        WidgetCenter.shared.reloadTimelines(ofKind: Shared.widgetKind)  // show "not running"
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showManager()
        return false
    }

    func showManager() {
        if managerWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "Preset Audio Player — Bardi Speak"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: ManagerView(store: store, portal: portal, recorder: recorder))
            w.contentMinSize = NSSize(width: 820, height: 580)
            w.center()
            w.setFrameAutosaveName("PresetAudioPlayerWindow")  // remembers size and position
            managerWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        managerWindow?.makeKeyAndOrderFront(nil)
    }
}

struct MenuBarIcon: View {
    @ObservedObject var portal: Portal
    var body: some View {
        Image(systemName: portal.playingID != nil || portal.talking ? "speaker.wave.2.fill" : "speaker.wave.2")
    }
}
