import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import HomifyCore

struct EditorScreen: View {
    let projectID: UUID
    @EnvironmentObject private var library: ProjectLibrary
    @State private var vm: EditorViewModel?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let vm {
                EditorView(vm: vm)
            } else if let loadError {
                ContentUnavailableView("Can't open project", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else {
                ProgressView()
            }
        }
        .task {
            guard vm == nil else { return }
            do { vm = EditorViewModel(project: try library.store.load(projectID), store: library.store) }
            catch { loadError = error.localizedDescription }
        }
    }
}

struct EditorView: View {
    @ObservedObject var vm: EditorViewModel
    @ObservedObject private var playback: PlaybackEngine
    @EnvironmentObject private var library: ProjectLibrary
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var fileImport: TrackKind?
    @State private var showFiles = false
    @State private var showExport = false
    @State private var showAudioPanel = false
    @State private var fullscreen = false
    @State private var renaming = false
    @State private var newName = ""

    init(vm: EditorViewModel) {
        self.vm = vm
        self._playback = ObservedObject(wrappedValue: vm.playback)
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                topBar
                PreviewArea(vm: vm, fullscreen: $fullscreen)
                    .frame(height: max(220, geo.size.height * 0.42))
                transportBar
                TimelineRepresentable(vm: vm)
                    .frame(maxHeight: .infinity)
                EditorToolbar(vm: vm,
                              addFromPhotos: { showPhotos = true },
                              addFromFiles: { kind in fileImport = kind; showFiles = true },
                              showAudio: { showAudioPanel = true })
            }
        }
        .background(Color(white: 0.05).ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 20,
                      matching: .videos, preferredItemEncoding: .current)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task { await importPhotos(items) }
        }
        .fileImporter(isPresented: $showFiles,
                      allowedContentTypes: fileImport == .audio ? [.audio] : [.movie, .audio],
                      allowsMultipleSelection: true) { result in
            let dest = fileImport ?? .main
            if case .success(let urls) = result {
                Task { await vm.importMedia(urls: urls, destination: dest, move: false, securityScoped: true) }
            }
        }
        .sheet(isPresented: $showExport) {
            ExportSheet(project: vm.project, store: vm.store)
        }
        .sheet(isPresented: $showAudioPanel) {
            AudioPanel(vm: vm)
                .presentationDetents([.height(300)])
                .presentationBackgroundInteraction(.enabled(upThrough: .height(300)))
        }
        .fullScreenCover(isPresented: $fullscreen) {
            FullscreenPlayer(vm: vm, playback: vm.playback)
        }
        .alert("Rename project", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") { vm.rename(newName) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Homify Studio", isPresented: Binding(get: { vm.message != nil }, set: { if !$0 { vm.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vm.message ?? "")
        }
        .overlay {
            if vm.isBusy {
                ProgressView("Importing…")
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                vm.playback.pause()
                vm.saveNow()
            }
        }
        .onDisappear {
            vm.close()
            library.refresh()
        }
        .preferredColorScheme(.dark)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: { Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold)) }
                .accessibilityLabel("Back to projects")
            Button { newName = vm.project.name; renaming = true } label: {
                Text(vm.project.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            }
            .foregroundStyle(.white)
            Spacer()
            Menu {
                Picker("Aspect ratio", selection: Binding(get: { vm.project.aspectRatio }, set: { vm.setAspectRatio($0) })) {
                    ForEach(AspectRatio.allCases) { Text($0.rawValue).tag($0) }
                }
            } label: {
                Label(vm.project.aspectRatio.rawValue, systemImage: "aspectratio")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
            }
            Button { vm.playback.pause(); vm.saveNow(); showExport = true } label: {
                Text("Export").font(.subheadline.weight(.bold))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Capsule().fill(Color.accentColor))
                    .foregroundStyle(.black)
            }
            .disabled(vm.project.duration == .zero)
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .tint(.white)
    }

    private var transportBar: some View {
        HStack(spacing: 18) {
            Button(action: vm.undo) { Image(systemName: "arrow.uturn.backward") }
                .disabled(!vm.canUndo)
                .accessibilityLabel("Undo")
            Button(action: vm.redo) { Image(systemName: "arrow.uturn.forward") }
                .disabled(!vm.canRedo)
                .accessibilityLabel("Redo")
            Spacer()
            TimecodeLabel(clock: vm.clock, duration: vm.project.duration, fps: vm.project.frameRate)
            Spacer()
            Button(action: vm.togglePlay) {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20))
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
            .disabled(vm.project.duration == .zero)
        }
        .font(.system(size: 17, weight: .medium))
        .tint(.white)
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Color(white: 0.07))
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        var urls: [URL] = []
        for item in items {
            do {
                if let movie = try await item.loadTransferable(type: PickedMovie.self) { urls.append(movie.url) }
            } catch {
                vm.message = "Could not load a video from Photos: \(error.localizedDescription)"
            }
        }
        await vm.importMedia(urls: urls, destination: .main, move: true, securityScoped: false)
    }
}

/// Receives a video file from the Photos picker as a temporary copy.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dest = AppPaths.importScratch.appendingPathComponent(UUID().uuidString + "." + ext)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedMovie(url: dest)
        }
    }
}
