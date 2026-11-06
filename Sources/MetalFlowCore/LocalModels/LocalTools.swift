import Foundation

/// An error whose message is shown to the model as the tool result.
public struct LocalToolError: Error, Sendable, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// A tool description for the model. Task 3 maps this to the client's tool spec.
public struct LocalToolSpec: Sendable, Equatable {
    public let name: String
    public let description: String
    public let parametersJSON: String
    public init(name: String, description: String, parametersJSON: String) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
    }
}

/// File and command tools for a local model, confined to a working directory.
public struct LocalTools: Sendable {
    public static let maxGrepMatches = 200
    public static let maxGlobResults = 500
    public static let maxBashOutput = 20_000
    public static let defaultBashTimeout: TimeInterval = 120

    public let workingDirectory: URL
    private let root: URL

    public init(workingDirectory: URL) {
        self.workingDirectory = workingDirectory
        self.root = Self.resolveSymlinks(workingDirectory.standardizedFileURL)
    }

    // MARK: Specs

    public static let specs: [LocalToolSpec] = [
        LocalToolSpec(
            name: "read",
            description: "Read a UTF-8 text file inside the working directory.",
            parametersJSON: #"{"type":"object","properties":{"path":{"type":"string","description":"File path, relative to the working directory."}},"required":["path"]}"#),
        LocalToolSpec(
            name: "grep",
            description: "Search files for lines matching a regular expression. Returns relative/path:line: text, at most 200 matches.",
            parametersJSON: #"{"type":"object","properties":{"pattern":{"type":"string","description":"Regular expression."},"path":{"type":"string","description":"File or directory to search. Defaults to the working directory."}},"required":["pattern"]}"#),
        LocalToolSpec(
            name: "glob",
            description: "List files matching a glob such as **/*.swift, relative to the working directory.",
            parametersJSON: #"{"type":"object","properties":{"pattern":{"type":"string","description":"Glob pattern."}},"required":["pattern"]}"#),
        LocalToolSpec(
            name: "edit",
            description: "Replace exactly one occurrence of old_string with new_string in a file. old_string must be unique in the file.",
            parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"},"old_string":{"type":"string","description":"Text to replace. Must occur exactly once."},"new_string":{"type":"string"}},"required":["path","old_string","new_string"]}"#),
        LocalToolSpec(
            name: "write",
            description: "Create or overwrite a file with the given content, creating parent directories.",
            parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}"#),
        LocalToolSpec(
            name: "bash",
            description: "Run a command without a shell. Pipes, redirects, ; & ` and $( are refused. Returns the exit code and combined output.",
            parametersJSON: #"{"type":"object","properties":{"command":{"type":"string"},"timeout":{"type":"number","description":"Seconds before the process is killed. Default 120."}},"required":["command"]}"#),
    ]

    // MARK: Path confinement

    /// Resolves symlinks component by component, including ones that do not
    /// exist yet at the tail and dangling links.
    private static func resolveSymlinks(_ url: URL, depth: Int = 0) -> URL {
        let fm = FileManager.default
        var current = "/"
        for comp in url.standardizedFileURL.pathComponents where comp != "/" {
            let next = (current as NSString).appendingPathComponent(comp)
            if depth < 40, let dest = try? fm.destinationOfSymbolicLink(atPath: next) {
                let target = dest.hasPrefix("/") ? dest : (current as NSString).appendingPathComponent(dest)
                current = resolveSymlinks(URL(fileURLWithPath: target), depth: depth + 1).path
            } else {
                current = next
            }
        }
        return URL(fileURLWithPath: current)
    }

    private func isInside(_ url: URL) -> Bool {
        url.path == root.path || url.path.hasPrefix(root.path + "/")
    }

    /// Resolves `path` against the working directory and refuses anything that leaves it.
    func confined(_ path: String) throws -> URL {
        let base = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : workingDirectory.appendingPathComponent(path)
        let resolved = Self.resolveSymlinks(base.standardizedFileURL)
        guard isInside(resolved) else {
            throw LocalToolError("Path '\(path)' is outside the working directory.")
        }
        return resolved
    }

    private func relative(_ url: URL) -> String {
        url.path == root.path ? "." : String(url.path.dropFirst(root.path.count + 1))
    }

    // MARK: read

    public func read(path: String) throws -> String {
        let url = try confined(path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw LocalToolError("No such file: \(path)")
        }
        if isDir.boolValue { throw LocalToolError("'\(path)' is a directory, not a file.") }
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw LocalToolError("Could not read \(path).")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw LocalToolError("'\(path)' is not valid UTF-8 text.")
        }
        return text
    }

    // MARK: file walking

    /// Files under `start` (or `start` itself), skipping hidden directories and
    /// anything whose real location leaves the working directory.
    private func files(under start: URL) -> [URL] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: start.path, isDirectory: &isDir) else { return [] }
        if !isDir.boolValue { return [start] }
        var result: [URL] = []
        guard let walker = fm.enumerator(at: start, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return [] }
        for case let item as URL in walker {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                if item.lastPathComponent.hasPrefix(".") { walker.skipDescendants() }
                continue
            }
            let real = Self.resolveSymlinks(item)
            guard isInside(real) else { continue }
            if fm.fileExists(atPath: real.path, isDirectory: &isDir), !isDir.boolValue {
                result.append(real)
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    // MARK: grep

    public func grep(pattern: String, path: String? = nil) throws -> String {
        let regex: NSRegularExpression
        do { regex = try NSRegularExpression(pattern: pattern) }
        catch { throw LocalToolError("Invalid regular expression: \(pattern)") }
        let start = try confined(path ?? ".")
        guard FileManager.default.fileExists(atPath: start.path) else {
            throw LocalToolError("No such path: \(path ?? ".")")
        }
        var lines: [String] = []
        var truncated = false
        outer: for file in files(under: start) {
            guard let data = FileManager.default.contents(atPath: file.path), data.count <= 5_000_000,
                  let text = String(data: data, encoding: .utf8) else { continue }
            let rel = relative(file)
            var number = 0
            for line in text.components(separatedBy: "\n") {
                number += 1
                let range = NSRange(line.startIndex..., in: line)
                if regex.firstMatch(in: line, range: range) != nil {
                    if lines.count >= Self.maxGrepMatches { truncated = true; break outer }
                    lines.append("\(rel):\(number): \(line)")
                }
            }
        }
        if lines.isEmpty { return "No matches." }
        if truncated { lines.append("[output cut at \(Self.maxGrepMatches) matches]") }
        return lines.joined(separator: "\n")
    }

    // MARK: glob

    public func glob(pattern: String) throws -> String {
        let regex = try Self.globRegex(pattern)
        var matches: [String] = []
        for file in files(under: root) {
            let rel = relative(file)
            if regex.firstMatch(in: rel, range: NSRange(rel.startIndex..., in: rel)) != nil {
                matches.append(rel)
            }
        }
        matches.sort()
        if matches.isEmpty { return "No files matched." }
        if matches.count > Self.maxGlobResults {
            matches = Array(matches.prefix(Self.maxGlobResults))
            matches.append("[output cut at \(Self.maxGlobResults) paths]")
        }
        return matches.joined(separator: "\n")
    }

    private static func globRegex(_ glob: String) throws -> NSRegularExpression {
        var out = "^"
        let chars = Array(glob)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "*" {
                if i + 1 < chars.count, chars[i + 1] == "*" {
                    if i + 2 < chars.count, chars[i + 2] == "/" {
                        out += "(?:.*/)?"
                        i += 3
                    } else {
                        out += ".*"
                        i += 2
                    }
                    continue
                }
                out += "[^/]*"
            } else if c == "?" {
                out += "[^/]"
            } else {
                out += NSRegularExpression.escapedPattern(for: String(c))
            }
            i += 1
        }
        out += "$"
        do { return try NSRegularExpression(pattern: out) }
        catch { throw LocalToolError("Invalid glob: \(glob)") }
    }

    // MARK: edit and write

    public func edit(path: String, oldString: String, newString: String) throws -> String {
        guard !oldString.isEmpty else { throw LocalToolError("old_string must not be empty.") }
        let text = try read(path: path)
        let count = text.components(separatedBy: oldString).count - 1
        if count == 0 { throw LocalToolError("old_string was not found in \(path).") }
        if count > 1 {
            throw LocalToolError("old_string appears \(count) times in \(path). Include more surrounding text so it is unique.")
        }
        let url = try confined(path)
        let updated = text.replacingOccurrences(of: oldString, with: newString)
        do { try updated.write(to: url, atomically: true, encoding: .utf8) }
        catch { throw LocalToolError("Could not write \(path): \(error.localizedDescription)") }
        return "Edited \(path)."
    }

    public func write(path: String, content: String) throws -> String {
        let url = try confined(path)
        let parent = url.deletingLastPathComponent()
        guard isInside(Self.resolveSymlinks(parent)) else {
            throw LocalToolError("Path '\(path)' is outside the working directory.")
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            throw LocalToolError("'\(path)' is a directory.")
        }
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw LocalToolError("Could not write \(path): \(error.localizedDescription)")
        }
        return "Wrote \(content.utf8.count) bytes to \(path)."
    }

    // MARK: bash

    public func bash(command: String, timeout: TimeInterval = LocalTools.defaultBashTimeout) async throws -> String {
        if let op = CommandWords.forbiddenOperator(in: command) {
            throw LocalToolError("Refused: the command contains '\(op)'. Commands run without a shell, so pipes, redirects, chaining and substitution are not available.")
        }
        guard let words = CommandWords.split(command) else {
            throw LocalToolError("Refused: unbalanced quote in the command.")
        }
        guard !words.isEmpty else { throw LocalToolError("The command is empty.") }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = words
        process.currentDirectoryURL = root
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let buffer = OutputBuffer(limit: Self.maxBashOutput * 4)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { buffer.append(data) }
        }

        let timedOut = Flag()
        let status: Int32 = await withCheckedContinuation { continuation in
            process.terminationHandler = { p in continuation.resume(returning: p.terminationStatus) }
            do { try process.run() }
            catch {
                buffer.append(Data("Could not start: \(error.localizedDescription)".utf8))
                process.terminationHandler = nil
                continuation.resume(returning: 127)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                timedOut.set()
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        if !timedOut.value, let rest = try? pipe.fileHandleForReading.readToEnd() { buffer.append(rest) }

        let (data, overflow) = buffer.snapshot()
        var text = String(decoding: data, as: UTF8.self)
        var cut = overflow
        if text.count > Self.maxBashOutput {
            text = String(text.prefix(Self.maxBashOutput))
            cut = true
        }
        var result = ""
        if timedOut.value { result += "Timed out after \(Int(timeout)) seconds; the process was killed.\n" }
        result += "exit code: \(status)\n\(text)"
        if cut { result += "\n[output cut at \(Self.maxBashOutput) characters]" }
        return result
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var overflow = false
    private let limit: Int
    init(limit: Int) { self.limit = limit }
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        let room = limit - data.count
        if chunk.count > room { overflow = true }
        if room > 0 { data.append(chunk.prefix(room)) }
    }
    func snapshot() -> (Data, Bool) {
        lock.lock(); defer { lock.unlock() }
        return (data, overflow)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
