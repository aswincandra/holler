import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Presets live in the App Group folder (~/Library/Group Containers/<TEAMID>.id.aswin.bardispeak),
/// so the widget can read them: one presets.json plus one audio file per preset.
/// Without an App Group (ad-hoc build) they stay in ~/Library/Application Support/BardiSpeak.
@MainActor
final class PresetStore: ObservableObject {
    @Published var presets: [Preset] = [] { didSet { save() } }

    let folder: URL
    private var manifest: URL { folder.appendingPathComponent("presets.json") }

    init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let legacy = support.appendingPathComponent("BardiSpeak", isDirectory: true)
        // One-time move from the feasibility-test app.
        let old = support.appendingPathComponent("BardiPresets", isDirectory: true)
        if !fm.fileExists(atPath: legacy.path), fm.fileExists(atPath: old.path) {
            try? fm.moveItem(at: old, to: legacy)
        }
        if let group = Shared.folder {
            folder = group
            // One-time copy into the shared folder. The old folder stays as a backup.
            if !fm.fileExists(atPath: group.appendingPathComponent("presets.json").path),
               let items = try? fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil) {
                for item in items {
                    try? fm.copyItem(at: item, to: group.appendingPathComponent(item.lastPathComponent))
                }
                appLog("[store] copied \(items.count) files into the App Group folder")
            }
        } else {
            folder = legacy
            appLog("[store] no App Group; the widget can't see presets")
        }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: manifest),
           var list = try? JSONDecoder().decode([Preset].self, from: data) {
            for i in list.indices where list[i].duration == nil {
                list[i].duration = Self.duration(of: folder.appendingPathComponent(list[i].fileName))
            }
            presets = list
        }
    }

    func fileURL(_ p: Preset) -> URL { folder.appendingPathComponent(p.fileName) }

    func add(_ urls: [URL], source: String? = nil, name: String? = nil) {
        for src in urls {
            guard let fileName = copyIn(src) else { continue }
            presets.append(Preset(
                name: name ?? src.deletingPathExtension().lastPathComponent,
                fileName: fileName,
                duration: Self.duration(of: folder.appendingPathComponent(fileName)),
                source: source ?? "\(src.pathExtension.lowercased()) file"))
        }
    }

    func addWithPanel() {
        add(pickAudioFiles(multiple: true))
    }

    func replaceFile(_ p: Preset) {
        guard let src = pickAudioFiles(multiple: false).first,
              let i = presets.firstIndex(where: { $0.id == p.id }),
              let fileName = copyIn(src) else { return }
        try? FileManager.default.removeItem(at: fileURL(p))
        presets[i].fileName = fileName
        presets[i].duration = Self.duration(of: folder.appendingPathComponent(fileName))
        presets[i].source = "\(src.pathExtension.lowercased()) file"
    }

    func remove(_ p: Preset) {
        try? FileManager.default.removeItem(at: fileURL(p))
        presets.removeAll { $0.id == p.id }
    }

    func markPlayed(_ id: UUID) {
        if let i = presets.firstIndex(where: { $0.id == id }) { presets[i].lastPlayed = .now }
    }

    private func copyIn(_ src: URL) -> String? {
        let fileName = UUID().uuidString + "." + src.pathExtension.lowercased()
        do {
            try FileManager.default.copyItem(at: src, to: folder.appendingPathComponent(fileName))
            return fileName
        } catch {
            appLog("[store] copy failed: \(error)")
            return nil
        }
    }

    private func pickAudioFiles(multiple: Bool) -> [URL] {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = multiple
        return panel.runModal() == .OK ? panel.urls : []
    }

    private static func duration(of url: URL) -> Double? {
        guard let f = try? AVAudioFile(forReading: url) else { return nil }
        return Double(f.length) / f.fileFormat.sampleRate
    }

    private func save() {
        if let data = try? JSONEncoder().encode(presets) {
            try? data.write(to: manifest, options: .atomic)
        }
    }
}
