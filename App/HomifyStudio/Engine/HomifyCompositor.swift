import AVFoundation
import CoreImage
import Metal
import HomifyCore

/// What the compositor needs to draw one clip. Value type, captured at build
/// time so rendering never touches mutable editor state.
struct CompositorLayer {
    let trackID: CMPersistentTrackID
    let timelineStart: Time
    let sourceStart: Time
    let transform: ClipTransform
    let orientation: CGImagePropertyOrientation
}

final class HomifyInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing: Bool = false
    let containsTweening: Bool = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    /// Bottom → top.
    let layers: [CompositorLayer]

    init(timeRange: CMTimeRange, layers: [CompositorLayer]) {
        self.timeRange = timeRange
        self.layers = layers
        let ids = Array(Set(layers.map(\.trackID)))
        self.requiredSourceTrackIDs = ids.isEmpty ? nil : ids.map { NSNumber(value: $0) }
        super.init()
    }
}

/// Custom video compositor used for BOTH preview and export, so the exported
/// file matches the preview frame for frame. It renders with a single shared
/// Metal-backed CIContext (GPU resources are reused, nothing is re-created
/// per frame) and draws at whatever render size the composition asks for —
/// a reduced size for preview, the full size for export.
final class HomifyCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    static let sharedContext: CIContext = {
        let options: [CIContextOption: Any] = [
            .cacheIntermediates: false,
            .name: "HomifyCompositor"
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        return CIContext(options: options)
    }()

    private static let outputColorSpace = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()

    private let renderQueue = DispatchQueue(label: "studio.homify.render", qos: .userInitiated)
    private let lock = NSLock()
    private var _cancelled = false
    private var cancelled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _cancelled }
        set { lock.lock(); _cancelled = newValue; lock.unlock() }
    }

    private static let pixelFormats: [NSNumber] = [
        NSNumber(value: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        NSNumber(value: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
        NSNumber(value: kCVPixelFormatType_32BGRA)
    ]

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: HomifyCompositor.pixelFormats,
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: [NSNumber(value: kCVPixelFormatType_32BGRA)],
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        renderQueue.async { [weak self] in
            guard let self else { request.finishCancelledRequest(); return }
            if self.cancelled { request.finishCancelledRequest(); return }
            autoreleasepool {
                do {
                    let buffer = try self.render(request)
                    request.finish(withComposedVideoFrame: buffer)
                } catch {
                    request.finish(with: error)
                }
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        cancelled = true
        renderQueue.async { [weak self] in self?.cancelled = false }
    }

    private func render(_ request: AVAsynchronousVideoCompositionRequest) throws -> CVPixelBuffer {
        guard let output = request.renderContext.newPixelBuffer() else {
            throw NSError(domain: "HomifyCompositor", code: 1, userInfo: [NSLocalizedDescriptionKey: "No output buffer"])
        }
        let size = request.renderContext.size
        let canvas = CGRect(origin: .zero, size: size)
        var image = CIImage(color: .black).cropped(to: canvas)

        if let instruction = request.videoCompositionInstruction as? HomifyInstruction {
            let now = Time(request.compositionTime)
            for layer in instruction.layers {
                guard let frame = request.sourceFrame(byTrackID: layer.trackID) else { continue }
                var src = CIImage(cvPixelBuffer: frame).oriented(layer.orientation)
                src = src.transformed(by: CGAffineTransform(translationX: -src.extent.minX, y: -src.extent.minY))

                let sourceTime = layer.sourceStart + (now - layer.timelineStart)
                let value = layer.transform.value(at: sourceTime)
                guard value.opacity > 0.001 else { continue }
                let m = LayerGeometry.layerTransform(sourceWidth: src.extent.width, sourceHeight: src.extent.height,
                                                     canvasWidth: size.width, canvasHeight: size.height,
                                                     transform: value)
                var placed = src.transformed(by: CGAffineTransform(a: m.a, b: m.b, c: m.c, d: m.d, tx: m.tx, ty: m.ty))
                if value.opacity < 0.999 {
                    placed = placed.applyingFilter("CIColorMatrix", parameters: [
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(value.opacity))
                    ])
                }
                image = placed.composited(over: image)
            }
        }

        HomifyCompositor.sharedContext.render(image.cropped(to: canvas), to: output, bounds: canvas,
                                              colorSpace: HomifyCompositor.outputColorSpace)
        CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return output
    }
}

extension CGImagePropertyOrientation {
    init(quarterTurns: Int) {
        switch ((quarterTurns % 4) + 4) % 4 {
        case 1: self = .right
        case 2: self = .down
        case 3: self = .left
        default: self = .up
        }
    }
}
