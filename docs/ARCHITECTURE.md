# Architecture

```
┌──────────────────────────── iOS app (App/HomifyStudio) ────────────────────────────┐
│ SwiftUI: ProjectListView · EditorView · ExportSheet · AudioPanel                   │
│ UIKit:   TimelineView (UIScrollView, centre playhead, tile-based thumbnails)       │
│ EditorViewModel  ── perform(edit) → new Project value → undo snapshot              │
│        │                         → debounced autosave (atomic JSON)                │
│        │                         → debounced composition rebuild                   │
│ Engine: CompositionBuilder (actor) → AVMutableComposition + AudioMix               │
│         HomifyCompositor (AVVideoCompositing, Core Image on Metal)                 │
│         PlaybackEngine (AVPlayer, chase-seek scrubbing)                            │
│         VideoExporter (AVAssetExportSession → H.264 MP4)                           │
│         ThumbnailProvider (async AVAssetImageGenerator + NSCache)                  │
└──────────────────────────────────────┬─────────────────────────────────────────────┘
                                       │ depends on
┌──────────────────────── HomifyCore (Swift package, Foundation only) ───────────────┐
│ Time (exact 1/120000 s) · Project/Track/Clip/MediaAsset · Editing ops · Snapping   │
│ EditHistory · Keyframes/Easing/CubicBezier · AudioMath · LayerGeometry             │
│ RenderPlan (lanes, segments, volume ramps) · ProjectStore                          │
└────────────────────────────────────────────────────────────────────────────────────┘
```

## Key decisions

- **Non-destructive editing.** A project is a small value type (`Project`) that
  describes the edit. Imported media is copied into the project folder once and
  is never modified. Each edit produces a new `Project`. Undo restores a
  snapshot; because `Project` uses copy-on-write arrays, snapshots are cheap.
- **Exact time.** `Time` is an `Int64` count on a 120,000 Hz timescale. Frames at
  24, 25, 30, 50 and 60 fps land on exact integers, so cuts never drift.
- **Platform-free core.** All editing logic, keyframe maths, audio envelopes and
  render planning live in `HomifyCore` and are unit-tested on Linux. The iOS
  layer only translates a `RenderPlan` into AVFoundation objects.
- **One render path.** Preview and export use the same `CompositionBuilder` and
  `HomifyCompositor`. Preview renders at 720p-class size, while export renders
  at full size from the **original** media. Timing, transforms and audio
  therefore match.
- **Keyframes live on clips.** No adjustment layer is needed. Keyframe times are
  stored in *source-media time*, so trimming or splitting a clip never shifts its
  animation relative to the picture. Auto-keyframe mode creates or updates
  keyframes. With auto-keyframe off, the app never creates a keyframe: a static
  property is simply set, and an animated property is offset as a whole.
- **Audio.** Fades use an equal-power (sine/cosine) curve, approximated with 8
  linear volume-ramp segments per fade. A crossfade is two overlapping clips on
  different lanes with complementary curves, so out² + in² = 1 and the overlap
  has no loudness dip.
- **Timeline performance.** The timeline uses UIKit, not SwiftUI. Clip views are
  reused across updates, and only thumbnail tiles inside the visible window
  (+50%) exist. Thumbnails are quantised to 0.25 s and cached in `NSCache`,
  which is purged on memory warnings. Playback drives the timeline with a
  `CADisplayLink`. The 60 Hz time updates go to a separate `PlaybackClock`
  object, so only the timecode label re-renders.
- **Scrubbing.** Precise seeks are coalesced ("chase seek"): the next seek
  starts only after the previous one finishes, so the decoder never queues up
  stale frames.

## Folder layout

```
project.yml                 XcodeGen spec (the .xcodeproj is generated, not committed)
Packages/HomifyCore/        platform-independent engine + 53 unit tests
App/HomifyStudio/           iOS app sources and assets
App/HomifyStudioTests/      simulator integration tests (real AVFoundation export)
.github/workflows/          CI and TestFlight pipelines
docs/                       this documentation
```
