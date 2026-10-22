import AppIntents
import AppKit
import SwiftUI
import WidgetKit

// The desktop widget: the preset list with play buttons.
// It can't play audio itself (only the app has the camera link), so a press
// sends a command to the running app. If the app isn't running, a press opens
// it with a bardispeak://play link instead.

#if !PREVIEWS  // the preview renderer has its own entry point
@main
struct BardiWidgets: WidgetBundle {
    var body: some Widget { PresetWidget() }
}
#endif

struct PresetWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Shared.widgetKind, provider: Provider()) { entry in
            PresetWidgetView(entry: entry)
        }
        .configurationDisplayName("Preset Audio Player")
        .description("Play your Bardi Speak presets on the camera.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

// MARK: Data

struct Entry: TimelineEntry {
    var date = Date.now
    var presets: [Preset]
    var state: AppState?
    var appRunning: Bool

    func isPlaying(_ p: Preset) -> Bool {
        guard appRunning, let s = state, s.playingID == p.id, let start = s.playStarted else { return false }
        return date < start.addingTimeInterval(s.playDuration)
    }
    func isBusy(_ p: Preset) -> Bool { appRunning && state?.busyID == p.id }

    static let sample = Entry(
        presets: [("Lunch time", 9), ("Nap time, sayang", 14), ("Hi from Papa", 6),
                  ("Clean-up song", 42), ("Lullaby", 80), ("Time to bathe", 11)]
            .map { Preset(name: $0.0, fileName: "", duration: $0.1) },
        state: AppState(camera: "IDR-IPC-PTZ", status: .ready), appRunning: true)
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        let e = load()
        completion(context.isPreview && e.presets.isEmpty ? .sample : e)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let now = load()
        var entries = [now]
        // When a preset is playing, add an entry for the moment it ends.
        if let s = now.state, s.playingID != nil, let start = s.playStarted {
            let end = start.addingTimeInterval(s.playDuration)
            if end > now.date {
                var after = now
                after.date = end
                after.state?.playingID = nil
                entries.append(after)
            }
        }
        // The app reloads the widget when anything changes; this is only a safety net.
        completion(Timeline(entries: entries, policy: .after(.now.addingTimeInterval(30 * 60))))
    }

    private func load() -> Entry {
        Entry(presets: Shared.read([Preset].self, from: "presets.json") ?? [],
              state: Shared.read(AppState.self, from: "state.json"),
              appRunning: !NSRunningApplication.runningApplications(withBundleIdentifier: Shared.appBundleID).isEmpty)
    }
}

// MARK: Intent

struct TogglePresetIntent: AppIntent {
    static var title: LocalizedStringResource = "Play or Stop Preset"
    static var isDiscoverable = false

    @Parameter(title: "Preset ID") var presetID: String

    init() {}
    init(_ id: UUID) { presetID = id.uuidString }

    /// WidgetKit redraws the widget right after perform() returns, much faster than a reload
    /// asked by the app (which macOS may delay). So wait until the app reports the result
    /// ("Playing", or stopped), then return, and the new state shows at once.
    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: presetID) else { return .result() }
        let wasPlaying = Shared.read(AppState.self, from: "state.json")?.playingID == id
        Shared.send(WidgetCommand(presetID: id))
        let start = Date.now
        while Date.now.timeIntervalSince(start) < 12 {
            try? await Task.sleep(for: .milliseconds(150))
            guard let s = Shared.read(AppState.self, from: "state.json") else { continue }
            if wasPlaying ? s.playingID != id : s.playingID == id { break }
            // Failed or ignored: the app is not busy with this preset and it isn't playing.
            if Date.now.timeIntervalSince(start) > 2, s.busyID == nil, s.playingID != id { break }
        }
        return .result()
    }
}

// MARK: Views

struct PresetWidgetView: View {
    var entry: Entry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if family == .systemLarge { LargeView(entry: entry) } else { MediumView(entry: entry) }
        }
        .containerBackground(for: .widget) {
            family == .systemLarge ? Color.white : Theme.tealDeep
        }
    }
}

/// A press target: a widget button when the app runs, otherwise a link that opens it.
struct PressTarget<Label: View>: View {
    var entry: Entry
    var preset: Preset
    @ViewBuilder var label: () -> Label

    var body: some View {
        if entry.appRunning {
            Button(intent: TogglePresetIntent(preset.id), label: label).buttonStyle(.plain)
        } else {
            Link(destination: Shared.playURL(preset.id), label: label)
        }
    }
}

struct StatusInfo {
    var text: String
    var dot: Color

    init(_ entry: Entry) {
        guard entry.appRunning, let s = entry.state else {
            text = "Not running"; dot = Color(hex: 0x9AA8AE); return
        }
        switch s.status {
        case .talking: text = "Live talk"; dot = Theme.ok
        case .playing: text = "Playing"; dot = Theme.ok
        case .connected: text = "Connected"; dot = Theme.ok
        case .connecting: text = "Connecting…"; dot = Color(hex: 0xF0B429)
        case .signedOut: text = "Sign in needed"; dot = Theme.danger
        case .ready: text = "Ready"; dot = Color(hex: 0x4ADE9B)
        }
    }
}

struct PlayCircle: View {
    var playing: Bool
    var busy: Bool
    var size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(playing || busy ? Theme.teal : Theme.orange)
            Image(systemName: busy ? "ellipsis" : playing ? "stop.fill" : "play.fill")
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

struct EmptyNote: View {
    var color: Color
    var body: some View {
        Text("No presets yet. Add one in Bardi Speak.")
            .font(.system(size: 12)).foregroundStyle(color)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Medium: dark teal, 2×2 tiles.
struct MediumView: View {
    var entry: Entry
    private let soft = Color(hex: 0xBFE0E3)

    var body: some View {
        let status = StatusInfo(entry)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2.fill").font(.system(size: 12, weight: .bold))
                Text("Bardi Speak").font(.system(size: 13, weight: .bold))
                Spacer(minLength: 4)
                Circle().fill(status.dot).frame(width: 7, height: 7)
                Text(entry.appRunning ? (entry.state?.camera ?? "") : status.text)
                    .font(.system(size: 11)).foregroundStyle(soft).lineLimit(1)
            }
            .foregroundStyle(.white)
            if entry.presets.isEmpty {
                EmptyNote(color: soft)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(entry.presets.prefix(4)) { p in tile(p) }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func tile(_ p: Preset) -> some View {
        let playing = entry.isPlaying(p), busy = entry.isBusy(p)
        return PressTarget(entry: entry, preset: p) {
            HStack(spacing: 10) {
                PlayCircle(playing: playing, busy: busy, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(busy ? "Connecting…" : playing ? "Playing" : formatDuration(p.duration))
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(soft)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .background(.white.opacity(playing ? 0.22 : 0.12), in: RoundedRectangle(cornerRadius: 14))
        }
        .accessibilityLabel((playing ? "Stop " : "Play ") + p.name)
    }
}

/// Large: white, a header and up to 6 rows.
struct LargeView: View {
    var entry: Entry

    var body: some View {
        let status = StatusInfo(entry)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 10).fill(Theme.tealDeep).frame(width: 34, height: 34)
                    .overlay(Image(systemName: "speaker.wave.2.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 0) {
                    Text("Preset Audio Player").font(.system(size: 14, weight: .bold))
                    Text(entry.appRunning ? "Bardi Speak · \(entry.state?.camera ?? "")" : "Bardi Speak")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 4)
                HStack(spacing: 5) {
                    Circle().fill(status.dot).frame(width: 7, height: 7)
                    Text(status.text)
                }
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.teal)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Theme.tealTint, in: Capsule())
            }
            if entry.presets.isEmpty {
                EmptyNote(color: Theme.muted)
            } else {
                VStack(spacing: 2) {
                    ForEach(entry.presets.prefix(6)) { p in row(p) }
                }
                if entry.presets.count > 6 {
                    Text("+\(entry.presets.count - 6) more in Bardi Speak")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted).padding(.leading, 8)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.ink)
    }

    private func row(_ p: Preset) -> some View {
        let playing = entry.isPlaying(p), busy = entry.isBusy(p)
        return PressTarget(entry: entry, preset: p) {
            HStack(spacing: 12) {
                PlayCircle(playing: playing, busy: busy, size: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if playing, let s = entry.state, let start = s.playStarted {
                        // Moves by itself in a widget, no reloads needed.
                        ProgressView(timerInterval: start...start.addingTimeInterval(max(s.playDuration, 0.1)),
                                     countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                            .progressViewStyle(.linear).tint(Theme.teal)
                    } else if busy {
                        Text("Connecting to camera…").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                }
                Spacer(minLength: 4)
                Text(formatDuration(p.duration)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(playing ? Theme.tealTint : .clear, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .accessibilityLabel((playing ? "Stop " : "Play ") + p.name)
    }
}
