import Combine
import Foundation
import WidgetKit

/// Keeps the desktop widget in step with the app:
/// writes state.json and reloads the widget when something it shows changes,
/// and plays or stops a preset when the widget asks (command.json + Darwin notification).
@MainActor
final class WidgetSync {
    private let store: PresetStore
    private let portal: Portal
    private var bag = Set<AnyCancellable>()
    private var lastShown: Data?

    init(store: PresetStore, portal: Portal) {
        self.store = store
        self.portal = portal
        guard Shared.folder != nil else { return }  // no App Group: no widget

        // objectWillChange fires before the change, so wait a moment and then read the new values.
        store.objectWillChange.merge(with: portal.objectWillChange)
            .debounce(for: .milliseconds(80), scheduler: RunLoop.main)
            .sink { [weak self] in self?.push() }
            .store(in: &bag)

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let me = Unmanaged<WidgetSync>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { MainActor.assumeIsolated { me.handleCommand() } }
            },
            Shared.commandNotification as CFString, nil, .deliverImmediately)
        push()
    }

    private var state: AppState {
        let status: AppState.Status
        if portal.talking { status = .talking }
        else if portal.playingID != nil { status = .playing }
        else {
            switch portal.camera {
            case .signedOut: status = .signedOut
            case .connecting: status = .connecting
            case .connected: status = .connected
            case .idle: status = portal.busyID != nil ? .connecting : .ready
            }
        }
        return AppState(camera: portal.cameraName, status: status, playingID: portal.playingID,
                        playStarted: portal.playStarted, playDuration: portal.playDuration, busyID: portal.busyID)
    }

    /// Reload the widget only when what it shows changed. WidgetKit limits how often
    /// a background app may reload, so don't waste reloads.
    func push() {
        let s = state
        Shared.write(s, to: "state.json")
        var shown = (try? JSONEncoder().encode(s)) ?? Data()
        shown.append((try? JSONEncoder().encode(store.presets)) ?? Data())
        guard shown != lastShown else { return }
        lastShown = shown
        WidgetCenter.shared.reloadTimelines(ofKind: Shared.widgetKind)
    }

    private func handleCommand() {
        guard let cmd = Shared.read(WidgetCommand.self, from: "command.json") else { return }
        Shared.remove("command.json")
        guard Date.now.timeIntervalSince(cmd.sentAt) < 15 else { return }  // stale press
        appLog("[widget] press \(cmd.presetID)")
        toggle(cmd.presetID)
    }

    /// Play or stop a preset, from a widget press or a bardispeak://play?id=… link.
    func toggle(_ id: UUID) {
        guard let preset = store.presets.first(where: { $0.id == id }) else {
            appLog("[widget] unknown preset \(id)")
            return
        }
        portal.toggle(preset, file: store.fileURL(preset)) { [store] in store.markPlayed($0) }
    }

    func handle(_ url: URL) {
        guard url.scheme == Shared.urlScheme, url.host == "play",
              let idText = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "id" })?.value,
              let id = UUID(uuidString: idText) else { return }
        appLog("[widget] link play \(id)")
        toggle(id)
    }
}
