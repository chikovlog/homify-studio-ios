import SwiftUI
import AVFoundation
import HomifyCore

@MainActor
final class ProjectLibrary: ObservableObject {
    let store: ProjectStore
    @Published private(set) var projects: [ProjectSummary] = []
    @Published var error: String?

    init(store: ProjectStore = ProjectStore(rootURL: AppPaths.projectsRoot)) {
        self.store = store
        refresh()
    }

    func refresh() {
        let store = self.store
        Task.detached(priority: .userInitiated) {
            let list = store.list()
            await MainActor.run { self.projects = list }
        }
    }

    func create(aspect: AspectRatio) -> UUID? {
        let n = projects.count + 1
        do {
            let p = try store.create(name: "Project \(n)", aspectRatio: aspect)
            refresh()
            return p.id
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func delete(_ id: UUID) {
        do { try store.delete(id) } catch { self.error = error.localizedDescription }
        projects.removeAll { $0.id == id }
    }

    func rename(_ id: UUID, to name: String) {
        guard var p = try? store.load(id) else { return }
        p.name = name
        try? store.save(p)
        refresh()
    }

    func duplicate(_ id: UUID) {
        let src = store.directory(for: id)
        guard var p = try? store.load(id) else { return }
        let newID = UUID()
        do {
            try FileManager.default.copyItem(at: src, to: store.directory(for: newID))
            p.id = newID
            p.name += " copy"
            p.createdAt = Date()
            p.modifiedAt = Date()
            try store.save(p)
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }
}

struct ProjectListView: View {
    @EnvironmentObject private var library: ProjectLibrary
    @State private var path: [UUID] = []
    @State private var showNew = false
    @State private var renameTarget: ProjectSummary?
    @State private var renameText = ""

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    Button { showNew = true } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "plus")
                                .font(.system(size: 22, weight: .semibold))
                                .frame(width: 56, height: 56)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor))
                                .foregroundStyle(.black)
                            VStack(alignment: .leading) {
                                Text("New Project").font(.headline)
                                Text("9:16 · 1:1 · 16:9 · 4:5").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .foregroundStyle(.white)
                }
                if !library.projects.isEmpty {
                    Section("Projects") {
                        ForEach(library.projects) { p in
                            NavigationLink(value: p.id) { ProjectRow(summary: p) }
                                .contextMenu {
                                    Button { renameText = p.name; renameTarget = p } label: { Label("Rename", systemImage: "pencil") }
                                    Button { library.duplicate(p.id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                                    Button(role: .destructive) { library.delete(p.id) } label: { Label("Delete", systemImage: "trash") }
                                }
                        }
                        .onDelete { idx in idx.map { library.projects[$0].id }.forEach(library.delete) }
                    }
                }
            }
            .navigationTitle("Homify Studio")
            .navigationDestination(for: UUID.self) { id in EditorScreen(projectID: id) }
            .confirmationDialog("Aspect ratio", isPresented: $showNew, titleVisibility: .visible) {
                ForEach(AspectRatio.allCases) { a in
                    Button(label(for: a)) { if let id = library.create(aspect: a) { path.append(id) } }
                }
            }
            .alert("Rename", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
                TextField("Name", text: $renameText)
                Button("Save") { if let t = renameTarget { library.rename(t.id, to: renameText) } }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Error", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(library.error ?? "") }
            .onAppear { library.refresh() }
        }
    }

    private func label(for a: AspectRatio) -> String {
        switch a {
        case .portrait9x16: return "9:16 · Reels / TikTok / Shorts"
        case .square: return "1:1 · Square"
        case .landscape16x9: return "16:9 · YouTube"
        case .portrait4x5: return "4:5 · Feed"
        }
    }
}

struct ProjectRow: View {
    let summary: ProjectSummary
    @State private var thumb: UIImage?

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08))
                if let thumb {
                    Image(uiImage: thumb).resizable().scaledToFill()
                } else {
                    Image(systemName: "film").foregroundStyle(.secondary)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.name).font(.headline).lineLimit(1)
                Text("\(summary.aspectRatio.rawValue) · \(Timecode.short(summary.duration))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(summary.modifiedAt, style: .relative).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .task(id: summary.firstVideoFile) {
            guard let url = summary.firstVideoFile else { thumb = nil; return }
            thumb = await ThumbnailProvider.shared.image(url: url, seconds: 0)
        }
    }
}
