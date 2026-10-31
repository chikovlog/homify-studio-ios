import Foundation

enum AppPaths {
    /// Projects live in Application Support (not visible in Files, backed up).
    static var projectsRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Projects", isDirectory: true)
    }

    /// Finished exports go to Documents/Exports so they are visible in the
    /// Files app ("On My iPhone › Homify Studio").
    static var exportsDirectory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var importScratch: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Import", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
