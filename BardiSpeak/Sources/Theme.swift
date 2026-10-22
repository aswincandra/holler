import SwiftUI

/// Bardi-inspired colors, matching the design canvas.
enum Theme {
    static let teal = Color(hex: 0x0B7A83)       // primary buttons, playing state
    static let tealDeep = Color(hex: 0x0F5F66)   // app icon tile
    static let tealTint = Color(hex: 0xEAF4F5)   // playing row
    static let orange = Color(hex: 0xE5531A)     // play buttons
    static let ink = Color(hex: 0x1F2A30)
    static let muted = Color(hex: 0x5B6B73)
    static let line = Color(hex: 0xE3E8EA)
    static let outline = Color(hex: 0xC9D4D7)
    static let surface = Color(hex: 0xF2F6F7)
    static let ok = Color(hex: 0x1FA971)
    static let danger = Color(hex: 0xB42318)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// "0:09", "1:20"
func formatDuration(_ seconds: Double?) -> String {
    guard let s = seconds, s.isFinite else { return "–" }
    let total = Int(s.rounded())
    return "\(total / 60):" + String(format: "%02d", total % 60)
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(Theme.teal.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(configuration.isPressed ? Theme.surface : .white, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.outline))
    }
}

/// Round orange play button that turns into a teal stop button while playing.
struct PlayButton: View {
    var isPlaying: Bool
    var isBusy: Bool
    var size: CGFloat = 36
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(isPlaying || isBusy ? Theme.teal : Theme.orange)
                if isBusy {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                        .font(.system(size: size * 0.36, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPlaying ? "Stop" : "Play")
    }
}
