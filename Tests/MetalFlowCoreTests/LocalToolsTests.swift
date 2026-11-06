import Foundation
import Testing
@testable import MetalFlowCore

@Suite("LocalTools")
struct LocalToolsTests {
    /// Runs `body` with a fresh temporary working directory, removed afterwards.
    private func withTemp(_ body: (URL, LocalTools) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await body(dir, LocalTools(workingDirectory: dir))
    }

    private func put(_ dir: URL, _ path: String, _ text: String) throws {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func refuses(_ body: () throws -> String) -> Bool {
        do { _ = try body(); return false } catch is LocalToolError { return true } catch { return false }
    }

    @Test func readsAFile() async throws {
        try await withTemp { dir, tools in
            try put(dir, "a.txt", "hello")
            #expect(try tools.read(path: "a.txt") == "hello")
        }
    }

    @Test func readRefusesADirectory() async throws {
        try await withTemp { dir, tools in
            try put(dir, "sub/a.txt", "x")
            #expect(refuses { try tools.read(path: "sub") })
        }
    }

    @Test func grepFindsLinesAndSkipsGit() async throws {
        try await withTemp { dir, tools in
            try put(dir, "src/a.swift", "one\nneedle here\nthree")
            try put(dir, ".git/config", "needle in git")
            let out = try tools.grep(pattern: "needle")
            #expect(out == "src/a.swift:2: needle here")
        }
    }

    @Test func grepCapsMatches() async throws {
        try await withTemp { dir, tools in
            try put(dir, "a.txt", String(repeating: "hit\n", count: 300))
            let out = try tools.grep(pattern: "hit")
            #expect(out.components(separatedBy: "\n").count == 201)
            #expect(out.contains("cut at 200"))
        }
    }

    @Test func globMatchesRecursivePattern() async throws {
        try await withTemp { dir, tools in
            try put(dir, "top.swift", "")
            try put(dir, "a/b/deep.swift", "")
            try put(dir, "a/note.txt", "")
            try put(dir, ".build/skip.swift", "")
            #expect(try tools.glob(pattern: "**/*.swift") == "a/b/deep.swift\ntop.swift")
        }
    }

    @Test func editReplacesAUniqueString() async throws {
        try await withTemp { dir, tools in
            try put(dir, "a.txt", "alpha beta")
            _ = try tools.edit(path: "a.txt", oldString: "beta", newString: "gamma")
            #expect(try tools.read(path: "a.txt") == "alpha gamma")
        }
    }

    @Test func editRefusesMissingDuplicatedAndEmpty() async throws {
        try await withTemp { dir, tools in
            try put(dir, "a.txt", "x x")
            #expect(refuses { try tools.edit(path: "a.txt", oldString: "nope", newString: "y") })
            #expect(refuses { try tools.edit(path: "a.txt", oldString: "x", newString: "y") })
            #expect(refuses { try tools.edit(path: "a.txt", oldString: "", newString: "y") })
            #expect(try tools.read(path: "a.txt") == "x x")
        }
    }

    @Test func writeCreatesANestedFile() async throws {
        try await withTemp { _, tools in
            _ = try tools.write(path: "one/two/c.txt", content: "data")
            #expect(try tools.read(path: "one/two/c.txt") == "data")
        }
    }

    @Test func dotDotEscapeIsRefused() async throws {
        try await withTemp { _, tools in
            #expect(refuses { try tools.read(path: "../x") })
            #expect(refuses { try tools.write(path: "../x", content: "") })
        }
    }

    @Test func absolutePathOutsideIsRefused() async throws {
        try await withTemp { _, tools in
            #expect(refuses { try tools.read(path: "/etc/hosts") })
            #expect(refuses { try tools.grep(pattern: "x", path: "/etc") })
        }
    }

    @Test func symlinkOutsideIsRefusedForReadAndWrite() async throws {
        try await withTemp { dir, tools in
            let outside = FileManager.default.temporaryDirectory
                .appendingPathComponent("lt-outside-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: outside) }
            try "secret".write(to: outside.appendingPathComponent("s.txt"), atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link"), withDestinationURL: outside)
            try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("file-link"), withDestinationURL: outside.appendingPathComponent("s.txt"))
            #expect(refuses { try tools.read(path: "link/s.txt") })
            #expect(refuses { try tools.read(path: "file-link") })
            #expect(refuses { try tools.write(path: "link/new.txt", content: "x") })
            #expect(refuses { try tools.write(path: "link/sub/new.txt", content: "x") })
            #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("new.txt").path))
        }
    }

    @Test func bashRunsACommand() async throws {
        try await withTemp { _, tools in
            let out = try await tools.bash(command: "echo hi")
            #expect(out.contains("exit code: 0"))
            #expect(out.contains("hi"))
        }
    }

    @Test func bashHonoursQuotes() async throws {
        try await withTemp { _, tools in
            let out = try await tools.bash(command: "echo 'a  b'")
            #expect(out.contains("a  b"))
        }
    }

    @Test func bashRefusesOperators() async throws {
        try await withTemp { _, tools in
            for command in ["echo a; echo b", "echo a && echo b", "echo a | cat", "echo a > f", "echo `ls`", "echo $(ls)", "echo a\necho b"] {
                do {
                    _ = try await tools.bash(command: command)
                    Issue.record("Expected a refusal for \(command)")
                } catch is LocalToolError {}
            }
        }
    }

    @Test func bashTimesOut() async throws {
        try await withTemp { _, tools in
            let start = Date()
            let out = try await tools.bash(command: "sleep 5", timeout: 1)
            #expect(out.contains("Timed out"))
            #expect(Date().timeIntervalSince(start) < 4)
        }
    }

    @Test func bashOutputIsCapped() async throws {
        try await withTemp { dir, tools in
            try put(dir, "big.txt", String(repeating: "x", count: 50_000))
            let out = try await tools.bash(command: "cat big.txt")
            #expect(out.contains("cut at 20000"))
            #expect(out.count < 20_200)
        }
    }

    @Test func specsCoverTheSixTools() {
        #expect(LocalTools.specs.map(\.name) == ["read", "grep", "glob", "edit", "write", "bash"])
    }
}
