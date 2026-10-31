import AVFoundation
import SwiftUI
import UIKit
import HomifyCore

/// Bare AVPlayerLayer host. The same AVPlayer can drive several layers
/// (inline preview and fullscreen) without a second decoder.
final class PlayerLayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.backgroundColor = .black
        v.playerLayer.videoGravity = .resizeAspect
        v.playerLayer.player = player
        return v
    }

    func updateUIView(_ v: PlayerLayerView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
    }
}

/// Fixed-height preview: it never shrinks when tracks are added because the
/// timeline below scrolls independently.
struct PreviewArea: View {
    @ObservedObject var vm: EditorViewModel
    @Binding var fullscreen: Bool

    var body: some View {
        ZStack {
            Color.black
            let ratio = CGFloat(vm.project.aspectRatio.widthOverHeight)
            ZStack {
                PlayerSurface(player: vm.playback.player)
                if vm.project.duration == .zero {
                    VStack(spacing: 8) {
                        Image(systemName: "film.stack").font(.system(size: 34, weight: .light))
                        Text("Add a video to start").font(.footnote)
                    }
                    .foregroundStyle(.secondary)
                }
                if vm.showSafeArea { SafeAreaGuide() }
            }
            .aspectRatio(ratio, contentMode: .fit)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.white.opacity(0.08), lineWidth: 1))
            .padding(.vertical, 6)
        }
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 6) {
                Button { vm.showSafeArea.toggle() } label: {
                    Image(systemName: vm.showSafeArea ? "rectangle.inset.filled" : "rectangle.dashed")
                }
                .accessibilityLabel("Subtitle safe area")
                Button { fullscreen = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .accessibilityLabel("Fullscreen")
            }
            .buttonStyle(OverlayButtonStyle())
            .padding(8)
        }
        .contentShape(Rectangle())
        .onTapGesture { vm.togglePlay() }
    }
}

/// Title-safe (90 %) and action-safe (80 %) guides, plus a lower-third band
/// where subtitles normally sit.
struct SafeAreaGuide: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                Rectangle().stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .frame(width: w * 0.9, height: h * 0.9)
                Rectangle().stroke(style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    .frame(width: w * 0.8, height: h * 0.8)
                Rectangle().fill(Color.yellow.opacity(0.10))
                    .frame(width: w * 0.8, height: h * 0.12)
                    .position(x: w / 2, y: h * 0.78)
            }
            .frame(width: w, height: h)
            .foregroundStyle(Color.yellow.opacity(0.7))
        }
        .allowsHitTesting(false)
    }
}

struct FullscreenPlayer: View {
    @ObservedObject var vm: EditorViewModel
    @ObservedObject var playback: PlaybackEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerSurface(player: vm.playback.player)
                .aspectRatio(CGFloat(vm.project.aspectRatio.widthOverHeight), contentMode: .fit)
                .ignoresSafeArea()
            if !playback.isPlaying {
                Image(systemName: "play.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white.opacity(0.85))
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { vm.togglePlay() }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(OverlayButtonStyle())
                .padding()
        }
        .statusBarHidden()
    }
}

struct OverlayButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(Circle().fill(Color.black.opacity(configuration.isPressed ? 0.75 : 0.5)))
    }
}

struct TimecodeLabel: View {
    @ObservedObject var clock: PlaybackClock
    let duration: Time
    let fps: Int

    var body: some View {
        HStack(spacing: 4) {
            Text(Timecode.string(clock.time, fps: fps)).foregroundStyle(.white)
            Text("/").foregroundStyle(.secondary)
            Text(Timecode.string(duration, fps: fps)).foregroundStyle(.secondary)
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .monospacedDigit()
    }
}

struct TimelineRepresentable: UIViewRepresentable {
    @ObservedObject var vm: EditorViewModel

    func makeUIView(context: Context) -> TimelineView {
        let v = TimelineView()
        vm.timeline.view = v
        v.mediaURL = { [weak vm] m in vm?.mediaURL(m) ?? URL(fileURLWithPath: "/dev/null") }
        v.onScrubBegan = { [weak vm] in vm?.scrubBegan() }
        v.onScrub = { [weak vm] t in vm?.scrub(to: t) }
        v.onSelect = { [weak vm] id in vm?.selectedClipID = id }
        v.onTrim = { [weak vm] id, edge, t, phase in vm?.trim(clipID: id, edge: edge, to: t, phase: phase) }
        v.onMoveMain = { [weak vm] id, index in vm?.moveMain(clipID: id, to: index) }
        v.onMoveLayered = { [weak vm] id, start, track in vm?.moveLayered(clipID: id, start: start, trackID: track) }
        v.onToggleMute = { [weak vm] id in vm?.toggleMute(trackID: id) }
        v.onToggleLock = { [weak vm] id in vm?.toggleLock(trackID: id) }
        return v
    }

    func updateUIView(_ v: TimelineView, context: Context) {
        v.update(project: vm.project, selectedClipID: vm.selectedClipID)
    }
}
