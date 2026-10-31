import Photos
import SwiftUI
import UIKit
import HomifyCore

@MainActor
final class ExportController: ObservableObject {
    enum State: Equatable {
        case idle
        case exporting(Double)
        case finished(URL)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var savedToPhotos = false
    @Published var photosMessage: String?
    private let exporter = VideoExporter()
    private var task: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    func start(project: Project, store: ProjectStore, settings: ExportSettings) {
        guard task == nil else { return }
        savedToPhotos = false
        state = .exporting(0)
        let safeName = project.name.components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted).joined()
        let stamp = Int(Date().timeIntervalSince1970)
        let url = AppPaths.exportsDirectory.appendingPathComponent("\(safeName.isEmpty ? "Homify" : safeName)-\(settings.resolution.label)-\(stamp).mp4")

        // iOS gives a backgrounded app only a short grace period and no GPU
        // access, so the screen is kept awake and a background task is used
        // only to finish cleanly if the user switches away briefly.
        UIApplication.shared.isIdleTimerDisabled = true
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Export") { [weak self] in
            Task { @MainActor in self?.cancel() }
        }
        let exporter = self.exporter
        task = Task {
            do {
                try await exporter.export(project: project, store: store, settings: settings, to: url) { p in
                    Task { @MainActor [weak self] in
                        if case .exporting = self?.state { self?.state = .exporting(p) }
                    }
                }
                state = .finished(url)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch ExportError.cancelled {
                state = .idle
            } catch {
                state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            finish()
        }
    }

    func cancel() {
        exporter.cancel()
    }

    private func finish() {
        task = nil
        UIApplication.shared.isIdleTimerDisabled = false
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    func saveToPhotos(_ url: URL) {
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                photosMessage = "Allow Homify Studio to add photos in Settings › Privacy › Photos."
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }
                savedToPhotos = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                photosMessage = error.localizedDescription
            }
        }
    }
}

struct ExportSheet: View {
    let project: Project
    let store: ProjectStore
    @StateObject private var controller = ExportController()
    @State private var settings = ExportSettings()
    @Environment(\.dismiss) private var dismiss

    private var supports60: Bool {
        let used = Set(project.tracks.flatMap { $0.clips.map(\.mediaID) })
        return project.media.contains { used.contains($0.id) && $0.frameRate > 31 }
    }

    var body: some View {
        NavigationStack {
            Form {
                switch controller.state {
                case .idle, .failed:
                    Section("Video") {
                        Picker("Resolution", selection: $settings.resolution) {
                            ForEach(ExportSettings.Resolution.allCases) { Text($0.label).tag($0) }
                        }
                        Picker("Frame rate", selection: $settings.frameRate) {
                            Text("30 fps").tag(30)
                            if supports60 { Text("60 fps").tag(60) }
                        }
                        let size = project.aspectRatio.renderSize(shortSide: settings.resolution.rawValue)
                        LabeledContent("Output", value: "\(size.width)×\(size.height) · H.264 MP4")
                        LabeledContent("Duration", value: Timecode.string(project.duration, fps: settings.frameRate))
                    }
                    if case .failed(let msg) = controller.state {
                        Section { Text(msg).foregroundStyle(.red) }
                    }
                    Section {
                        Button {
                            controller.start(project: project, store: store, settings: settings)
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                        }
                    } footer: {
                        Text("Keep Homify Studio open while exporting. iOS suspends GPU rendering for apps in the background, so leaving the app will stop the export.")
                    }
                case .exporting(let p):
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Rendering… \(Int(p * 100))%").font(.headline.monospacedDigit())
                            ProgressView(value: p)
                        }
                        .padding(.vertical, 6)
                        Button("Cancel export", role: .destructive) { controller.cancel() }
                    }
                case .finished(let url):
                    Section {
                        Label("Export complete", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Button {
                            controller.saveToPhotos(url)
                        } label: {
                            Label(controller.savedToPhotos ? "Saved to Photos" : "Save to Photos",
                                  systemImage: controller.savedToPhotos ? "checkmark" : "photo.badge.plus")
                        }
                        .disabled(controller.savedToPhotos)
                        ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                    } footer: {
                        Text("Also available in the Files app: On My iPhone › Homify Studio › Exports.")
                    }
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.disabled(isExporting)
                }
            }
            .interactiveDismissDisabled(isExporting)
            .alert("Photos", isPresented: Binding(get: { controller.photosMessage != nil }, set: { if !$0 { controller.photosMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(controller.photosMessage ?? "") }
            .onAppear { settings.frameRate = min(project.frameRate, supports60 ? 60 : 30) }
        }
        .preferredColorScheme(.dark)
    }

    private var isExporting: Bool {
        if case .exporting = controller.state { return true }
        return false
    }
}
