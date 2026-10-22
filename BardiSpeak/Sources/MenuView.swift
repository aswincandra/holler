import SwiftUI

/// The dropdown under the menu-bar icon.
struct MenuView: View {
    @ObservedObject var store: PresetStore
    @ObservedObject var portal: Portal
    @ObservedObject var recorder: Recorder

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.line)
            presetList
            if let err = portal.lastError ?? recorder.error {
                Text(err)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            Divider().overlay(Theme.line)
            HStack(spacing: 8) {
                Button { store.addWithPanel() } label: { Label("Add Preset", systemImage: "plus") }
                    .buttonStyle(PrimaryButtonStyle())
                RecordButton(store: store, recorder: recorder)
            }
            .padding(12)
            VStack(alignment: .leading, spacing: 0) {
                MenuLink(title: "Manage Presets…") {
                    AppDelegate.shared?.showManager()
                }
                MenuLink(title: "Show Camera Portal…") { portal.showWindow() }
                MenuLink(title: "Quit Bardi Speak", dim: true) { NSApp.terminate(nil) }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .frame(width: 340)
        .background(.white)
        .foregroundStyle(Theme.ink)
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                AppIconTile(size: 32)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Bardi Speak").font(.system(size: 15, weight: .bold))
                    Text("Preset Audio Player").font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button {
                    AppDelegate.shared?.showManager()
                } label: {
                    Image(systemName: "gearshape").font(.system(size: 15)).foregroundStyle(Theme.muted)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
            }
            CameraStatusRow(portal: portal)
            TalkButton(portal: portal)
        }
        .padding(16)
    }

    private var presetList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("PRESETS")
                .font(.system(size: 11, weight: .bold)).kerning(0.6)
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 8).padding(.vertical, 4)
            if store.presets.isEmpty {
                Text("No presets yet. Add an audio file or record one.")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
                    .padding(8)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(store.presets) { p in
                            PresetRow(preset: p, store: store, portal: portal)
                        }
                    }
                }
                .frame(maxHeight: 320)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
    }
}

struct PresetRow: View {
    let preset: Preset
    @ObservedObject var store: PresetStore
    @ObservedObject var portal: Portal

    var body: some View {
        let isPlaying = portal.playingID == preset.id
        HStack(spacing: 12) {
            PlayButton(isPlaying: isPlaying, isBusy: portal.busyID == preset.id) {
                portal.toggle(preset, file: store.fileURL(preset)) { store.markPlayed($0) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(preset.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                if isPlaying, let start = portal.playStarted {
                    TimelineView(.periodic(from: start, by: 0.1)) { ctx in
                        ProgressView(value: min(ctx.date.timeIntervalSince(start) / max(portal.playDuration, 0.1), 1))
                            .tint(Theme.teal)
                    }
                } else if portal.busyID == preset.id {
                    Text("Connecting to camera…").font(.system(size: 12)).foregroundStyle(Theme.muted)
                } else {
                    Text(preset.source ?? "Audio file").font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            }
            Spacer(minLength: 0)
            Text(formatDuration(preset.duration))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.muted)
        }
        .padding(8)
        .background(isPlaying ? Theme.tealTint : .clear, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct CameraStatusRow: View {
    @ObservedObject var portal: Portal

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(portal.cameras, id: \.self) { name in
                    Button { portal.selectCamera(name) } label: {
                        if name == portal.cameraName { Label(name, systemImage: "checkmark") } else { Text(name) }
                    }
                }
                if !portal.cameras.isEmpty { Divider() }
                Button(portal.loadingCameras ? "Refreshing…" : "Refresh Camera List") {
                    Task { await portal.refreshCameras() }
                }
                .disabled(portal.loadingCameras)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "video").foregroundStyle(Theme.teal)
                    Text(portal.cameraName).font(.system(size: 13, weight: .semibold))
                        .lineLimit(1).truncationMode(.tail)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.muted)
                }
                .contentShape(Rectangle())
            }
            // .borderlessButton would flatten the label to one icon + text; this keeps it as drawn.
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .disabled(portal.playingID != nil || portal.talking || portal.busyID != nil)
            .accessibilityLabel("Camera: \(portal.cameraName)")
            Spacer(minLength: 4)
            if portal.loadingCameras {
                ProgressView().controlSize(.small)
                Text("Loading cameras…").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                    .fixedSize()
            } else {
                Circle().fill(dot).frame(width: 8, height: 8)
                Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.teal)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    private var label: String {
        if portal.talking { return "Live talk" }
        if portal.playingID != nil { return "Playing preset" }
        switch portal.camera {
        case .signedOut: return "Sign in needed"
        case .idle: return "Ready"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        }
    }

    private var dot: Color {
        switch portal.camera {
        case .signedOut: return Theme.orange
        case .connecting: return Theme.outline
        default: return Theme.ok
        }
    }
}

struct RecordButton: View {
    @ObservedObject var store: PresetStore
    @ObservedObject var recorder: Recorder

    var body: some View {
        Button { recorder.toggle(into: store) } label: {
            if recorder.isRecording, let start = recorder.started {
                TimelineView(.periodic(from: start, by: 1)) { ctx in
                    Label("Stop " + formatDuration(ctx.date.timeIntervalSince(start)), systemImage: "stop.circle.fill")
                }
                .foregroundStyle(Theme.orange)
            } else {
                Label { Text("Record Preset") } icon: { Image(systemName: "mic").foregroundStyle(Theme.orange) }
            }
        }
        .buttonStyle(OutlineButtonStyle())
    }
}

/// Hold to talk: the Mac's mic goes live to the camera only while the button is held.
struct TalkButton: View {
    @ObservedObject var portal: Portal
    @State private var held = false

    var body: some View {
        let live = portal.talking
        HStack(spacing: 8) {
            if portal.talkPending && !live {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: live ? "waveform" : "mic.fill")
            }
            Text(live ? "Talking… release to stop" : portal.talkPending ? "Connecting…" : "Hold to Talk")
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(live ? .white : Theme.teal)
        .frame(maxWidth: .infinity, minHeight: 40)
        .background(live ? Theme.teal : Theme.tealTint, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !held else { return }
                    held = true
                    Task { await portal.talkStart() }
                }
                .onEnded { _ in
                    held = false
                    Task { await portal.talkStop() }
                }
        )
        // The menu or window closed while held: no release event will come.
        .onDisappear {
            if held { held = false; Task { await portal.talkStop() } }
        }
        .accessibilityElement()
        .accessibilityLabel("Hold to talk through the camera")
        .accessibilityAddTraits(.isButton)
    }
}

struct AppIconTile: View {
    var size: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28)
            .fill(Theme.tealDeep)
            .frame(width: size, height: size)
            .overlay(Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(.white))
            .accessibilityHidden(true)
    }
}

struct MenuLink: View {
    var title: String
    var dim = false
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(dim ? Theme.muted : Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(hover ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
