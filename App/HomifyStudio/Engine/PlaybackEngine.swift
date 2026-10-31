import AVFoundation
import Combine
import HomifyCore

/// Owns the AVPlayer. Scrubbing uses "chase" seeking: while one precise seek
/// is in flight, newer requests only update the target, so the decoder is
/// never flooded and the preview keeps up with the finger without freezing.
@MainActor
final class PlaybackEngine: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var isPlaying = false
    private var chaseTarget: CMTime = .zero
    private var isSeeking = false
    private var endObserver: NSObjectProtocol?

    init() {
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = false
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let item = note.object as? AVPlayerItem, item === self.player.currentItem else { return }
                self.isPlaying = false
            }
        }
    }

    deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    var currentTime: Time { Time(player.currentTime()) }

    var duration: Time {
        guard let d = player.currentItem?.asset.duration, d.isNumeric else { return .zero }
        return Time(d)
    }

    func load(_ built: BuiltComposition?, at time: Time) {
        guard let built else {
            pause()
            player.replaceCurrentItem(with: nil)
            return
        }
        let item = AVPlayerItem(asset: built.composition)
        item.videoComposition = built.videoComposition
        item.audioMix = built.audioMix
        item.seekingWaitsForVideoCompositionRendering = true
        item.preferredForwardBufferDuration = 2
        let resume = isPlaying
        player.replaceCurrentItem(with: item)
        chaseTarget = time.cmTime
        isSeeking = false
        player.seek(to: time.cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in if resume { self?.player.play() } }
        }
    }

    func play() {
        guard player.currentItem != nil else { return }
        let d = duration
        if d > .zero, currentTime >= d - Time.frame(60) {
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func toggle() { isPlaying ? pause() : play() }

    func seek(to t: Time) {
        let target = t.cmTime
        guard CMTimeCompare(target, chaseTarget) != 0 || !isSeeking else { return }
        chaseTarget = target
        if !isSeeking { seekToChaseTarget() }
    }

    private func seekToChaseTarget() {
        guard player.currentItem != nil else { return }
        isSeeking = true
        let target = chaseTarget
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if CMTimeCompare(target, self.chaseTarget) == 0 {
                    self.isSeeking = false
                } else {
                    self.seekToChaseTarget()
                }
            }
        }
    }
}
