import AppKit
import SwiftUI

// Renders the app's real SwiftUI views with sample data into PNGs for the README.
// Run: scripts/render_previews.sh  (writes to ../docs/images)
// Nothing here touches the network, the camera, or your real presets.

/// MenuView calls AppDelegate.shared?.showManager(); the renderer has no app delegate.
@MainActor final class AppDelegate {
    static var shared: AppDelegate? { nil }
    func showManager() {}
}

nonisolated(unsafe) var outDir = URL(fileURLWithPath: ".")

/// Draw a view offscreen at 2x and save it as a PNG.
/// Note: a command-line tool is never the active app, so AppKit progress bars draw grey here.
@MainActor func render<V: View>(_ name: String, _ view: V, size: CGSize? = nil) {
    let host = NSHostingView(rootView: view.environment(\.colorScheme, .light))
    host.frame.size = size ?? host.fittingSize
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .aqua)
    window.isOpaque = false
    window.backgroundColor = .clear
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: .now.addingTimeInterval(0.6))  // let SwiftUI and AppKit controls settle
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: rep)
    let url = outDir.appendingPathComponent(name + ".png")
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
    print("wrote \(url.path) (\(rep.pixelsWide)×\(rep.pixelsHigh))")
}

/// A plain window frame with traffic lights, so the wide window reads as a Mac window.
struct WindowChrome<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(hex: 0x3C4448))
                HStack(spacing: 8) {
                    ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { Circle().fill(Color(hex: UInt32($0))).frame(width: 12, height: 12) }
                    Spacer()
                }
                .padding(.leading, 14)
            }
            .frame(height: 34)
            .frame(maxWidth: .infinity)
            .background(Color(hex: 0xECEEF0))
            Divider()
            content
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.black.opacity(0.12)))
        .padding(1)
    }
}

/// The menu-bar dropdown's rounded panel.
struct MenuPanel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.black.opacity(0.12)))
            .padding(1)
    }
}

/// A desktop widget's rounded tile (WidgetKit draws this itself on the desktop).
struct WidgetTile<Content: View>: View {
    var background: Color
    var size: CGSize
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(16)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.black.opacity(0.08)))
            .padding(1)
    }
}

@MainActor func run() {
    outDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "previews", isDirectory: true)
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    UserDefaults.standard.removeObject(forKey: "cameraName")

    let samples: [Preset] = [
        ("Dinner is ready", 9, "Recorded in app"), ("Time for school", 14, "m4a file"),
        ("Come downstairs, please", 6, "Recorded in app"), ("Bedtime story time", 42, "mp3 file"),
        ("Feed the cat", 11, "Recorded in app"), ("Hello from work", 8, "m4a file"),
    ].map { Preset(name: $0.0, fileName: "", duration: $0.1, source: $0.2) }
    var played = samples
    played[0].lastPlayed = .now.addingTimeInterval(-3 * 60)
    played[1].lastPlayed = .now.addingTimeInterval(-26 * 3600)
    played[4].lastPlayed = .now.addingTimeInterval(-3 * 86400)

    let store = PresetStore(sample: played)
    let portal = Portal(offline: true)
    let recorder = Recorder()
    portal.cameras = ["Living Room", "Baby Room"]
    portal.camera = .connected
    // One preset playing, about 40% through.
    portal.playingID = samples[0].id
    portal.playDuration = samples[0].duration ?? 9
    portal.playStarted = .now.addingTimeInterval(-0.4 * portal.playDuration)

    render("menu", MenuPanel { MenuView(store: store, portal: portal, recorder: recorder) })
    render("manager", WindowChrome(title: "Preset Audio Player — Bardi Speak") {
        ManagerView(store: store, portal: portal, recorder: recorder).frame(width: 900, height: 640)
    })

    let entry = Entry(presets: samples,
                      state: AppState(camera: "Living Room", status: .playing, playingID: samples[0].id,
                                      playStarted: portal.playStarted, playDuration: portal.playDuration),
                      appRunning: true)
    render("widget-medium", WidgetTile(background: Theme.tealDeep, size: CGSize(width: 364, height: 170)) {
        MediumView(entry: entry)
    })
    render("widget-large", WidgetTile(background: .white, size: CGSize(width: 364, height: 382)) {
        LargeView(entry: entry)
    })
}

MainActor.assumeIsolated { run() }
