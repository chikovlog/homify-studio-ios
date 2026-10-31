import Foundation

public struct ProjectSummary: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var modifiedAt: Date
    public var duration: Time
    public var aspectRatio: AspectRatio
    public var firstVideoFile: URL?
}

/// File-based project storage:
///
///     <root>/<project-id>/project.json   ← the edit (small, rewritten atomically)
///     <root>/<project-id>/Media/…        ← imported originals (never modified)
///
/// Saving only rewrites the small JSON document, never media, so autosave is
/// cheap enough to run after every edit.
public final class ProjectStore: @unchecked Sendable {
    public let rootURL: URL
    private let fm = FileManager.default
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        // Default (Double seconds) date encoding is lossless, unlike ISO-8601.
        return e
    }()
    private let decoder: JSONDecoder = {
        JSONDecoder()
    }()

    public init(rootURL: URL) {
        self.rootURL = rootURL
        try? fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    public func directory(for id: UUID) -> URL { rootURL.appendingPathComponent(id.uuidString, isDirectory: true) }
    public func mediaDirectory(for id: UUID) -> URL { directory(for: id).appendingPathComponent("Media", isDirectory: true) }
    public func documentURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("project.json") }
    public func mediaURL(projectID: UUID, fileName: String) -> URL { mediaDirectory(for: projectID).appendingPathComponent(fileName) }

    public func create(name: String, aspectRatio: AspectRatio, frameRate: Int = 30) throws -> Project {
        let p = Project(name: name, aspectRatio: aspectRatio, frameRate: frameRate)
        try fm.createDirectory(at: mediaDirectory(for: p.id), withIntermediateDirectories: true)
        try save(p)
        return p
    }

    public func encode(_ project: Project) throws -> Data { try encoder.encode(project) }

    public func save(_ project: Project) throws {
        try fm.createDirectory(at: directory(for: project.id), withIntermediateDirectories: true)
        let data = try encoder.encode(project)
        // .atomic writes to a temp file and renames, so a crash mid-save can
        // never leave a half-written project behind.
        try data.write(to: documentURL(for: project.id), options: .atomic)
    }

    public func load(_ id: UUID) throws -> Project {
        let data = try Data(contentsOf: documentURL(for: id))
        return try decoder.decode(Project.self, from: data)
    }

    public func delete(_ id: UUID) throws {
        try fm.removeItem(at: directory(for: id))
    }

    public func list() -> [ProjectSummary] {
        guard let dirs = try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) else { return [] }
        var out: [ProjectSummary] = []
        for dir in dirs {
            guard let id = UUID(uuidString: dir.lastPathComponent), let p = try? load(id) else { continue }
            let firstVideo = p.mainTrack.clips.first.flatMap { p.mediaAsset($0.mediaID) }
                .map { mediaURL(projectID: p.id, fileName: $0.fileName) }
            out.append(ProjectSummary(id: p.id, name: p.name, modifiedAt: p.modifiedAt, duration: p.duration,
                                      aspectRatio: p.aspectRatio, firstVideoFile: firstVideo))
        }
        return out.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// Copies (or moves) a file into the project's media folder and returns
    /// the stored file name. The source file itself is never altered.
    public func importFile(at source: URL, into projectID: UUID, move: Bool) throws -> String {
        let dir = mediaDirectory(for: projectID)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension.lowercased()
        let name = UUID().uuidString + "." + ext
        let dest = dir.appendingPathComponent(name)
        if move {
            do { try fm.moveItem(at: source, to: dest) } catch { try fm.copyItem(at: source, to: dest) }
        } else {
            try fm.copyItem(at: source, to: dest)
        }
        return name
    }

    /// Deletes media files no clip references (call when closing a project,
    /// never while undo history might still need them).
    @discardableResult
    public func purgeUnusedMedia(of project: inout Project) -> Int {
        let used = Set(project.tracks.flatMap { $0.clips.map(\.mediaID) })
        let unused = project.media.filter { !used.contains($0.id) }
        for m in unused { try? fm.removeItem(at: mediaURL(projectID: project.id, fileName: m.fileName)) }
        project.media.removeAll { !used.contains($0.id) }
        return unused.count
    }
}
