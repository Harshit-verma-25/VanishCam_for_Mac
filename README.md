# VanishCam for macOS

A native macOS take on the Windows [vanish_webcam](https://github.com/Nicovic17/vanish_webcam) idea, written from scratch in Swift.
VanishCam installs a virtual camera called **Vanish Camera**. Pick it once in Zoom / Meet / Teams / FaceTime / Photo Booth,
and the effects work whenever that app turns the camera on. The VanishCam app doesn't need to be running.

| Mode | Gesture (toggle: do it again to reappear) | Effect |
|---|---|---|
| Normal Vanish | V sign (index + middle apart) | Noisy dissolve with a glowing edge |
| Particles | V sign | You break into fragments drifting on the wind |
| Goku Teleport | Index + middle together on your forehead, hold 1 s | Comic streaks, then you're gone |
| Naruto Substitution | Palms pressed together, fingers up | Smoke burst, a log falls where you stood |

Everything runs on-device with Apple's Vision framework (hand pose, face, person segmentation) and Metal Core Image kernels.
Nothing is recorded or uploaded.

## How it works

```
Zoom/Meet ──opens──▶ Vanish Camera (CoreMediaIO camera extension, runs on demand)
                          │
                          ├─ AVCaptureSession on the real FaceTime/USB camera
                          ├─ Vision: person mask every frame when needed, hand pose ~15×/s
                          ├─ Background model: learns the empty room where you're not standing,
                          │  fills never-seen spots by blurring nearby pixels, saved to disk
                          └─ Metal CIKernels: dissolve / particles / goku / smoke + log
VanishCam.app ──CMIO custom properties──▶ mode, commands (recapture/vanish/reappear), status
```

## Requirements

- macOS 13 Ventura or later (Apple Silicon recommended)
- Xcode 15 or later
- **An Apple Developer Program membership ($99/yr).** System extensions need the
  `System Extension` capability, which free Personal Teams generally can't sign. Try it with your free
  account first. If Xcode says the capability or provisioning profile isn't supported, this is why.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Build & install

1. Open `project.yml` and set `DEVELOPMENT_TEAM` to your Team ID (Xcode → Settings → Accounts → your team).
   Optionally change `com.harshitverma.VanishCam`. If you do, change it in both targets and keep
   the extension id = app id + `.CameraExtension`.
2. Generate and open the project:
   ```bash
   cd VanishCamMac
   xcodegen generate
   open VanishCam.xcodeproj
   ```
3. Select the **VanishCam** scheme → Product → Build (⌘B).
4. Product → Show Build Folder in Finder → `Products/Debug/VanishCam.app` → **copy it to `/Applications`**.
   macOS refuses to install system extensions from anywhere else.
5. Open `/Applications/VanishCam.app` → **Install Camera Extension**.
6. Approve it:
   - macOS 15+: System Settings → General → Login Items & Extensions → Camera Extensions → enable VanishCam
   - macOS 13/14: System Settings → Privacy & Security → "System software from … was blocked" → Allow
7. Allow camera access when asked (for the app preview and for the extension).
8. Quit and reopen your meeting app, then choose **Vanish Camera** in its video settings.

**First use:** click **Recapture background** in the app, step out of frame for about 7 s, then come back.
The background is remembered across restarts, so you only redo this when the camera or room changes.
Without it, VanishCam still learns the room as you move around and fills the spot behind you with a blur.

### Updating after code changes

Rebuild, copy to `/Applications` again (replace), open it and click **Reinstall**.
Every build gets a unique build number automatically, so macOS swaps in the new extension.

## Local build (no Apple Developer account)

`VanishCamLocal` runs the same engine inside a normal ad-hoc signed app and shows the effects in its own window.
It has no system-wide virtual camera, so "Vanish Camera" only appears in Google Meet, through the Chrome extension.

```bash
xcodegen generate
xcodebuild -project VanishCam.xcodeproj -scheme VanishCamLocal -configuration Debug -derivedDataPath build build
ditto build/Build/Products/Debug/VanishCamLocal.app /Applications/VanishCamLocal.app
open /Applications/VanishCamLocal.app
```

**Google Meet:** in Chrome, open `chrome://extensions`, turn on Developer mode, click **Load unpacked** and pick the
`ChromeExtension` folder. Reload Meet and choose **Vanish Camera** in its camera list. Keep the app open during the call.
The app streams to the extension over `127.0.0.1:47831` and only accepts connections from `https://meet.google.com`.

**Zoom and other apps:** click **Open Output Window**, add that window to OBS with Window Capture, click
**Start Virtual Camera** in OBS, then pick **OBS Virtual Camera** in your meeting app.

Ad-hoc signatures change on every rebuild, so macOS may ask for camera access again after you rebuild.

## Troubleshooting

| Problem | Fix |
|---|---|
| "Move VanishCam.app to /Applications" | Run the copy in /Applications, not the one in DerivedData |
| Vanish Camera missing in Zoom/Chrome | Quit and reopen the app (camera lists are read at launch). Check `systemextensionsctl list` |
| Black frame saying "Camera access needed" | System Settings → Privacy & Security → Camera → allow VanishCam |
| Ghost or blur where you were | Click Recapture background and stay fully out of frame |
| Gesture doesn't fire | Good light, hand clearly in frame, hold still. Watch the hand meter in the app |

Logs: `log stream --predicate 'subsystem == "VanishCam.Extension"'`

Uninstall: the **Uninstall** button in the app, or delete VanishCam.app from /Applications.

## Project layout

```
project.yml                 XcodeGen spec (app + system extension)
Shared/VanishShared.swift   modes, commands, status, IPC names (compiled into both targets)
App/                        SwiftUI host app: install, mode picker, preview, controls
Local/                      Local build: engine runs in the app, no extension or Apple account
ChromeExtension/            Adds Vanish Camera to Google Meet, fed by the local build
Extension/
  main.swift                extension entry point
  VanishProvider.swift      CMIO provider / device / stream + custom properties
  CameraCapture.swift       real-camera capture (skips virtual cameras)
  VanishEngine.swift        frame pipeline, background model, phases, compositing
  GestureDetector.swift     V sign, palms together, Goku forehead (Vision)
  EffectKernels.swift       Swift wrappers + Core Graphics log art
  Effects.metal             Core Image Metal kernels
```
