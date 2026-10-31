import AVFoundation
import Combine
import SwiftUI
import UIKit
import HomifyCore

/// Separate tiny observable for the playhead time so 60 Hz updates only
/// re-render the timecode label, never the editor or the toolbar.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var time: Time = .zero
}

/// Weak bridge from the view model to the UIKit timeline.
@MainActor
final class TimelineBridge {
    weak var view: TimelineView?
}

private final class DisplayLinkProxy: NSObject {
    weak var owner: EditorViewModel?
    @objc func tick(_ link: CADisplayLink) {
        MainActor.assumeIsolated { owner?.displayTick() }
    }
}

@MainActor
final class EditorViewModel: ObservableObject {
    @Published private(set) var project: Project
    @Published var selectedClipID: UUID?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published var message: String?
    @Published private(set) var isBusy = false
    @Published var showSafeArea = false

    let clock = PlaybackClock()
    let playback = PlaybackEngine()
    let timeline = TimelineBridge()
    let store: ProjectStore

    private var history = EditHistory<Project>(limit: 200)
    private var gestureBase: Project?
    private var rebuildTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var displayLink: CADisplayLink?
    private var cancellables = Set<AnyCancellable>()
    private let builder: CompositionBuilder

    /// Preview renders at 720p-class resolution; export always renders from
    /// the original media at full resolution.
    static let previewShortSide = 720

    init(project: Project, store: ProjectStore) {
        self.project = project
        self.store = store
        let projectID = project.id
        self.builder = CompositionBuilder { media in store.mediaURL(projectID: projectID, fileName: media.fileName) }
        playback.$isPlaying
            .removeDuplicates()
            .sink { [weak self] playing in
                guard let self else { return }
                playing ? self.startDisplayLink() : self.stopDisplayLink()
                if !playing { self.syncClockFromPlayer() }
            }
            .store(in: &cancellables)
        scheduleRebuild(immediate: true)
    }

    // MARK: - Derived

    var selectedClip: Clip? { selectedClipID.flatMap { project.clip($0) } }
    var selectedTrack: Track? { selectedClipID.flatMap { project.track(containing: $0) } }

    func mediaURL(_ media: MediaAsset) -> URL { store.mediaURL(projectID: project.id, fileName: media.fileName) }

    // MARK: - Edit pipeline

    /// Applies an edit as one undoable step. The body mutates a copy; if it
    /// throws, nothing changes.
    func perform(_ name: String, _ body: (inout Project) throws -> Void) {
        var copy = project
        do {
            try body(&copy)
        } catch {
            fail(error)
            return
        }
        guard copy != project else { return }
        history.record(project, name: name)
        commit(copy)
    }

    private func commit(_ p: Project, rebuild: Bool = true) {
        var p = p
        p.modifiedAt = Date()
        project = p
        if let sel = selectedClipID, p.clip(sel) == nil { selectedClipID = nil }
        canUndo = history.canUndo
        canRedo = history.canRedo
        scheduleSave()
        if rebuild { scheduleRebuild() }
    }

    func undo() {
        guard let prev = history.undo(current: project) else { return }
        commit(prev)
        haptic(.light)
    }

    func redo() {
        guard let next = history.redo(current: project) else { return }
        commit(next)
        haptic(.light)
    }

    /// Live (gesture-driven) edits: each change is re-applied to the state
    /// captured when the gesture began, and only the final result becomes an
    /// undo step. The composition is rebuilt once, on release.
    func beginGestureEdit() {
        playback.pause()
        gestureBase = project
    }

    func updateGestureEdit(_ body: (inout Project) throws -> Void) {
        guard let base = gestureBase else { return }
        var copy = base
        if (try? body(&copy)) != nil, copy != project { project = copy }
    }

    func endGestureEdit(_ name: String, commit apply: Bool, _ body: (inout Project) throws -> Void) {
        guard let base = gestureBase else { return }
        gestureBase = nil
        guard apply else { project = base; return }
        var copy = base
        do {
            try body(&copy)
        } catch {
            project = base
            fail(error)
            return
        }
        guard copy != base else { project = base; return }
        history.record(base, name: name)
        commit(copy)
    }

    // MARK: - Editing commands

    func split() {
        guard let id = selectedClipID else { return }
        let t = clock.time
        var newID: UUID?
        perform("Split") { newID = try $0.split(clipID: id, at: t) }
        if newID != nil { haptic(.medium) }
    }

    func deleteSelected() {
        guard let id = selectedClipID else { return }
        perform("Delete") { try $0.delete(clipID: id) }
        selectedClipID = nil
    }

    func duplicateSelected() {
        guard let id = selectedClipID else { return }
        var newID: UUID?
        perform("Duplicate") { newID = try $0.duplicate(clipID: id) }
        if let newID { selectedClipID = newID }
    }

    func setAspectRatio(_ a: AspectRatio) {
        perform("Aspect Ratio") { $0.aspectRatio = a }
    }

    func toggleMute(trackID: UUID) {
        perform("Mute") { p in
            let muted = p.tracks.first { $0.id == trackID }?.isMuted ?? false
            p.setTrackMuted(trackID, !muted)
        }
    }

    func toggleLock(trackID: UUID) {
        perform("Lock") { p in
            let locked = p.tracks.first { $0.id == trackID }?.isLocked ?? false
            p.setTrackLocked(trackID, !locked)
        }
    }

    func trim(clipID: UUID, edge: ClipEdge, to t: Time, phase: UIGestureRecognizer.State) {
        switch phase {
        case .began: beginGestureEdit()
        case .changed: updateGestureEdit { try $0.trim(clipID: clipID, edge: edge, to: t) }
        case .ended: endGestureEdit("Trim", commit: true) { try $0.trim(clipID: clipID, edge: edge, to: t) }
        default: endGestureEdit("Trim", commit: false) { _ in }
        }
    }

    func moveMain(clipID: UUID, to index: Int) {
        perform("Move") { try $0.moveMainClip(clipID: clipID, toIndex: index) }
    }

    func moveLayered(clipID: UUID, start: Time, trackID: UUID) {
        perform("Move") { try $0.moveLayeredClip(clipID: clipID, toStart: start, trackID: trackID) }
    }

    /// Volume/fade sliders: live while dragging, one undo step per drag.
    func editClipAudio(_ phase: SliderPhase, _ body: @escaping (inout Clip) -> Void) {
        guard let id = selectedClipID else { return }
        switch phase {
        case .began:
            gestureBase = project
            updateGestureEdit { try $0.updateClip(id, body) }
        case .changed:
            updateGestureEdit { try $0.updateClip(id, body) }
        case .ended:
            endGestureEdit("Audio", commit: true) { try $0.updateClip(id, body) }
        }
    }

    enum SliderPhase { case began, changed, ended }

    // MARK: - Import

    func importMedia(urls: [URL], destination: TrackKind, move: Bool, securityScoped: Bool) async {
        guard !urls.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        playback.pause()
        let importer = MediaImporter(store: store)
        var insertAt = clock.time
        var imported = 0
        for url in urls {
            let scoped = securityScoped && url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let asset = try await importer.importFile(at: url, projectID: project.id, move: move)
                if destination == .main && !asset.hasVideo {
                    message = "\(asset.originalName) has no video; added to an audio track."
                }
                let target: TrackKind = asset.hasVideo ? destination : .audio
                let at = insertAt
                var newID: UUID?
                perform("Import") { p in
                    p.addMedia(asset)
                    if target == .main {
                        newID = try p.insertIntoMain(mediaID: asset.id, near: at)
                    } else {
                        newID = try p.addLayeredClip(mediaID: asset.id, kind: target, at: at)
                    }
                }
                if target == .main, let newID, let c = project.clip(newID) {
                    // Next file goes right after this one.
                    insertAt = c.timelineRange.end - Time(value: 1)
                }
                imported += 1
            } catch {
                fail(error)
            }
        }
        if imported > 0 { haptic(.light) }
    }

    // MARK: - Playback & scrubbing

    func togglePlay() {
        if playback.isPlaying { playback.pause() } else { playback.play() }
    }

    func scrubBegan() {
        if playback.isPlaying { playback.pause() }
    }

    func scrub(to t: Time) {
        clock.time = t
        playback.seek(to: t)
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let proxy = DisplayLinkProxy()
        proxy.owner = self
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    fileprivate func displayTick() {
        guard playback.isPlaying else { return }
        syncClockFromPlayer()
    }

    private func syncClockFromPlayer() {
        guard playback.player.currentItem != nil else { return }
        let t = playback.currentTime
        clock.time = t
        timeline.view?.setTime(t)
    }

    // MARK: - Composition rebuild

    func scheduleRebuild(immediate: Bool = false) {
        rebuildTask?.cancel()
        let snapshot = project
        rebuildTask = Task { [weak self] in
            if !immediate { try? await Task.sleep(nanoseconds: 40_000_000) }
            guard let self, !Task.isCancelled else { return }
            do {
                let size = snapshot.aspectRatio.renderSize(shortSide: EditorViewModel.previewShortSide)
                let built = try await self.builder.build(project: snapshot, renderSize: size)
                guard !Task.isCancelled else { return }
                self.playback.load(built, at: min(self.clock.time, snapshot.duration))
            } catch CompositionError.empty {
                self.playback.load(nil, at: .zero)
            } catch {
                guard !Task.isCancelled else { return }
                self.fail(error)
            }
        }
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = project
        let store = self.store
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            try? store.save(snapshot)
        }
    }

    func saveNow() {
        saveTask?.cancel()
        do { try store.save(project) } catch { fail(error) }
    }

    func rename(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        perform("Rename") { $0.name = trimmed }
    }

    func close() {
        playback.pause()
        stopDisplayLink()
        rebuildTask?.cancel()
        saveNow()
    }

    // MARK: - Feedback

    private func fail(_ error: Error) {
        message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}

extension EditError: LocalizedError {
    public var errorDescription: String? { description }
}
