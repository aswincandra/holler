import AppKit
import AVFoundation
import WebKit

/// Owns the hidden WKWebView that runs the Bardi portal plus our injected bridge.js.
/// Connects to the camera on demand and drops the stream after an idle period.
@MainActor
final class Portal: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    enum Camera: Equatable { case signedOut, idle, connecting, connected }

    @Published var camera: Camera = .idle      // state of the selected camera
    @Published var cameras: [String] = []      // names from the portal's device list
    @Published var loadingCameras = false      // the camera list is being read from the portal
    @Published var playingID: UUID?
    @Published var playStarted: Date?
    @Published var playDuration: Double = 0
    @Published var busyID: UUID?          // preset waiting for the camera to connect
    @Published var talking = false        // Hold to Talk: the Mac's mic is live
    @Published var talkPending = false
    @Published var lastError: String?

    /// The camera that presets and Hold to Talk go to.
    var cameraName: String {
        get { UserDefaults.standard.string(forKey: "cameraName") ?? cameras.first ?? "IDR-IPC-PTZ" }
        set { UserDefaults.standard.set(newValue, forKey: "cameraName"); objectWillChange.send() }
    }
    private var cameraStates: [String: Camera] = [:]
    private var listReloads = 0           // reloads in a row because the camera list didn't load

    func selectCamera(_ name: String) {
        guard name != cameraName else { return }
        cameraName = name
        if camera != .signedOut { camera = cameraStates[name] ?? .idle }
    }

    /// Ask the page for the camera names under "All Devices".
    func refreshCameras() async {
        guard !loadingCameras else { return }
        loadingCameras = true
        defer { loadingCameras = false }
        let started = ContinuousClock.now
        let list = (try? await webView.callAsyncJavaScript(
            "return await window.__bardi.devices()", contentWorld: .page) as? [String]) ?? []
        try? await Task.sleep(until: started + .milliseconds(600))  // so a fast refresh still shows feedback
        guard !list.isEmpty else {
            // The portal's own API calls can fail (seen after a server outage) and it never
            // retries them, so the list stays empty. Reload at most twice, with long waits so we
            // don't add load to a struggling server, and never while the user is playing or talking.
            guard camera != .signedOut, listReloads < 2 else { return }
            listReloads += 1
            let wait = listReloads == 1 ? 10 : 30
            appLog("[portal] no cameras; reload \(listReloads)/2 in \(wait) s")
            try? await Task.sleep(for: .seconds(wait))
            guard !isBusy else { appLog("[portal] busy, skipping reload"); return }
            webView.reload()
            return
        }
        listReloads = 0
        cameras = list
        if !list.contains(cameraName) { selectCamera(list[0]) }
    }

    /// A preset or talk is starting or running, so the page must not reload.
    private var isBusy: Bool { busyID != nil || playingID != nil || talking || talkPending }

    /// Close the stream after this long without playing, so we don't stream video all day.
    let idleTimeout: Duration = .seconds(120)

    let webView: WKWebView
    private var window: NSWindow?
    private var idleTask: Task<Void, Never>?
    private var allowMic = false          // true only while a talk is starting or running
    private var talkGen = 0               // bumped on every press and release; a stale talkStart gives up
    private var talkLimit: Task<Void, Never>?
    private let maxTalk: Duration = .seconds(60)
    private var captureWatch: [NSKeyValueObservation] = []
    private static let portalURL = URL(string: "https://ipc.bardi.co.id/playback")!

    /// `offline: true` never loads the portal or makes its window (used to render README previews).
    init(offline: Bool = false) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()  // keeps the QR login between launches
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.inactiveSchedulingPolicy = .none  // keep WebRTC running while hidden
        let controller = WKUserContentController()
        if CommandLine.arguments.contains("--debug") {  // turns on network logging in bridge.js
            controller.addUserScript(WKUserScript(source: "window.__bardiDebug = true",
                                                  injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        // bridgeJS is compiled into the binary (see build_app.sh), so the code signature covers it.
        controller.addUserScript(WKUserScript(source: bridgeJS, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController = controller
        config.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"

        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 700), configuration: config)
        // Safari > Develop can attach only when launched with --debug.
        webView.isInspectable = CommandLine.arguments.contains("--debug")
        // WebKit slows a page down a lot when its window is covered or hidden.
        // Turn occlusion detection off (private API, so check that it exists).
        if webView.responds(to: Selector(("_setWindowOcclusionDetectionEnabled:"))) {
            webView.setValue(false, forKey: "windowOcclusionDetectionEnabled")
        }
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        controller.add(self, name: "bardi")
        watchCapture()
        guard !offline else { return }
        makeWindow()
        webView.load(URLRequest(url: Self.portalURL))
    }

    // MARK: Window
    // The portal window is never ordered out: a hidden page runs its timers very slowly,
    // which made playback wait for minutes. When not shown, it is a "ghost":
    // on screen but fully transparent, click-through, and on every Space.

    private func makeWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                         styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Camera Portal — Bardi Speak"
        w.isReleasedWhenClosed = false
        w.contentView = webView
        w.delegate = self
        w.center()
        window = w
        hideWindow()
    }

    func showWindow() {
        guard let w = window else { return }
        w.alphaValue = 1
        w.ignoresMouseEvents = false
        w.level = .normal
        w.collectionBehavior = [.managed]
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func hideWindow() {
        guard let w = window else { return }
        w.alphaValue = 0
        w.ignoresMouseEvents = true
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .transient, .fullScreenAuxiliary]
        w.orderFrontRegardless()
    }

    // MARK: Playback

    func toggle(_ preset: Preset, file: URL, onPlayed: @escaping (UUID) -> Void) {
        guard busyID == nil else { return }  // a preset is still connecting
        if playingID == preset.id {
            Task { await stop() }
        } else {
            Task { await play(preset, file: file, onPlayed: onPlayed) }
        }
    }

    func play(_ preset: Preset, file: URL, onPlayed: (UUID) -> Void) async {
        lastError = nil
        idleTask?.cancel()
        if camera == .signedOut {
            lastError = "Sign in needed. Scan the QR code in the camera portal."
            showWindow()
            return
        }
        busyID = preset.id
        defer { busyID = nil }
        guard let data = try? Data(contentsOf: file) else {
            lastError = "Could not read the preset file."
            return
        }
        let b64 = data.base64EncodedString()
        for attempt in 1...2 {
            do {
                _ = try await webView.callAsyncJavaScript(
                    "await window.__bardi.connect(camera); return await window.__bardi.play(id, b64, camera)",
                    arguments: ["camera": cameraName, "id": preset.id.uuidString, "b64": b64],
                    contentWorld: .page)
                onPlayed(preset.id)
                return
            } catch {
                // The page reloaded during the call ("Completion handler ... no longer reachable"):
                // the new page is fine, so try once more.
                if attempt == 1, error.localizedDescription.contains("no longer reachable") {
                    appLog("[portal] page reloaded during play; retrying")
                    try? await Task.sleep(for: .seconds(2))
                    continue
                }
                lastError = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
                    ?? error.localizedDescription
                appLog("[portal] play failed: " + (lastError ?? ""))
                scheduleIdleDisconnect()
                return
            }
        }
    }

    // MARK: Live talk

    func talkStart() async {
        guard !talkPending, !talking else { return }
        lastError = nil
        idleTask?.cancel()
        if camera == .signedOut {
            lastError = "Sign in needed. Scan the QR code in the camera portal."
            showWindow()
            return
        }
        talkGen += 1
        let gen = talkGen
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            lastError = "Microphone access is off. Turn it on in System Settings › Privacy & Security › Microphone."
            return
        }
        // Released while macOS was asking for permission: don't open the mic.
        guard gen == talkGen else { return }
        talkPending = true
        allowMic = true
        defer { talkPending = false }
        do {
            _ = try await webView.callAsyncJavaScript(
                "return await window.__bardi.talkStart(camera)",
                arguments: ["camera": cameraName], contentWorld: .page)
        } catch {
            allowMic = false
            lastError = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
                ?? error.localizedDescription
            appLog("[portal] talk failed: " + (lastError ?? ""))
        }
    }

    func talkStop() async {
        talkGen += 1
        allowMic = false
        talkLimit?.cancel()
        _ = try? await webView.callAsyncJavaScript("await window.__bardi.talkStop()", contentWorld: .page)
        await webView.setMicrophoneCaptureState(.none)  // hard stop, even if the page kept a track
        scheduleIdleDisconnect()
    }

    // WebKit keeps a mic grant until the page reloads, and iframes have the real
    // getUserMedia. So watch the web view itself: the camera may never be on,
    // and the mic only while Hold to Talk allows it.
    private func watchCapture() {
        captureWatch = [
            webView.observe(\.microphoneCaptureState, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.enforceCapture() }
            },
            webView.observe(\.cameraCaptureState, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.enforceCapture() }
            },
        ]
    }

    private func enforceCapture() {
        if webView.cameraCaptureState != .none {
            appLog("[guard] page turned the camera on; forcing it off")
            webView.setCameraCaptureState(.none)
        }
        if webView.microphoneCaptureState != .none && !allowMic {
            appLog("[guard] page turned the mic on outside Hold to Talk; forcing it off")
            webView.setMicrophoneCaptureState(.none)
        }
    }

    func stop() async {
        _ = try? await webView.callAsyncJavaScript("await window.__bardi.stop()", contentWorld: .page)
    }

    /// Reloading the page is the simplest clean way to close the live stream.
    func disconnect() {
        idleTask?.cancel()
        guard camera == .connected || camera == .connecting else { return }
        camera = .idle
        webView.reload()
    }

    private func scheduleIdleDisconnect() {
        idleTask?.cancel()
        idleTask = Task { [weak self, idleTimeout] in
            try? await Task.sleep(for: idleTimeout)
            guard !Task.isCancelled, let self, self.playingID == nil, self.busyID == nil,
                  !self.talking, !self.talkPending else { return }
            appLog("[portal] idle, closing stream")
            self.disconnect()
        }
    }

    // MARK: Messages from bridge.js (WebKit delivers them on the main thread)

    nonisolated func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "log":
                appLog("[bridge] " + (body["text"] as? String ?? ""))
            case "route":
                let path = body["path"] as? String ?? ""
                appLog("[portal] route \(path)")
                if path.hasPrefix("/login") {
                    camera = .signedOut
                } else {
                    if camera == .signedOut {
                        camera = .idle
                        hideWindow()  // signed in: the portal can go back into hiding
                    }
                    Task { await refreshCameras() }
                }
            case "camera":
                let state: Camera
                switch body["state"] as? String {
                case "connected": state = .connected
                case "connecting", "new": state = .connecting
                default: state = .idle
                }
                let device = body["device"] as? String
                if let device { cameraStates[device] = state }
                if (device == nil || device == cameraName) && camera != .signedOut { camera = state }
            case "session":
                // The server ended this login. Go to the QR page so the user can sign in again.
                guard camera != .signedOut else { break }
                appLog("[portal] session invalid; opening login")
                camera = .signedOut
                lastError = "Signed out. The Bardi portal allows one web login at a time, so a login in Chrome or elsewhere ends this one. Scan the QR code again."
                webView.load(URLRequest(url: URL(string: "https://ipc.bardi.co.id/login")!))
            case "talking":
                talking = body["on"] as? Bool ?? false
                talkLimit?.cancel()
                if talking {  // safety net if the release never arrives
                    talkLimit = Task { [weak self, maxTalk] in
                        try? await Task.sleep(for: maxTalk)
                        guard !Task.isCancelled, let self, self.talking else { return }
                        appLog("[portal] talk hit the time limit, stopping")
                        await self.talkStop()
                    }
                }
            case "playing":
                if let id = (body["id"] as? String).flatMap(UUID.init) {
                    playingID = id
                    playStarted = .now
                    playDuration = body["duration"] as? Double ?? 0
                } else {
                    playingID = nil
                    playStarted = nil
                    scheduleIdleDisconnect()
                }
            default:
                break
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            playingID = nil
            talking = false
            cameraStates = [:]
            if camera != .signedOut { camera = .idle }
        }
    }

    // Diagnostics: why a page load fails (HTTP status, network errors).
    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                             decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        MainActor.assumeIsolated {
            if let r = navigationResponse.response as? HTTPURLResponse {
                appLog("[portal] load \(r.statusCode) \(r.url?.path ?? "")")
            }
            decisionHandler(.allow)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { appLog("[portal] load failed: \(error.localizedDescription)") }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { appLog("[portal] page failed: \(error.localizedDescription)") }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated { appLog("[portal] web content process crashed; reloading") }
        Task { @MainActor in webView.reload() }
    }

    // Closing the portal window only turns it back into the ghost window.
    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated { hideWindow() }
        return false
    }

    // The page may open the Mac's mic only while Hold to Talk is starting or running.
    // Every other mic or camera request is denied.
    nonisolated func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                             initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                             decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        MainActor.assumeIsolated {
            let grant = allowMic && type == .microphone
            appLog("[portal] \(grant ? "granted" : "denied") page request for mic/camera (type \(type.rawValue))")
            decisionHandler(grant ? .grant : .deny)
        }
    }
}
