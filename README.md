# Homify Studio — native iOS video editor

A lightweight, offline-first video editor written in Swift for iPhone 14 (iOS 17+).
It uses SwiftUI and UIKit for the interface, AVFoundation for editing and
export, and Core Image on Metal for compositing. It has **no** WebView, no
browser engine, no analytics and no login.

## Status: Phase 1 (core editor) and part of Phase 2

Each feature below works end to end and has tests where it can be tested
automatically. "Device-verified" will be added only after testing on a real iPhone 14.

| Feature | State |
|---|---|
| Project library: create (9:16, 1:1, 16:9, 4:5), open, rename, duplicate, delete | ✅ |
| Import video from Photos (multi-select) and from Files; import audio from Files | ✅ |
| Originals preserved; all edits non-destructive; autosave after every edit (atomic) | ✅ |
| Preview with play/pause, fullscreen, timecode, subtitle safe-area guides | ✅ |
| Timeline: centre playhead, inertial scroll, pinch zoom, frame-snapped scrubbing | ✅ |
| Magnetic main track (ripple), split at playhead, trim handles, duplicate, delete | ✅ |
| Long-press drag: reorder main clips; move audio clips in time and across tracks | ✅ |
| Magnetic snapping to clip edges and the playhead, with haptics | ✅ |
| Multiple audio tracks, track mute and lock, clip volume, equal-power fade in/out | ✅ |
| Undo / redo (200 steps) | ✅ |
| Export H.264 MP4, 720p/1080p, 30/60 fps, progress, cancel, Save to Photos, Share | ✅ |
| Keyframe engine (auto-keyframe, easing, cubic Bézier, copy/paste, move/delete) | ✅ in core + tests; editor UI is Phase 3 |
| Overlay track rendering (compositor + render plan) | ✅ in engine; "add overlay" UI waits for the transform tools (Phase 3) |
| Waveforms, sound-effect library, crossfade UI | Phase 2 (next) |
| Transform gestures and the keyframe UI on the preview | Phase 3 |
| Speed and velocity, effects, text and subtitles | Phase 4 |
| Proxy media, profiling HUD, thermal testing | Phase 5 |

## Build

- **iPhone only (no Mac):** see [docs/CLOUD_BUILD.md](docs/CLOUD_BUILD.md). GitHub
  Actions builds on macOS and uploads to TestFlight.
- **On a Mac:** `brew install xcodegen && xcodegen generate && open HomifyStudio.xcodeproj`
- **Core tests on any OS with Swift 5.9+:** `cd Packages/HomifyCore && swift test`

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the design.

## Known limitations (honest list)

- HDR (Dolby Vision/HLG) clips from the iPhone camera are converted to SDR (Rec. 709) in preview and export.
- Export needs the app to stay in the foreground. iOS doesn't give background apps GPU access, so leaving the app makes the export fail with a message.
- While dragging a trim handle, the preview shows the new frame only after you release.
- No performance numbers have been measured on an iPhone 14 yet (see the Phase 5 plan in CLOUD_BUILD.md §7).
