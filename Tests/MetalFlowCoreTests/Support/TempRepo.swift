import Foundation

/// A throwaway git repository with one commit on `main`; removed on deinit.
final class TempRepo: Sendable {
    /// Symlink-resolved repository root.
    let url: URL
    private let root: URL

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("metalflow-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        url = URL(fileURLWithPath: root.appendingPathComponent("repo").resolvingSymlinksInPath().path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try git(["init", "-b", "main"])
        try git(["config", "user.name", "Test"])
        try git(["config", "user.email", "test@example.com"])
        try git(["config", "commit.gpgsign", "false"])
        try write("README.md", "hello\n")
        try commit("initial")
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// A fresh path inside the temp area for a worktree.
    func worktreePath(_ name: String) -> URL {
        root.appendingPathComponent(name)
    }

    /// Writes a file relative to the repo root (or `dir`).
    func write(_ name: String, _ content: String, in dir: URL? = nil) throws {
        try content.write(to: (dir ?? url).appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// Stages everything and commits.
    func commit(_ message: String) throws {
        try git(["add", "-A"])
        try git(["commit", "-m", message])
    }

    /// Runs git in the repo and returns stdout.
    @discardableResult
    func git(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", url.path] + args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        _ = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw NSError(domain: "TempRepo", code: Int(p.terminationStatus)) }
        return String(decoding: data, as: UTF8.self)
    }
}
