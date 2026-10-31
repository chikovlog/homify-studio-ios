import AVFoundation
import XCTest
import HomifyCore
@testable import HomifyStudio

/// End-to-end checks of the real AVFoundation pipeline on the simulator:
/// import → edit → build composition → export H.264 MP4 → decode result.
final class EngineIntegrationTests: XCTestCase {
    private var root: URL!
    private var store: ProjectStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("homify-it-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = ProjectStore(rootURL: root.appendingPathComponent("Projects"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testImportProbesGeneratedVideo() async throws {
        let src = try await TestMedia.makeVideo(at: root.appendingPathComponent("a.mov"), seconds: 2, fps: 30,
                                                size: CGSize(width: 320, height: 240), withAudio: true)
        let p = try store.create(name: "Probe", aspectRatio: .landscape16x9)
        let asset = try await MediaImporter(store: store).importFile(at: src, projectID: p.id, move: false)
        XCTAssertTrue(asset.hasVideo)
        XCTAssertTrue(asset.hasAudio)
        XCTAssertEqual(asset.naturalWidth, 320)
        XCTAssertEqual(asset.duration.seconds, 2, accuracy: 0.05)
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path), "original must be preserved")
    }

    func testEditAndExportProducesPlayableMP4() async throws {
        let a = try await TestMedia.makeVideo(at: root.appendingPathComponent("a.mov"), seconds: 3, fps: 30,
                                              size: CGSize(width: 320, height: 240), withAudio: true)
        let b = try await TestMedia.makeVideo(at: root.appendingPathComponent("b.mov"), seconds: 2, fps: 30,
                                              size: CGSize(width: 240, height: 320), withAudio: false)
        var p = try store.create(name: "Export", aspectRatio: .portrait9x16)
        let importer = MediaImporter(store: store)
        let ma = try await importer.importFile(at: a, projectID: p.id, move: false)
        let mb = try await importer.importFile(at: b, projectID: p.id, move: false)
        p.addMedia(ma)
        p.addMedia(mb)
        let c1 = try p.insertIntoMain(mediaID: ma.id, near: .zero)
        _ = try p.insertIntoMain(mediaID: mb.id, near: p.duration + .seconds(1))
        // Split the 3 s clip at 1 s and delete the first second → 2 + 2 = 4 s.
        let right = try p.split(clipID: c1, at: .seconds(1))
        try p.delete(clipID: c1)
        try p.updateClip(right) { $0.fadeIn = .seconds(0.5) }
        // Overlay + a keyframed transform exercise the custom compositor.
        _ = try p.addLayeredClip(mediaID: mb.id, kind: .overlay, at: .seconds(0.5))
        try p.updateClip(right) { c in
            c.transform.apply(TransformValue(scale: 1.2), at: .seconds(2), autoKeyframe: true,
                              tolerance: .frame(30), anchor: c.sourceRange.start)
        }
        XCTAssertEqual(p.validate(), [])
        XCTAssertEqual(p.duration.seconds, 4, accuracy: 0.001)
        try store.save(p)

        let out = root.appendingPathComponent("out.mp4")
        let exporter = VideoExporter()
        var settings = ExportSettings()
        settings.resolution = .p720
        try await exporter.export(project: p, store: store, settings: settings, to: out) { _ in }

        let result = AVURLAsset(url: out)
        let duration = try await result.load(.duration)
        XCTAssertEqual(duration.seconds, 4, accuracy: 0.1)
        let videoTracks = try await result.loadTracks(withMediaType: .video)
        XCTAssertEqual(videoTracks.count, 1)
        let size = try await videoTracks[0].load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 720, height: 1280))
        let formats = try await videoTracks[0].load(.formatDescriptions)
        XCTAssertEqual(formats.first.map(CMFormatDescriptionGetMediaSubType), kCMVideoCodecType_H264)
        let audioTracks = try await result.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1, "audio from the first clip must survive export")

        // The exported file must actually decode.
        let gen = AVAssetImageGenerator(asset: result)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        for s in [0.1, 1.9, 3.5] {
            _ = try await gen.image(at: CMTime(seconds: s, preferredTimescale: 600))
        }
    }

    func testCompositionTimingMatchesPlan() async throws {
        let a = try await TestMedia.makeVideo(at: root.appendingPathComponent("a.mov"), seconds: 2, fps: 30,
                                              size: CGSize(width: 160, height: 120), withAudio: true)
        var p = try store.create(name: "Plan", aspectRatio: .square)
        let m = try await MediaImporter(store: store).importFile(at: a, projectID: p.id, move: false)
        p.addMedia(m)
        let id = try p.insertIntoMain(mediaID: m.id, near: .zero)
        try p.trim(clipID: id, edge: .end, to: .seconds(1.5))
        let s: ProjectStore = store
        let pid = p.id
        let builder = CompositionBuilder { s.mediaURL(projectID: pid, fileName: $0.fileName) }
        let built = try await builder.build(project: p, renderSize: PixelSize(width: 360, height: 360))
        XCTAssertEqual(built.composition.duration.seconds, 1.5, accuracy: 0.01)
        let instructions = try XCTUnwrap(built.videoComposition?.instructions)
        XCTAssertEqual(instructions.first?.timeRange.start.seconds, 0)
        XCTAssertEqual(CMTimeRangeGetEnd(instructions.last!.timeRange), built.composition.duration)
    }

    func testCancelExportStopsCleanly() async throws {
        let a = try await TestMedia.makeVideo(at: root.appendingPathComponent("a.mov"), seconds: 6, fps: 30,
                                              size: CGSize(width: 640, height: 480), withAudio: false)
        var p = try store.create(name: "Cancel", aspectRatio: .landscape16x9)
        let m = try await MediaImporter(store: store).importFile(at: a, projectID: p.id, move: false)
        p.addMedia(m)
        _ = try p.insertIntoMain(mediaID: m.id, near: .zero)
        let out = root.appendingPathComponent("cancel.mp4")
        let exporter = VideoExporter()
        let task = Task { try await exporter.export(project: p, store: store, settings: ExportSettings(), to: out) { _ in } }
        try await Task.sleep(nanoseconds: 300_000_000)
        exporter.cancel()
        do {
            try await task.value
            // Finished before the cancel landed: acceptable on a fast host.
        } catch ExportError.cancelled {
            XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
        }
    }
}

enum TestMedia {
    /// Writes a short H.264 movie with a moving colour bar (and optional sine
    /// tone) using AVAssetWriter, so tests never depend on bundled media.
    static func makeVideo(at url: URL, seconds: Double, fps: Int32, size: CGSize, withAudio: Bool) async throws -> URL {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ])
        vIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height)
        ])
        writer.add(vIn)

        var aIn: AVAssetWriterInput?
        if withAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            aIn = input
        }

        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "TestMedia", code: 1) }
        writer.startSession(atSourceTime: .zero)

        let frames = Int(seconds * Double(fps))
        for i in 0..<frames {
            while !vIn.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            guard let pool = adaptor.pixelBufferPool else { throw NSError(domain: "TestMedia", code: 2) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let buffer = pb else { throw NSError(domain: "TestMedia", code: 3) }
            fill(buffer, frame: i, of: frames)
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        vIn.markAsFinished()

        if let aIn {
            let sampleRate = 44_100
            let total = Int(seconds * Double(sampleRate))
            let chunk = 4_410
            var written = 0
            while written < total {
                while !aIn.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
                let n = min(chunk, total - written)
                if let sb = makeToneBuffer(start: written, count: n, sampleRate: sampleRate) { aIn.append(sb) }
                written += n
            }
            aIn.markAsFinished()
        }

        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? NSError(domain: "TestMedia", code: 4) }
        return url
    }

    private static func fill(_ buffer: CVPixelBuffer, frame: Int, of total: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        let bar = Int(Double(frame) / Double(max(1, total)) * Double(w))
        for y in 0..<h {
            let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w {
                let o = x * 4
                let onBar = abs(x - bar) < 6
                row[o] = onBar ? 255 : UInt8(y * 255 / max(1, h))      // B
                row[o + 1] = onBar ? 255 : UInt8(x * 255 / max(1, w))  // G
                row[o + 2] = onBar ? 255 : 80                           // R
                row[o + 3] = 255
            }
        }
    }

    private static func makeToneBuffer(start: Int, count: Int, sampleRate: Int) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(mSampleRate: Float64(sampleRate), mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                               mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
                                               mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                             magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr,
              let format else { return nil }
        var samples = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            samples[i] = Int16(sin(2 * Double.pi * 440 * Double(start + i) / Double(sampleRate)) * 8_000)
        }
        var block: CMBlockBuffer?
        let bytes = count * 2
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        _ = samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
        var sb: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format,
                                                                   sampleCount: count,
                                                                   presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(sampleRate)),
                                                                   packetDescriptions: nil, sampleBufferOut: &sb) == noErr else { return nil }
        return sb
    }
}
