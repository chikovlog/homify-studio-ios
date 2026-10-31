import UIKit
import HomifyCore

/// Scroll view that refuses to pan when the touch starts on a trim handle or
/// while a clip is being dragged, so those gestures never fight scrolling.
final class TimelineScrollView: UIScrollView {
    var shouldBlockPan: ((CGPoint) -> Bool)?

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === panGestureRecognizer, let block = shouldBlockPan, block(g.location(in: self)) { return false }
        return super.gestureRecognizerShouldBegin(g)
    }
}

/// Multitrack timeline in UIKit for precise, allocation-free scrolling.
///
/// The playhead is fixed in the centre; the content scrolls underneath it
/// (time at playhead = (contentOffset.x + inset) / pointsPerSecond). Only
/// visible thumbnail tiles exist at any time.
final class TimelineView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    // MARK: Callbacks
    var onScrubBegan: (() -> Void)?
    var onScrub: ((Time) -> Void)?
    var onSelect: ((UUID?) -> Void)?
    var onTrim: ((UUID, ClipEdge, Time, UIGestureRecognizer.State) -> Void)?
    var onMoveMain: ((UUID, Int) -> Void)?
    var onMoveLayered: ((UUID, Time, UUID) -> Void)?
    var onToggleMute: ((UUID) -> Void)?
    var onToggleLock: ((UUID) -> Void)?
    var mediaURL: ((MediaAsset) -> URL)?

    // MARK: Layout constants
    static let rulerHeight: CGFloat = 22
    static let headerWidth: CGFloat = 30
    static let mainRowHeight: CGFloat = 58
    static let rowHeight: CGFloat = 40
    static let rowSpacing: CGFloat = 6
    static let topPadding: CGFloat = 8

    private(set) var pointsPerSecond: CGFloat = 60
    private let minPPS: CGFloat = 4
    private let maxPPS: CGFloat = 900

    private let scrollView = TimelineScrollView()
    private let contentView = UIView()
    private let ruler = TimelineRulerView()
    private let playhead = UIView()
    private var clipViews: [UUID: TimelineClipView] = [:]
    private var headerViews: [UUID: TrackHeaderView] = [:]
    private struct Row { let track: Track; let y: CGFloat; let height: CGFloat }
    private var rows: [Row] = []

    private(set) var project: Project?
    private var selectedClipID: UUID?
    private var isProgrammaticScroll = false
    private var lastBoundsWidth: CGFloat = 0
    private var lastReportedTime: Time = .zero

    // Pinch
    private var pinchStartPPS: CGFloat = 0
    private var pinchAnchorTime: Time = .zero

    // Trim
    private var trimClipID: UUID?
    private var trimEdge: ClipEdge = .end
    private var trimOriginalEdge: Time = .zero

    // Drag-move
    private var dragClipID: UUID?
    private var dragStartPoint: CGPoint = .zero
    private var dragStartFrame: CGRect = .zero
    private var dragOriginalStart: Time = .zero
    private var dragTargetTrackID: UUID?
    private var dragProposedStart: Time = .zero

    private let snapFeedback = UISelectionFeedbackGenerator()
    private var lastSnap: Time?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func setup() {
        backgroundColor = UIColor(white: 0.07, alpha: 1)
        clipsToBounds = true

        scrollView.delegate = self
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = true
        scrollView.alwaysBounceHorizontal = true
        scrollView.isDirectionalLockEnabled = true
        scrollView.decelerationRate = .normal
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.shouldBlockPan = { [weak self] p in self?.shouldBlockPan(at: p) ?? false }
        addSubview(scrollView)
        scrollView.addSubview(contentView)

        ruler.isUserInteractionEnabled = false
        addSubview(ruler)

        playhead.backgroundColor = .white
        playhead.isUserInteractionEnabled = false
        playhead.layer.shadowColor = UIColor.black.cgColor
        playhead.layer.shadowOpacity = 0.6
        playhead.layer.shadowRadius = 2
        playhead.layer.shadowOffset = .zero
        addSubview(playhead)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        contentView.addGestureRecognizer(tap)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.35
        longPress.delegate = self
        contentView.addGestureRecognizer(longPress)
    }

    // MARK: Public API

    var currentTime: Time {
        let x = scrollView.contentOffset.x + scrollView.contentInset.left
        return Time(seconds: Double(max(0, x) / pointsPerSecond))
    }

    /// Moves the content so `t` sits under the playhead (programmatic, e.g. playback).
    func setTime(_ t: Time) {
        guard !scrollView.isTracking, !scrollView.isDecelerating, trimClipID == nil, dragClipID == nil else { return }
        isProgrammaticScroll = true
        scrollView.contentOffset.x = CGFloat(t.seconds) * pointsPerSecond - scrollView.contentInset.left
        isProgrammaticScroll = false
        afterScroll()
    }

    func update(project: Project, selectedClipID: UUID?) {
        let t = currentTime
        self.project = project
        self.selectedClipID = selectedClipID
        relayout()
        if trimClipID == nil, dragClipID == nil { setTimeKeepingIfNeeded(t, duration: project.duration) }
    }

    private func setTimeKeepingIfNeeded(_ t: Time, duration: Time) {
        // After an edit that shortened the timeline, keep the playhead inside it.
        let clamped = min(t, duration)
        guard clamped != t else { return }
        setTime(clamped)
        // Report asynchronously: this runs inside a SwiftUI view update.
        DispatchQueue.main.async { [weak self] in self?.onScrub?(clamped) }
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let t = currentTime
        ruler.frame = CGRect(x: 0, y: 0, width: bounds.width, height: TimelineView.rulerHeight)
        scrollView.frame = CGRect(x: 0, y: TimelineView.rulerHeight, width: bounds.width, height: bounds.height - TimelineView.rulerHeight)
        playhead.frame = CGRect(x: (bounds.width / 2).rounded() - 1, y: 4, width: 2, height: bounds.height - 4)
        if bounds.width != lastBoundsWidth {
            lastBoundsWidth = bounds.width
            let inset = bounds.width / 2
            scrollView.contentInset = UIEdgeInsets(top: 0, left: inset, bottom: 12, right: inset)
            relayout()
            setTime(t)
        }
    }

    private func x(for t: Time) -> CGFloat { CGFloat(t.seconds) * pointsPerSecond }
    private func time(forX x: CGFloat) -> Time { Time(seconds: Double(x / pointsPerSecond)) }

    private func orderedTracks(_ p: Project) -> [Track] {
        // Main first, then overlays (top-most layer first), then audio.
        let main = p.tracks.filter { $0.kind == .main }
        let overlays = p.tracks.filter { $0.kind == .overlay }.reversed()
        let audio = p.tracks.filter { $0.kind == .audio }
        return Array(overlays) + main + audio
    }

    private func relayout() {
        guard let project else { return }
        var y = TimelineView.topPadding
        rows = orderedTracks(project).map { track in
            let h = track.kind == .main ? TimelineView.mainRowHeight : TimelineView.rowHeight
            defer { y += h + TimelineView.rowSpacing }
            return Row(track: track, y: y, height: h)
        }
        let width = max(x(for: project.duration), 1)
        contentView.frame = CGRect(x: 0, y: 0, width: width, height: y)
        scrollView.contentSize = CGSize(width: width, height: y)

        var seenClips = Set<UUID>()
        var seenTracks = Set<UUID>()
        for row in rows {
            seenTracks.insert(row.track.id)
            let header = headerViews[row.track.id] ?? makeHeader(for: row.track.id)
            header.configure(track: row.track)
            header.frame = CGRect(x: 0, y: row.y, width: TimelineView.headerWidth, height: row.height)

            for clip in row.track.clips {
                seenClips.insert(clip.id)
                let view = clipViews[clip.id] ?? makeClipView(clip.id)
                let media = project.mediaAsset(clip.mediaID)
                let url = media.flatMap { m in mediaURL?(m) }
                view.configure(clip: clip, kind: row.track.kind, media: media, url: url,
                               pointsPerSecond: pointsPerSecond,
                               selected: clip.id == selectedClipID,
                               locked: row.track.isLocked, muted: row.track.isMuted)
                if clip.id != dragClipID {
                    view.frame = CGRect(x: x(for: clip.timelineStart), y: row.y,
                                        width: max(2, x(for: clip.duration)), height: row.height)
                }
            }
        }
        for (id, v) in clipViews where !seenClips.contains(id) { v.removeFromSuperview(); clipViews[id] = nil }
        for (id, v) in headerViews where !seenTracks.contains(id) { v.removeFromSuperview(); headerViews[id] = nil }
        if let sel = selectedClipID, let v = clipViews[sel] { contentView.bringSubviewToFront(v) }
        if let d = dragClipID, let v = clipViews[d] { contentView.bringSubviewToFront(v) }
        for h in headerViews.values { contentView.bringSubviewToFront(h) }
        afterScroll()
    }

    private func makeClipView(_ id: UUID) -> TimelineClipView {
        let v = TimelineClipView(clipID: id)
        v.leftHandle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handleTrimPan(_:))))
        v.rightHandle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handleTrimPan(_:))))
        contentView.addSubview(v)
        clipViews[id] = v
        return v
    }

    private func makeHeader(for trackID: UUID) -> TrackHeaderView {
        let h = TrackHeaderView()
        h.onMute = { [weak self] in self?.onToggleMute?(trackID) }
        h.onLock = { [weak self] in self?.onToggleLock?(trackID) }
        contentView.addSubview(h)
        headerViews[trackID] = h
        return h
    }

    /// Work done on every scroll: pin headers, redraw ruler, load visible tiles.
    private func afterScroll() {
        let offsetX = scrollView.contentOffset.x
        for h in headerViews.values { h.frame.origin.x = offsetX }
        ruler.update(offsetX: offsetX, pointsPerSecond: pointsPerSecond, duration: project?.duration ?? .zero)
        let visible = CGRect(x: offsetX, y: scrollView.contentOffset.y, width: scrollView.bounds.width, height: scrollView.bounds.height)
        for v in clipViews.values {
            let r = v.frame.intersection(visible.insetBy(dx: -scrollView.bounds.width * 0.5, dy: 0))
            v.updateVisibleTiles(in: r.isNull ? .zero : v.convert(r, from: contentView))
        }
    }

    // MARK: UIScrollViewDelegate

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        onScrubBegan?()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        afterScroll()
        guard !isProgrammaticScroll, scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating else { return }
        let fps = project?.frameRate ?? 30
        let t = min(currentTime, project?.duration ?? .zero).snapped(toFrameRate: fps)
        if t != lastReportedTime {
            lastReportedTime = t
            onScrub?(t)
        }
    }

    // MARK: Gestures

    private func shouldBlockPan(at pointInScroll: CGPoint) -> Bool {
        if dragClipID != nil || trimClipID != nil { return true }
        guard let sel = selectedClipID, let v = clipViews[sel] else { return false }
        let p = v.convert(pointInScroll, from: scrollView)
        return v.handleHitTest(p)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        let p = g.location(in: contentView)
        if let sel = selectedClipID, let v = clipViews[sel], v.handleHitTest(v.convert(p, from: contentView)) { return }
        let hit = clipViews.values.first { $0.frame.contains(p) && !$0.isHidden }
        let id = hit?.clipID
        onSelect?(id == selectedClipID ? nil : id)
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            pinchStartPPS = pointsPerSecond
            pinchAnchorTime = currentTime
        case .changed:
            let pps = min(max(pinchStartPPS * g.scale, minPPS), maxPPS)
            guard abs(pps - pointsPerSecond) > 0.01 else { return }
            pointsPerSecond = pps
            relayout()
            isProgrammaticScroll = true
            scrollView.contentOffset.x = CGFloat(pinchAnchorTime.seconds) * pps - scrollView.contentInset.left
            isProgrammaticScroll = false
            afterScroll()
        default:
            break
        }
    }

    private func snapThreshold() -> Time { Time(seconds: Double(10 / pointsPerSecond)) }

    private func snapped(_ t: Time, excluding clipID: UUID) -> Time {
        guard let project else { return t }
        let pts = project.snapPoints(excluding: clipID, playhead: currentTime)
        if let s = Snapping.snap(t, to: pts, threshold: snapThreshold()) {
            if lastSnap != s { snapFeedback.selectionChanged(); lastSnap = s }
            return s
        }
        lastSnap = nil
        return t
    }

    @objc private func handleTrimPan(_ g: UIPanGestureRecognizer) {
        guard let handle = g.view, let clipView = handle.superview as? TimelineClipView,
              let clip = project?.clip(clipView.clipID) else { return }
        switch g.state {
        case .began:
            trimClipID = clip.id
            trimEdge = handle === clipView.leftHandle ? .start : .end
            trimOriginalEdge = trimEdge == .start ? clip.timelineStart : clip.timelineRange.end
            snapFeedback.prepare()
            onTrim?(clip.id, trimEdge, trimOriginalEdge, .began)
        case .changed:
            guard trimClipID == clip.id else { return }
            let dx = g.translation(in: contentView).x
            let raw = trimOriginalEdge + time(forX: dx)
            onTrim?(clip.id, trimEdge, snapped(raw, excluding: clip.id), .changed)
        case .ended, .cancelled, .failed:
            guard let id = trimClipID else { return }
            let dx = g.translation(in: contentView).x
            let raw = trimOriginalEdge + time(forX: dx)
            trimClipID = nil
            lastSnap = nil
            onTrim?(id, trimEdge, snapped(raw, excluding: id), g.state == .ended ? .ended : .cancelled)
        default:
            break
        }
    }

    @objc private func handleLongPress(_ g: UILongPressGestureRecognizer) {
        guard let project else { return }
        let p = g.location(in: contentView)
        switch g.state {
        case .began:
            guard let v = clipViews.values.first(where: { $0.frame.contains(p) }),
                  let track = project.track(containing: v.clipID), !track.isLocked,
                  let clip = project.clip(v.clipID) else { return }
            dragClipID = v.clipID
            dragStartPoint = p
            dragStartFrame = v.frame
            dragOriginalStart = clip.timelineStart
            dragProposedStart = clip.timelineStart
            dragTargetTrackID = track.id
            contentView.bringSubviewToFront(v)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            UIView.animate(withDuration: 0.15) {
                v.transform = CGAffineTransform(scaleX: 1.03, y: 1.08)
                v.alpha = 0.85
            }
        case .changed:
            guard let id = dragClipID, let v = clipViews[id], let clip = project.clip(id),
                  let track = project.track(containing: id) else { return }
            let dx = p.x - dragStartPoint.x
            var frame = dragStartFrame
            if track.kind == .main {
                frame.origin.x = dragStartFrame.minX + dx
            } else {
                var start = max(.zero, dragOriginalStart + time(forX: dx))
                // Snap either edge.
                let s1 = snapped(start, excluding: id)
                if s1 != start { start = s1 } else {
                    let end = start + clip.duration
                    let s2 = snapped(end, excluding: id)
                    if s2 != end { start = s2 - clip.duration }
                }
                dragProposedStart = max(.zero, start)
                frame.origin.x = x(for: dragProposedStart)
                // Vertical: switch to the row under the finger if same kind.
                if let row = rows.first(where: { p.y >= $0.y && p.y < $0.y + $0.height && $0.track.kind == track.kind }) {
                    dragTargetTrackID = row.track.id
                    frame.origin.y = row.y
                    frame.size.height = row.height
                }
            }
            v.frame = frame
        case .ended, .cancelled, .failed:
            guard let id = dragClipID, let v = clipViews[id] else { dragClipID = nil; return }
            let track = project.track(containing: id)
            dragClipID = nil
            lastSnap = nil
            UIView.animate(withDuration: 0.15) {
                v.transform = .identity
                v.alpha = 1
            }
            guard g.state == .ended, let track else { relayout(); return }
            if track.kind == .main {
                let centre = time(forX: v.frame.midX)
                onMoveMain?(id, project.mainDropIndex(forCenter: centre, moving: id))
            } else if let target = dragTargetTrackID {
                onMoveLayered?(id, dragProposedStart, target)
            }
            relayout()
        default:
            break
        }
    }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g is UILongPressGestureRecognizer {
            let p = g.location(in: contentView)
            return clipViews.values.contains { $0.frame.contains(p) }
        }
        return super.gestureRecognizerShouldBegin(g)
    }
}

// MARK: - Clip view

final class TimelineClipView: UIView {
    let clipID: UUID
    let leftHandle = UIView()
    let rightHandle = UIView()
    private let tilesContainer = UIView()
    private let label = UILabel()
    private let durationLabel = UILabel()
    private var tiles: [Int: UIImageView] = [:]
    private var tileTasks: [Int: Task<Void, Never>] = [:]
    private var tileWidth: CGFloat = 40
    private var url: URL?
    private var sourceStart: Time = .zero
    private var pps: CGFloat = 60
    private var showsThumbnails = false
    private var isSelectedClip = false

    static let handleWidth: CGFloat = 16

    init(clipID: UUID) {
        self.clipID = clipID
        super.init(frame: .zero)
        layer.cornerRadius = 6
        layer.cornerCurve = .continuous
        clipsToBounds = true

        tilesContainer.isUserInteractionEnabled = false
        tilesContainer.clipsToBounds = true
        addSubview(tilesContainer)

        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .white
        label.isUserInteractionEnabled = false
        addSubview(label)

        durationLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        durationLabel.textColor = UIColor(white: 1, alpha: 0.9)
        durationLabel.backgroundColor = UIColor(white: 0, alpha: 0.45)
        durationLabel.layer.cornerRadius = 3
        durationLabel.clipsToBounds = true
        durationLabel.textAlignment = .center
        addSubview(durationLabel)

        for (h, corners) in [(leftHandle, CACornerMask([.layerMinXMinYCorner, .layerMinXMaxYCorner])),
                             (rightHandle, CACornerMask([.layerMaxXMinYCorner, .layerMaxXMaxYCorner]))] {
            h.backgroundColor = UIColor(red: 1, green: 0.78, blue: 0.2, alpha: 1)
            h.layer.cornerRadius = 6
            h.layer.maskedCorners = corners
            let grip = UIView(frame: CGRect(x: 0, y: 0, width: 2, height: 14))
            grip.backgroundColor = UIColor(white: 0, alpha: 0.55)
            grip.layer.cornerRadius = 1
            grip.tag = 99
            h.addSubview(grip)
            h.isHidden = true
            addSubview(h)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(clip: Clip, kind: TrackKind, media: MediaAsset?, url: URL?, pointsPerSecond: CGFloat,
                   selected: Bool, locked: Bool, muted: Bool) {
        let thumbs = kind != .audio && media?.hasVideo == true
        if url != self.url || clip.sourceRange.start != sourceStart || pointsPerSecond != pps || thumbs != showsThumbnails {
            resetTiles()
        }
        self.url = url
        self.sourceStart = clip.sourceRange.start
        self.pps = pointsPerSecond
        self.showsThumbnails = thumbs
        self.isSelectedClip = selected

        switch kind {
        case .main: backgroundColor = UIColor(red: 0.16, green: 0.20, blue: 0.30, alpha: 1)
        case .overlay: backgroundColor = UIColor(red: 0.35, green: 0.22, blue: 0.45, alpha: 1)
        case .audio: backgroundColor = UIColor(red: 0.10, green: 0.42, blue: 0.32, alpha: 1)
        }
        if let m = media, m.displayHeight > 0 {
            let aspect = CGFloat(m.displayWidth / m.displayHeight)
            tileWidth = max(24, min(120, TimelineView.mainRowHeight * aspect))
        }
        label.text = kind == .audio ? "♪ " + (media?.originalName ?? "Audio") : nil
        label.isHidden = kind != .audio
        durationLabel.text = " " + Timecode.short(clip.duration) + " "
        alpha = muted && kind == .audio ? 0.45 : 1

        layer.borderWidth = selected ? 2 : 0
        layer.borderColor = UIColor(red: 1, green: 0.78, blue: 0.2, alpha: 1).cgColor
        leftHandle.isHidden = !selected || locked
        rightHandle.isHidden = !selected || locked
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        tilesContainer.frame = bounds
        label.frame = CGRect(x: 8, y: 4, width: max(0, bounds.width - 16), height: 14)
        let dw = durationLabel.intrinsicContentSize.width
        durationLabel.frame = CGRect(x: bounds.width - dw - 4, y: bounds.height - 15, width: dw, height: 12)
        durationLabel.isHidden = bounds.width < dw + 30
        let hw = TimelineClipView.handleWidth
        leftHandle.frame = CGRect(x: 0, y: 0, width: hw, height: bounds.height)
        rightHandle.frame = CGRect(x: bounds.width - hw, y: 0, width: hw, height: bounds.height)
        for h in [leftHandle, rightHandle] {
            h.viewWithTag(99)?.center = CGPoint(x: hw / 2, y: bounds.height / 2)
        }
        bringSubviewToFront(leftHandle)
        bringSubviewToFront(rightHandle)
    }

    /// Larger hit area than the visible handle for comfortable one-hand use.
    func handleHitTest(_ p: CGPoint) -> Bool {
        guard !leftHandle.isHidden else { return false }
        let slop: CGFloat = 14
        return leftHandle.frame.insetBy(dx: -slop, dy: 0).contains(p) || rightHandle.frame.insetBy(dx: -slop, dy: 0).contains(p)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if handleHitTest(point) { return true }
        return super.point(inside: point, with: event)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if !leftHandle.isHidden {
            let slop: CGFloat = 14
            if leftHandle.frame.insetBy(dx: -slop, dy: 0).contains(point) { return leftHandle }
            if rightHandle.frame.insetBy(dx: -slop, dy: 0).contains(point) { return rightHandle }
        }
        return super.hitTest(point, with: event)
    }

    private func resetTiles() {
        tileTasks.values.forEach { $0.cancel() }
        tileTasks.removeAll()
        tiles.values.forEach { $0.removeFromSuperview() }
        tiles.removeAll()
    }

    /// Creates/reuses image views only for tiles intersecting `rect` (in self coordinates).
    func updateVisibleTiles(in rect: CGRect) {
        guard showsThumbnails, let url, rect.width > 0, tileWidth > 0 else {
            if !tiles.isEmpty && rect.width <= 0 { resetTiles() }
            return
        }
        let first = max(0, Int(floor(rect.minX / tileWidth)))
        let last = max(first, Int(ceil(rect.maxX / tileWidth)))
        let wanted = Set(first...last)
        for (i, v) in tiles where !wanted.contains(i) {
            v.removeFromSuperview()
            tiles[i] = nil
            tileTasks[i]?.cancel()
            tileTasks[i] = nil
        }
        for i in wanted where tiles[i] == nil {
            let iv = UIImageView(frame: CGRect(x: CGFloat(i) * tileWidth, y: 0, width: tileWidth, height: bounds.height))
            iv.contentMode = .scaleAspectFill
            iv.clipsToBounds = true
            tilesContainer.addSubview(iv)
            tiles[i] = iv
            let seconds = sourceStart.seconds + Double((CGFloat(i) + 0.5) * tileWidth / pps)
            if let img = ThumbnailProvider.shared.cached(url: url, seconds: seconds) {
                iv.image = img
            } else {
                tileTasks[i] = Task { @MainActor [weak self, weak iv] in
                    let img = await ThumbnailProvider.shared.image(url: url, seconds: seconds)
                    guard !Task.isCancelled, let iv, let self, self.tiles[i] === iv else { return }
                    iv.alpha = 0
                    iv.image = img
                    UIView.animate(withDuration: 0.12) { iv.alpha = 1 }
                }
            }
        }
        for (_, iv) in tiles { iv.frame.size.height = bounds.height }
    }
}

// MARK: - Track header

final class TrackHeaderView: UIView {
    var onMute: (() -> Void)?
    var onLock: (() -> Void)?
    private let muteButton = UIButton(type: .system)
    private let lockButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.1, alpha: 0.92)
        layer.cornerRadius = 4
        for b in [muteButton, lockButton] {
            b.tintColor = UIColor(white: 0.85, alpha: 1)
            addSubview(b)
        }
        muteButton.addAction(UIAction { [weak self] _ in self?.onMute?() }, for: .touchUpInside)
        lockButton.addAction(UIAction { [weak self] _ in self?.onLock?() }, for: .touchUpInside)
        muteButton.accessibilityLabel = "Mute track"
        lockButton.accessibilityLabel = "Lock track"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(track: Track) {
        let cfg = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        muteButton.setImage(UIImage(systemName: track.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", withConfiguration: cfg), for: .normal)
        lockButton.setImage(UIImage(systemName: track.isLocked ? "lock.fill" : "lock.open", withConfiguration: cfg), for: .normal)
        muteButton.tintColor = track.isMuted ? .systemRed : UIColor(white: 0.85, alpha: 1)
        lockButton.tintColor = track.isLocked ? .systemOrange : UIColor(white: 0.85, alpha: 1)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = bounds.height / 2
        muteButton.frame = CGRect(x: 0, y: 0, width: bounds.width, height: h)
        lockButton.frame = CGRect(x: 0, y: h, width: bounds.width, height: h)
    }
}

// MARK: - Ruler

final class TimelineRulerView: UIView {
    private var offsetX: CGFloat = 0
    private var pps: CGFloat = 60
    private var duration: Time = .zero
    private let font = UIFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.07, alpha: 1)
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(offsetX: CGFloat, pointsPerSecond: CGFloat, duration: Time) {
        self.offsetX = offsetX
        self.pps = pointsPerSecond
        self.duration = duration
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let candidates: [Double] = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        let major = candidates.first { CGFloat($0) * pps >= 64 } ?? 600
        let minor = major / 5
        let startT = max(0, Double(offsetX / pps))
        let endT = Double((offsetX + bounds.width) / pps)
        var t = (startT / minor).rounded(.down) * minor
        ctx.setFillColor(UIColor(white: 0.45, alpha: 1).cgColor)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor(white: 0.6, alpha: 1)]
        while t <= endT + minor {
            let x = CGFloat(t) * pps - offsetX
            let isMajor = abs((t / major).rounded() * major - t) < minor * 0.01
            let h: CGFloat = isMajor ? 7 : 3
            ctx.fill(CGRect(x: x, y: bounds.height - h, width: 1, height: h))
            if isMajor {
                let label: String
                if major < 1 { label = String(format: "%.1fs", t) }
                else { label = String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }
                (label as NSString).draw(at: CGPoint(x: x + 3, y: 3), withAttributes: attrs)
            }
            t += minor
        }
    }
}
