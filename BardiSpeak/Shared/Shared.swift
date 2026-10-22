import Foundation

/// Code used by both the app and the widget.
/// They talk through the App Group folder:
/// - presets.json + audio files: written by the app, read by the widget
/// - state.json: the app's camera and playback state, for the widget to show
/// - command.json + a Darwin notification: a play/stop press from the widget

struct Preset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var fileName: String
    var duration: Double?
    var source: String?
    var lastPlayed: Date?
}

/// What the widget shows about the app.
struct AppState: Codable, Equatable {
    enum Status: String, Codable { case ready, connecting, connected, signedOut, playing, talking }
    var camera: String
    var status: Status
    var playingID: UUID?
    var playStarted: Date?
    var playDuration: Double = 0
    var busyID: UUID?       // a preset waiting for the camera to connect
}

/// A press in the widget.
struct WidgetCommand: Codable {
    var presetID: UUID
    var sentAt = Date.now
}

enum Shared {
    static let appBundleID = "id.aswin.bardispeak"
    static let widgetKind = "PresetPlayer"
    static let urlScheme = "bardispeak"

    /// "<TEAMID>.id.aswin.bardispeak", filled in at build time from the Info.plist.
    static let groupID = Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String

    /// The shared folder, or nil when the build has no App Group (e.g. ad-hoc signing).
    static var folder: URL? {
        groupID.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    }

    /// Darwin notification names must start with the group ID to pass the widget's sandbox.
    static var commandNotification: String { (groupID ?? appBundleID) + ".command" }

    static func read<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let url = folder?.appendingPathComponent(name), let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return try? decoder.decode(T.self, from: data)
    }

    static func write<T: Encodable>(_ value: T, to name: String) {
        guard let url = folder?.appendingPathComponent(name), let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func remove(_ name: String) {
        guard let url = folder?.appendingPathComponent(name) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Widget side: ask the running app to play or stop a preset.
    static func send(_ command: WidgetCommand) {
        write(command, to: "command.json")
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(commandNotification as CFString), nil, nil, true)
    }

    /// Link used when the app is not running: opening it starts the app and plays the preset.
    static func playURL(_ id: UUID) -> URL {
        URL(string: "\(urlScheme)://play?id=\(id.uuidString)")!
    }
}
