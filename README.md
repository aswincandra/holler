# holler

Holler at home from your Mac. **Bardi Speak** is a macOS menu-bar app and desktop
widget that plays saved audio clips ("presets") through the speaker of a home
security camera, with one click.

> **Works only with Bardi cameras.** The app drives the official Bardi web portal
> (`ipc.bardi.co.id`), so it has only been tested with a Bardi IDR-IPC-PTZ camera
> on a Bardi account. Other Tuya-based brands may use a similar portal, but they
> are untested.
>
> This is an unofficial personal project. It is not made, approved or supported by
> Bardi or Tuya. The portal can change at any time and break it.

## Features

- **Preset Audio Player**: add `.m4a`, `.wav` or `.mp3` files, rename and delete
  them, and play them on the camera.
- **Record Preset**: record a new clip with the Mac's microphone.
- **Hold to Talk**: live talk through the camera, only while you hold the button.
- **Several cameras**: choose which camera to speak to.
- **Desktop widget**: medium and large sizes with one-tap play buttons. If the app
  isn't running, a tap starts it and plays the clip.
- The camera keeps working in the Bardi phone app for everyone else. Nothing is
  re-paired.

## How it works

The Bardi portal is a web app that streams live view over WebRTC.
Bardi Speak loads it in a hidden `WKWebView` and injects a script (`bridge.js`):

1. The page's `getUserMedia` is replaced, so the page gets a Web Audio track
   instead of the real microphone.
2. To play a preset, the app decodes the file into an `AudioBuffer`, plays it into
   that track, and calls `RTCRtpSender.replaceTrack()` on the camera's audio
   sender. The camera hears it like the portal's own talk button.
3. After 2 minutes without use, the app closes the stream.

The portal window stays "on screen" but fully transparent. A hidden page
throttles its timers, which made playback wait for minutes.

See [`feasibility/FINDINGS.md`](feasibility/FINDINGS.md) for the protocol notes.

## Privacy and security

- **Mac microphone**: used only during Record Preset and while Hold to Talk is held.
  The app grants the page mic access only during Hold to Talk, and it watches
  the web view's capture state. If anything turns the mic on at another time, the
  app forces it off. Talk also stops by itself after 60 seconds.
- **Mac camera**: never used. The app has no camera permission, and the web
  view's camera is forced off.
- **Camera sound on the Mac**: muted, so a preset doesn't echo back through
  the Mac speakers.
- `bridge.js` is compiled into the binary, so the code signature covers it.
- The log (`~/Library/Logs/BardiSpeak.log`) is readable only by you. It never
  contains tokens or cookies. Network logging is on only with `--debug`.

## Build

Requirements: macOS 14+ (tested on macOS 27), Xcode 27, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`), and an Apple ID added in **Xcode › Settings › Accounts**
with an *Apple Development* certificate (a free account works).

```sh
cd BardiSpeak
./build_app.sh               # build, install to /Applications, relaunch
./build_app.sh --no-install  # build only
```

`build_app.sh` finds your team ID automatically, or you can set `DEVELOPMENT_TEAM`.
It generates the Xcode project from `project.yml`, so edit that file, not the `.xcodeproj`.

First run: click the menu-bar icon, choose **Show Camera Portal…**, and scan
the QR code with the Bardi phone app.

## Known limits

- The portal allows **one web login per account**. Logging in from Chrome or
  another device signs the app out, and the app then asks you to scan the QR code again.
- If Bardi's servers are slow or down, the camera list can fail to load. The app
  reloads the portal up to 2 times.

## Project layout

```
BardiSpeak/
  project.yml          XcodeGen spec (app + widget)
  build_app.sh         build and install
  Sources/             app (SwiftUI menu bar, wide window, portal, recorder)
  Shared/              code used by the app and the widget
  Widget/              WidgetKit desktop widget
  Resources/bridge.js  script injected into the portal
  scripts/             build helpers
feasibility/           protocol notes and the test-only preset server
```
