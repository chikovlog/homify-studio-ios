import CoreMedia
import HomifyCore

extension Time {
    var cmTime: CMTime { CMTime(value: value, timescale: CMTimeScale(Time.timescale)) }

    init(_ cm: CMTime) {
        guard cm.isValid, !cm.isIndefinite, cm.timescale != 0 else { self = .zero; return }
        if cm.timescale == CMTimeScale(Time.timescale) {
            self.init(value: cm.value)
        } else {
            self.init(value: CMTimeConvertScale(cm, timescale: CMTimeScale(Time.timescale), method: .roundHalfAwayFromZero).value)
        }
    }
}

extension TimeRange {
    var cmTimeRange: CMTimeRange { CMTimeRange(start: start.cmTime, duration: duration.cmTime) }

    init(_ r: CMTimeRange) { self.init(start: Time(r.start), duration: Time(r.duration)) }
}

extension PixelSize {
    var cgSize: CGSize { CGSize(width: width, height: height) }
}
