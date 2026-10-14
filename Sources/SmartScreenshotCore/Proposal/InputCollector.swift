import Foundation

public struct InputSelection: Sendable, Equatable {
    /// The resolved input path.
    public var root: URL
    public var isDirectory: Bool
    /// Files to process, in a stable order.
    public var files: [URL]
    /// Folder entries skipped because they are subfolders or not supported images. Hidden files are not counted.
    public var ignoredEntryCount: Int
}

public enum InputError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case notFound(String)
    case unreadableFolder(path: String, reason: String)

    public var description: String {
        switch self {
        case .notFound(let path): "no such file or folder: \(path)"
        case .unreadableFolder(let path, let reason): "cannot list folder \(path): \(reason)"
        }
    }
}

/// Resolves the command-line path into the files to process. Only reads directory listings.
public enum InputCollector {
    public static let supportedExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif"]

    public static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// A single file is always returned, even if unsupported, so it can be reported. For a folder, only its
    /// immediate, non-hidden children with supported extensions are returned, sorted by name as Finder does.
    public static func collect(path: String, fileManager: FileManager = .default) throws -> InputSelection {
        let root = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            throw InputError.notFound(root.path)
        }
        guard isDirectory.boolValue else {
            return InputSelection(root: root, isDirectory: false, files: [root], ignoredEntryCount: 0)
        }

        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw InputError.unreadableFolder(path: root.path, reason: error.localizedDescription)
        }

        var files: [URL] = []
        var ignored = 0
        for entry in entries {
            let isRegularFile = (try? entry.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]))?
                .isRegularFile ?? false
            if isRegularFile, isSupported(entry) {
                files.append(entry)
            } else {
                ignored += 1
            }
        }
        files.sort { precedes($0.lastPathComponent, $1.lastPathComponent) }
        return InputSelection(root: root, isDirectory: true, files: files, ignoredEntryCount: ignored)
    }

    /// Finder-like ordering ("Shot 2" before "Shot 10") that does not depend on the current locale.
    static func precedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .numeric, .widthInsensitive, .forcedOrdering], range: nil, locale: nil)
            == .orderedAscending
    }
}
