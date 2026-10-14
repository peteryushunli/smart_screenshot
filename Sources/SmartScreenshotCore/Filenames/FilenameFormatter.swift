import Foundation

/// The date used for a filename's timestamp.
///
/// File creation time approximates capture time: macOS writes a screenshot when it is taken, but copying
/// a file with tools that do not preserve dates (for example `cp` without `-p`) resets it.
public struct FileTimestamp: Sendable, Equatable {
    public enum Source: String, Sendable, Codable {
        case creationTime = "file-creation-time"
        /// Fallback for volumes that do not record creation time.
        case modificationTime = "file-modification-time"
    }

    public var date: Date
    public var source: Source

    public init(date: Date, source: Source) {
        self.date = date
        self.source = source
    }

    public static func read(from fileURL: URL) throws -> FileTimestamp {
        let values = try fileURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        if let created = values.creationDate {
            return FileTimestamp(date: created, source: .creationTime)
        }
        if let modified = values.contentModificationDate {
            return FileTimestamp(date: modified, source: .modificationTime)
        }
        throw CocoaError(.fileReadUnknown)
    }
}

/// Builds `<title> — <yyyy-MM-dd HHmmss>.<original extension>`.
public struct FilenameFormatter: Sendable {
    public static let separator = " — "
    /// APFS limits a filename to 255 bytes of UTF-8.
    public static let maxFilenameBytes = 255

    public var timeZone: TimeZone

    public init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
    }

    public func timestamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return formatter.string(from: date)
    }

    /// `title` must already be sanitized. The extension is preserved exactly, including its case.
    /// Returns nil only if no part of the title fits within the filesystem's filename limit.
    public func filename(title: String, date: Date, pathExtension: String) -> String? {
        let suffix = Self.separator + timestamp(for: date) + (pathExtension.isEmpty ? "" : ".\(pathExtension)")
        var title = title
        while !title.isEmpty, title.utf8.count + suffix.utf8.count > Self.maxFilenameBytes {
            title = TitleSanitizer.trimEdges(String(title.dropLast()))
        }
        return title.isEmpty ? nil : title + suffix
    }
}
