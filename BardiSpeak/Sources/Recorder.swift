import AVFoundation
import Foundation

/// Records a new preset from the Mac's microphone as .m4a.
@MainActor
final class Recorder: ObservableObject {
    @Published var isRecording = false
    @Published var started: Date?
    @Published var error: String?

    private var recorder: AVAudioRecorder?
    private var url: URL?

    func toggle(into store: PresetStore) {
        if isRecording { finish(into: store) } else { Task { await start() } }
    }

    private func start() async {
        error = nil
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            error = "Microphone access is off. Turn it on in System Settings › Privacy & Security › Microphone."
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recording-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            guard r.record() else { throw NSError(domain: "Recorder", code: 1) }
            recorder = r
            self.url = url
            started = .now
            isRecording = true
        } catch {
            self.error = "Could not start recording."
        }
    }

    private func finish(into store: PresetStore) {
        recorder?.stop()
        isRecording = false
        started = nil
        guard let url else { return }
        let name = "Recording " + Date.now.formatted(date: .omitted, time: .shortened)
        store.add([url], source: "Recorded in app", name: name)
        try? FileManager.default.removeItem(at: url)
        self.url = nil
        recorder = nil
    }
}
