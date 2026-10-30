import Foundation
import os

/// An advisory, per-run lock (`flock` on `<root>/runs/<id>.lock`) that keeps two processes from driving one run.
///
/// The lock belongs to the open file description, so it also conflicts between two engines in one process, and the
/// system releases it if the holder dies.
public final class RunLock: Sendable {
    private let fd: OSAllocatedUnfairLock<Int32>

    private init(fd: Int32) { self.fd = OSAllocatedUnfairLock(initialState: fd) }

    /// Takes the exclusive lock on `url` (creating the file) without blocking; nil when someone else holds it.
    public static func tryAcquire(_ url: URL) -> RunLock? {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return RunLock(fd: fd)
    }

    /// Releases the lock; later calls do nothing.
    public func release() {
        fd.withLock { fd in
            guard fd >= 0 else { return }
            flock(fd, LOCK_UN)
            close(fd)
            fd = -1
        }
    }

    deinit { release() }
}
