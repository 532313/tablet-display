import Foundation

enum AppLog {
    private static let lock = NSLock()

    static let fileURL: URL = {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("TabletDisplay.log")
    }()

    static func write(_ message: String) {
        let line = "\(Date()) \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        fputs(line, stderr)
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: fileURL)
        }
    }
}
