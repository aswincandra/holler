import SwiftUI

/// "Preset Audio Player" window: everything the menu has, plus rename, delete
/// and drag-and-drop adding.
struct ManagerView: View {
    @ObservedObject var store: PresetStore
    @ObservedObject var portal: Portal
    @ObservedObject var recorder: Recorder
    @State private var dropTargeted = false
    @State private var dropHover = false

    private let columns = [
        GridItem(.fixed(40)), GridItem(.flexible(minimum: 160)), GridItem(.fixed(120)),
        GridItem(.fixed(60)), GridItem(.fixed(120)), GridItem(.fixed(40)),
    ]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.line)
            cameraBar
            Divider().overlay(Theme.line)
            VStack(spacing: 12) {
                table
                dropZone
                if let err = portal.lastError ?? recorder.error {
                    Text(err).font(.system(size: 12)).foregroundStyle(Theme.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            Spacer(minLength: 0)
            Divider().overlay(Theme.line)
            footer
        }
        .frame(minWidth: 820, minHeight: 580)
        .background(.white)
        .foregroundStyle(Theme.ink)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            AppIconTile(size: 30)
            VStack(alignment: .leading, spacing: 0) {
                Text("Preset Audio Player").font(.system(size: 14, weight: .bold))
                Text("Bardi Speak · \(store.presets.count) presets").font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            Spacer()
            RecordButton(store: store, recorder: recorder).frame(width: 150)
            Button { store.addWithPanel() } label: { Label("Add Preset", systemImage: "plus") }
                .buttonStyle(PrimaryButtonStyle()).frame(width: 130)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color(hex: 0xF7F9FA))
    }

    // Same camera controls as the menu: picker + status, Hold to Talk, the portal.
    private var cameraBar: some View {
        HStack(spacing: 10) {
            CameraStatusRow(portal: portal).frame(maxWidth: 420)
            TalkButton(portal: portal).frame(width: 220)
            Button { portal.showWindow() } label: { Label("Show Camera Portal…", systemImage: "video") }
                .buttonStyle(OutlineButtonStyle()).frame(width: 190)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private var table: some View {
        VStack(spacing: 6) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 0) {
                ForEach(["", "NAME", "SOURCE", "LENGTH", "LAST PLAYED", ""], id: \.self) { h in
                    Text(h).font(.system(size: 11, weight: .bold)).kerning(0.6).foregroundStyle(Theme.muted)
                }
            }
            .padding(.horizontal, 12)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach($store.presets) { $preset in
                        row($preset)
                        Divider().overlay(Theme.line)
                    }
                    if store.presets.isEmpty {
                        Text("No presets yet. Add an audio file, drop one below, or record one.")
                            .font(.system(size: 13)).foregroundStyle(Theme.muted).padding(16)
                    }
                }
            }
            .frame(maxHeight: 300)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func row(_ preset: Binding<Preset>) -> some View {
        let p = preset.wrappedValue
        let isPlaying = portal.playingID == p.id
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 0) {
            PlayButton(isPlaying: isPlaying, isBusy: portal.busyID == p.id, size: 32) {
                portal.toggle(p, file: store.fileURL(p)) { store.markPlayed($0) }
            }
            VStack(alignment: .leading, spacing: 4) {
                TextField("Preset name", text: preset.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                if isPlaying, let start = portal.playStarted {
                    TimelineView(.periodic(from: start, by: 0.1)) { ctx in
                        ProgressView(value: min(ctx.date.timeIntervalSince(start) / max(portal.playDuration, 0.1), 1))
                            .tint(Theme.teal)
                    }
                } else if portal.busyID == p.id {
                    Text("Connecting to camera…").font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            }
            Text(p.source ?? "Audio file").font(.system(size: 13)).foregroundStyle(Theme.muted)
            Text(formatDuration(p.duration)).font(.system(size: 13).monospacedDigit()).foregroundStyle(Theme.muted)
            Text(p.lastPlayed.map { $0.formatted(.relative(presentation: .named)) } ?? "Never")
                .font(.system(size: 13)).foregroundStyle(Theme.muted)
            Button { store.remove(p) } label: {
                Image(systemName: "trash").foregroundStyle(Theme.danger)
            }
            .buttonStyle(OutlineButtonStyle()).frame(width: 34)
            .accessibilityLabel("Delete \(p.name)")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(isPlaying ? Theme.tealTint : .white)
    }

    // Click it like "Add Preset", or drop files on it.
    private var dropZone: some View {
        Button { store.addWithPanel() } label: {
            HStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down").foregroundStyle(Theme.teal)
                Text("Drop .m4a, .wav or .mp3 files here, or click to choose files")
            }
            .font(.system(size: 13))
            .foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(dropTargeted || dropHover ? Theme.tealTint : Color(hex: 0xF7FAFA), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: 0x9FB7BC), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            dropHover = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .accessibilityLabel("Add preset from audio files")
        .dropDestination(for: URL.self) { urls, _ in
            let audio = urls.filter { ["m4a", "wav", "mp3", "aac", "aiff", "caf"].contains($0.pathExtension.lowercased()) }
            store.add(audio)
            return !audio.isEmpty
        } isTargeted: { dropTargeted = $0 }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("Disconnects from the camera after 2 minutes without use.").font(.system(size: 12)).foregroundStyle(Theme.muted)
            Spacer()
            Button("Show Presets in Finder") { NSWorkspace.shared.open(store.folder) }
                .buttonStyle(.link).font(.system(size: 12))
            Text("·").foregroundStyle(Theme.muted)
            Button("Quit Bardi Speak") { NSApp.terminate(nil) }
                .buttonStyle(.link).font(.system(size: 12))
        }
        .padding(.horizontal, 20).frame(height: 40)
    }
}
