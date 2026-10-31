import XCTest
@testable import HomifyCore

final class RenderTests: XCTestCase {
    func testEqualPowerIsConstantPower() {
        for i in 0...10 {
            let g = AudioMath.equalPowerGains(Double(i) / 10)
            XCTAssertEqual(g.out * g.out + g.in * g.in, 1, accuracy: 1e-12)
        }
    }

    func testClipGainFades() {
        let d = Time.seconds(4)
        XCTAssertEqual(AudioMath.clipGain(local: .zero, duration: d, volume: 1, fadeIn: .seconds(1), fadeOut: .seconds(1)), 0)
        XCTAssertEqual(AudioMath.clipGain(local: .seconds(2), duration: d, volume: 0.5, fadeIn: .seconds(1), fadeOut: .seconds(1)), 0.5)
        XCTAssertEqual(AudioMath.clipGain(local: d, duration: d, volume: 1, fadeIn: .zero, fadeOut: .seconds(1)), 0, accuracy: 1e-12)
    }

    func testVolumeRampsCoverClipExactly() {
        var c = Clip(mediaID: UUID(), sourceRange: TimeRange(start: .zero, duration: .seconds(4)), timelineStart: .seconds(10))
        c.volume = 0.8
        c.fadeIn = .seconds(1)
        c.fadeOut = .seconds(2)
        let ramps = RenderPlan.volumeRamps(for: c)
        XCTAssertEqual(ramps.first?.range.start, .seconds(10))
        XCTAssertEqual(ramps.last?.range.end, .seconds(14))
        for (a, b) in zip(ramps, ramps.dropFirst()) {
            XCTAssertEqual(a.range.end, b.range.start)
            XCTAssertEqual(a.endVolume, b.startVolume, accuracy: 1e-9, "continuous envelope")
        }
        XCTAssertEqual(ramps.first!.startVolume, 0)
        XCTAssertEqual(ramps.last!.endVolume, 0, accuracy: 1e-9)
        XCTAssertEqual(ramps.map(\.endVolume).max()!, 0.8, accuracy: 1e-9)
    }

    func testOverlongFadesAreScaled() {
        var c = Clip(mediaID: UUID(), sourceRange: TimeRange(start: .zero, duration: .seconds(2)), timelineStart: .zero)
        c.fadeIn = .seconds(3)
        c.fadeOut = .seconds(1)
        let f = c.effectiveFades
        XCTAssertEqual(f.fadeIn + f.fadeOut, .seconds(2))
        XCTAssertEqual(f.fadeIn, .seconds(1.5))
    }

    func testSegmentsAreContiguousAndStackLayers() throws {
        var (p, ids) = Fixtures.project([3, 3])
        let ov = Fixtures.video(2, audio: false)
        p.addMedia(ov)
        let overlay = try p.addLayeredClip(mediaID: ov.id, kind: .overlay, at: .seconds(2))
        let plan = RenderPlan.make(from: p)
        XCTAssertEqual(plan.duration, .seconds(6))
        XCTAssertEqual(plan.videoLanes.count, 2)
        XCTAssertEqual(plan.segments.first?.range.start, .zero)
        XCTAssertEqual(plan.segments.last?.range.end, .seconds(6))
        for (a, b) in zip(plan.segments, plan.segments.dropFirst()) { XCTAssertEqual(a.range.end, b.range.start) }
        XCTAssertEqual(plan.segments.map(\.range.start), [.zero, .seconds(2), .seconds(3), .seconds(4)])
        XCTAssertEqual(plan.segments[1].layers.map(\.clipID), [ids[0], overlay])
        XCTAssertEqual(plan.segments[2].layers.map(\.clipID), [ids[1], overlay])
        XCTAssertEqual(plan.segments[3].layers.map(\.clipID), [ids[1]])
        // Overlay has no audio → only the main lane is audible.
        XCTAssertEqual(plan.audioLanes.count, 1)
    }

    func testGapsProduceEmptySegments() throws {
        var p = Project(name: "x")
        let ov = Fixtures.video(1)
        p.addMedia(ov)
        try p.addLayeredClip(mediaID: ov.id, kind: .overlay, at: .seconds(2))
        let plan = RenderPlan.make(from: p)
        XCTAssertEqual(plan.segments.count, 2)
        XCTAssertEqual(plan.segments[0].layers, [])
    }

    func testMutedTrackIsSilent() {
        var (p, _) = Fixtures.project([3])
        p.setTrackMuted(p.mainTrack.id, true)
        let plan = RenderPlan.make(from: p)
        XCTAssertTrue(plan.audioLanes.isEmpty)
        XCTAssertEqual(plan.videoLanes.count, 1)
    }

    func testRenderSizes() {
        XCTAssertEqual(AspectRatio.portrait9x16.renderSize(shortSide: 1080), PixelSize(width: 1080, height: 1920))
        XCTAssertEqual(AspectRatio.landscape16x9.renderSize(shortSide: 720), PixelSize(width: 1280, height: 720))
        XCTAssertEqual(AspectRatio.portrait4x5.renderSize(shortSide: 1080), PixelSize(width: 1080, height: 1350))
        XCTAssertEqual(AspectRatio.square.renderSize(shortSide: 1080), PixelSize(width: 1080, height: 1080))
    }

    func testLayerTransformFitsAndCentres() {
        // 1920×1080 landscape video into a 1080×1920 portrait canvas.
        let m = LayerGeometry.layerTransform(sourceWidth: 1920, sourceHeight: 1080, canvasWidth: 1080, canvasHeight: 1920, transform: .identity)
        let centre = m.apply(960, 540)
        XCTAssertEqual(centre.x, 540, accuracy: 1e-9)
        XCTAssertEqual(centre.y, 960, accuracy: 1e-9)
        let left = m.apply(0, 540)
        XCTAssertEqual(left.x, 0, accuracy: 1e-9) // fits width exactly
    }

    func testLayerTransformUserOffsetAndRotation() {
        var v = TransformValue()
        v.positionX = 0.25
        v.positionY = 0.25   // down on screen = lower y in y-up space
        v.rotation = 90      // clockwise on screen
        let m = LayerGeometry.layerTransform(sourceWidth: 100, sourceHeight: 100, canvasWidth: 100, canvasHeight: 100, transform: v)
        let c = m.apply(50, 50)
        XCTAssertEqual(c.x, 75, accuracy: 1e-9)
        XCTAssertEqual(c.y, 25, accuracy: 1e-9)
        // The source's right-middle point should end up below the centre after a clockwise turn.
        let r = m.apply(100, 50)
        XCTAssertEqual(r.x, 75, accuracy: 1e-9)
        XCTAssertEqual(r.y, -25, accuracy: 1e-9)
    }

    func testQuarterTurns() {
        XCTAssertEqual(LayerGeometry.quarterTurns([1, 0, 0, 1, 0, 0]), 0)
        XCTAssertEqual(LayerGeometry.quarterTurns([0, 1, -1, 0, 1080, 0]), 1)
        XCTAssertEqual(LayerGeometry.quarterTurns([-1, 0, 0, -1, 1920, 1080]), 2)
        XCTAssertEqual(LayerGeometry.quarterTurns([0, -1, 1, 0, 0, 1920]), 3)
        let portrait = MediaAsset(kind: .video, fileName: "a", originalName: "a", duration: .seconds(1),
                                  naturalWidth: 1920, naturalHeight: 1080, preferredTransform: [0, 1, -1, 0, 1080, 0],
                                  hasVideo: true, hasAudio: false)
        XCTAssertEqual(portrait.displayWidth, 1080)
        XCTAssertEqual(portrait.displayHeight, 1920)
    }
}
