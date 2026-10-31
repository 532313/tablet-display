import Darwin
import Foundation

/// Keeps a process-wide advisory lock for the lifetime of the app. The lock is
/// released automatically by the kernel if the process exits, crashes or is
/// force-quit, so a stale lock cannot block the next launch.
final class SingleInstanceGuard {
    private let fd: Int32

    private init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        close(fd)
    }

    static func acquire() -> SingleInstanceGuard? {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TabletDisplay", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("instance.lock").path
        let fd = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return SingleInstanceGuard(fd: fd)
    }
}
