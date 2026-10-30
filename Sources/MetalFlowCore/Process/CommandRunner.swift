import Foundation
import os

/// An external program invocation.
public struct Command: Sendable, Hashable {
    /// Program name (searched on PATH) or absolute path.
    public var executable: String
    /// Arguments passed to the program.
    public var arguments: [String]
    /// Working directory for the process; inherits the current one when nil.
    public var workingDirectory: URL?
    /// Extra environment variables merged over the inherited environment.
    public var environment: [String: String]

    /// Creates a command.
    public init(executable: String, arguments: [String] = [], workingDirectory: URL? = nil, environment: [String: String] = [:]) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
    }
}

/// The captured outcome of a finished command.
public struct CommandResult: Sendable {
    /// Process exit status.
    public var exitCode: Int32
    /// Everything written to standard output.
    public var stdout: String
    /// Everything written to standard error.
    public var stderr: String
    /// True when the exit status is zero.
    public var succeeded: Bool { exitCode == 0 }

    /// Creates a result.
    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Failures from running a command.
public enum CommandError: Error, Equatable {
    /// The executable could not be found or launched.
    case executableNotFound(String)
    /// The command exited with a non-zero status.
    case failed(Command, exitCode: Int32, stderr: String)
}

/// Runs external programs.
public protocol CommandRunner: Sendable {
    /// Runs a command to completion and captures its output, whatever the exit code.
    func run(_ c: Command) async throws -> CommandResult
    /// Streams stdout line by line; throws `CommandError.failed` at the end on a non-zero exit.
    func lines(_ c: Command) -> AsyncThrowingStream<String, Error>
}

extension CommandRunner {
    /// Runs a command and throws `CommandError.failed` on a non-zero exit.
    @discardableResult
    public func check(_ c: Command) async throws -> CommandResult {
        let result = try await run(c)
        guard result.succeeded else {
            throw CommandError.failed(c, exitCode: result.exitCode, stderr: result.stderr)
        }
        return result
    }
}

/// Finds executables on a search path, defaulting to the login shell's PATH.
public actor ExecutableResolver {
    private var searchPath: [String]?

    /// Creates a resolver; a nil `searchPath` is read lazily from the login shell.
    public init(searchPath: [String]? = nil) {
        self.searchPath = searchPath
    }

    /// Resolves a program name to an executable file URL.
    public func resolve(_ name: String) async throws -> URL {
        if name.hasPrefix("/") { return URL(fileURLWithPath: name) }
        let dirs = loadSearchPath()
        for dir in dirs {
            let path = (dir as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            if FileManager.default.isExecutableFile(atPath: path),
               FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue {
                return URL(fileURLWithPath: path)
            }
        }
        throw CommandError.executableNotFound(name)
    }

    private func loadSearchPath() -> [String] {
        if let searchPath { return searchPath }
        let loaded = Self.loginShellPath() ?? ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let dirs = loaded.split(separator: ":").map(String.init)
        searchPath = dirs
        return dirs
    }

    private static func loginShellPath() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lic", "print -r -- $PATH"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return nil }
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }
}

/// Wraps a `Process` so it can be signalled from a cancellation handler.
private final class ProcessBox: @unchecked Sendable {
    let process = Process()
    private let started = OSAllocatedUnfairLock(initialState: false)

    func markStarted() { started.withLock { $0 = true } }

    /// SIGTERM now, SIGKILL after five seconds if the process is still alive.
    func terminate() {
        guard started.withLock({ $0 }), process.isRunning else { return }
        let pid = process.processIdentifier
        kill(pid, SIGTERM)
        let process = process
        Task.detached {
            try? await Task.sleep(for: .seconds(5))
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}

/// Runs commands as real child processes.
public struct ProcessRunner: CommandRunner {
    private let resolver: ExecutableResolver

    /// Creates a runner that resolves executables through `resolver`.
    public init(resolver: ExecutableResolver) {
        self.resolver = resolver
    }

    public func run(_ c: Command) async throws -> CommandResult {
        let out = try await execute(c) { _ in }
        return CommandResult(exitCode: out.exitCode, stdout: out.stdout, stderr: out.stderr)
    }

    public func lines(_ c: Command) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let out = try await execute(c) { continuation.yield($0) }
                    if out.exitCode != 0 {
                        continuation.finish(throwing: CommandError.failed(c, exitCode: out.exitCode, stderr: out.stderr))
                    } else {
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct Output {
        var exitCode: Int32
        var stdout: String
        var stderr: String
    }

    private func execute(_ c: Command, onLine: @escaping @Sendable (String) -> Void) async throws -> Output {
        let url = try await resolver.resolve(c.executable)
        let box = ProcessBox()
        let process = box.process
        process.executableURL = url
        process.arguments = c.arguments
        process.currentDirectoryURL = c.workingDirectory
        if !c.environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(c.environment) { _, new in new }
        }
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        let (exits, exitCont) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { p in
            exitCont.yield(p.terminationStatus)
            exitCont.finish()
        }

        return try await withTaskCancellationHandler {
            do { try process.run() } catch { throw CommandError.executableNotFound(c.executable) }
            box.markStarted()
            if Task.isCancelled { box.terminate() }

            let outHandle = outPipe.fileHandleForReading
            let errHandle = errPipe.fileHandleForReading
            async let outData = Self.readLines(outHandle, onLine: onLine)
            async let errData = Self.readLines(errHandle, onLine: { _ in })
            let (stdout, stderr) = await (outData, errData)
            var status: Int32 = -1
            for await s in exits { status = s }
            if Task.isCancelled { throw CancellationError() }
            return Output(
                exitCode: status,
                stdout: String(decoding: stdout, as: UTF8.self),
                stderr: String(decoding: stderr, as: UTF8.self))
        } onCancel: {
            box.terminate()
        }
    }

    /// Reads a pipe to EOF via its readability handler, reporting each completed line and returning all bytes.
    private static func readLines(_ handle: FileHandle, onLine: @Sendable (String) -> Void) async -> Data {
        let (chunks, cont) = AsyncStream<Data>.makeStream()
        handle.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                cont.finish()
            } else {
                cont.yield(data)
            }
        }
        var all = Data()
        var current = Data()
        for await chunk in chunks {
            all.append(chunk)
            for byte in chunk {
                if byte == 0x0A {
                    onLine(String(decoding: current, as: UTF8.self))
                    current.removeAll(keepingCapacity: true)
                } else {
                    current.append(byte)
                }
            }
        }
        if !current.isEmpty { onLine(String(decoding: current, as: UTF8.self)) }
        return all
    }
}
