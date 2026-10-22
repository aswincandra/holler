import Foundation

/// Logs to the console and to ~/Library/Logs/BardiSpeak.log, so logs survive
/// however the app was started (Finder, Terminal, login item).
func appLog(_ message: String) {
    NSLog("%@", message)
    let line = Date.now.formatted(date: .omitted, time: .standard) + " " + message + "\n"
    let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/BardiSpeak.log")
    guard let data = line.data(using: .utf8) else { return }
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile()
        h.write(data)
        try? h.close()
    } else {
        // Only this user can read the log (it names the cameras).
        FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
    }
}
