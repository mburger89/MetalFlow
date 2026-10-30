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
    /// The executable name could not be resolved on the search path. A nonexistent absolute path is not resolved
    /// at all, so it surfaces as `launchFailed` instead.
    case executableNotFound(String)
    /// The process could not be started for another reason, such as a missing working directory (executable and error description).
    case launchFailed(String)
    /// The command exited with a non-zero status.
    case failed(Command, exitCode: Int32, stderr: String)
}

extension CommandError: LocalizedError {
    /// A readable message naming the executable and, for failures, the exit code and stderr.
    public var errorDescription: String? {
        switch self {
        case .executableNotFound(let name):
            return "\(name): executable not found on PATH"
        case .launchFailed(let detail):
            return "could not start \(detail)"
        case .failed(let command, let code, let stderr):
            let line = ([command.executable] + command.arguments).joined(separator: " ")
            let shown = line.count > 200 ? String(line.prefix(200)) + "…" : line
            let tail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(command.executable) exited with status \(code) (\(shown))" + (tail.isEmpty ? "" : ": \(tail)")
        }
    }
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
    private var cachedPath: [String]?

    /// Creates a resolver; a nil `searchPath` is read lazily from the login shell.
    public init(searchPath: [String]? = nil) {
        self.cachedPath = searchPath
    }

    /// The directories executables are resolved against (loading the login shell's PATH on first use).
    public func searchPath() async -> [String] { await loadSearchPath() }

    /// Resolves a program name to an executable file URL.
    public func resolve(_ name: String) async throws -> URL {
        if name.hasPrefix("/") { return URL(fileURLWithPath: name) }
        let dirs = await searchPath()
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

    private func loadSearchPath() async -> [String] {
        if let cachedPath { return cachedPath }
        let shellPath = await Self.loginShellPath()
        if let cachedPath { return cachedPath }
        let loaded = shellPath ?? ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let dirs = loaded.split(separator: ":").map(String.init)
        cachedPath = dirs
        return dirs
    }

    /// Asks the login shell for PATH without blocking a thread; after five seconds the shell tree is SIGKILLed.
    private static func loginShellPath() async -> String? {
        let pathSentinel = "__MF_PATH__"
        struct State {
            var data = Data()
            var eof = false
            var status: Int32?
            var done = false
        }
        let box = ProcessBox()
        let process = box.process
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lic", "print -r -- \"\(pathSentinel)$PATH\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let handle = pipe.fileHandleForReading
        let state = OSAllocatedUnfairLock(initialState: State())

        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let complete: @Sendable (Bool) -> Void = { force in
                let result: (Data, Int32?)? = state.withLock { s in
                    guard !s.done, force || (s.eof && s.status != nil) else { return nil }
                    s.done = true
                    return (s.data, s.status)
                }
                guard let (data, status) = result else { return }
                handle.readabilityHandler = nil
                if force { box.killTree() }
                guard status == 0 else { return cont.resume(returning: nil) }
                let text = String(decoding: data, as: UTF8.self)
                cont.resume(returning: text.split(whereSeparator: \.isNewline)
                    .last { $0.hasPrefix(pathSentinel) }
                    .map { String($0.dropFirst(pathSentinel.count)).trimmingCharacters(in: .whitespaces) })
            }
            handle.readabilityHandler = { h in
                let chunk = h.availableData
                if chunk.isEmpty {
                    h.readabilityHandler = nil
                    state.withLock { $0.eof = true }
                    complete(false)
                } else {
                    state.withLock { $0.data.append(chunk) }
                }
            }
            process.terminationHandler = { p in
                state.withLock { $0.status = p.terminationStatus }
                complete(false)
            }
            do { try process.run() } catch {
                handle.readabilityHandler = nil
                state.withLock { $0.done = true }
                return cont.resume(returning: nil)
            }
            box.markStarted()
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { complete(true) }
        }
    }
}

/// Wraps a `Process` so it can be signalled from a cancellation handler.
private final class ProcessBox: @unchecked Sendable {
    let process = Process()
    private let started = OSAllocatedUnfairLock(initialState: false)
    private let terminated = OSAllocatedUnfairLock(initialState: false)

    func markStarted() { started.withLock { $0 = true } }

    /// SIGTERM the whole descendant tree (leaves first, then the child); SIGKILL survivors after five seconds.
    /// Once-only: later calls do nothing.
    func terminate() {
        guard started.withLock({ $0 }), terminated.withLock({ done in
            defer { done = true }
            return !done
        }), process.isRunning else { return }
        let root = process.processIdentifier
        // Collect before signalling: once the parent dies, children are reparented and lost.
        let victims = Self.descendants(of: root) + [root]
        for pid in victims { kill(pid, SIGTERM) }
        Task.detached {
            try? await Task.sleep(for: .seconds(5))
            for pid in victims where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }

    /// SIGKILL the child and all its descendants immediately.
    func killTree() {
        guard started.withLock({ $0 }), process.isRunning else { return }
        let root = process.processIdentifier
        for pid in Self.descendants(of: root) + [root] { kill(pid, SIGKILL) }
    }

    /// True once the process has been launched and has since exited.
    var hasExited: Bool { started.withLock { $0 } && !process.isRunning }

    /// Descendants in post-order, so children precede their parents.
    private static func descendants(of pid: pid_t) -> [pid_t] {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError = FileHandle.nullDevice
        pgrep.standardInput = FileHandle.nullDevice
        do { try pgrep.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        pgrep.waitUntilExit()
        let children = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline).compactMap { pid_t($0) }
        return children.flatMap { descendants(of: $0) + [$0] }
    }
}

/// Runs commands as real child processes.
public struct ProcessRunner: CommandRunner {
    private let resolver: ExecutableResolver

    /// Creates a runner that resolves executables through `resolver`.
    public init(resolver: ExecutableResolver) {
        self.resolver = resolver
    }

    /// Runs the command to completion. Cancelling the calling task terminates the process tree
    /// (SIGTERM, then SIGKILL after five seconds) and throws `CancellationError`, even if the process had just exited.
    public func run(_ c: Command) async throws -> CommandResult {
        let out = try await execute(c, keepStdout: true) { _ in }
        return CommandResult(exitCode: out.exitCode, stdout: out.stdout, stderr: out.stderr)
    }

    /// Streams stdout lines as they arrive and throws `CommandError.failed` at the end on a non-zero exit.
    /// Cancelling the consumer terminates the process tree; a cancellation racing with exit may still surface as `CancellationError`.
    public func lines(_ c: Command) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let out = try await execute(c, keepStdout: false) { continuation.yield($0) }
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

    private func execute(_ c: Command, keepStdout: Bool, onLine: @escaping @Sendable (String) -> Void) async throws -> Output {
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
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        let (outChunks, outCont) = Self.chunks(from: outHandle)
        let (errChunks, errCont) = Self.chunks(from: errHandle)

        // Once-only: stop waiting for EOF (descendants may still hold the pipes open). The handles are never
        // closed here: a readability handler may still be inside `availableData`, so the pipes' file descriptors
        // are closed when the `Pipe` objects deallocate, after this function returns.
        let stopped = OSAllocatedUnfairLock(initialState: false)
        let stopReading: @Sendable () -> Void = {
            guard stopped.withLock({ done in
                defer { done = true }
                return !done
            }) else { return }
            for (h, cont) in [(outHandle, outCont), (errHandle, errCont)] {
                h.readabilityHandler = nil
                cont.finish()
            }
        }

        return try await withTaskCancellationHandler {
            do { try process.run() } catch {
                outHandle.readabilityHandler = nil
                errHandle.readabilityHandler = nil
                throw CommandError.launchFailed("\(url.path): \(error.localizedDescription)")
            }
            box.markStarted()
            if Task.isCancelled { box.terminate() }

            async let outData = Self.consume(outChunks, keep: keepStdout, onLine: onLine)
            async let errData = Self.consume(errChunks, keep: true, onLine: { _ in })
            var status: Int32 = -1
            // Detached so that cancellation does not cut the wait short: the child must really be gone.
            status = await Task.detached { () -> Int32 in
                var code: Int32 = -1
                for await s in exits { code = s }
                return code
            }.value
            if Task.isCancelled { stopReading() }
            // A background descendant may keep the pipes open after the child exits: allow two seconds for EOF.
            let grace = Task.detached {
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { stopReading() }
            }
            let (stdout, stderr) = await (outData, errData)
            grace.cancel()
            if Task.isCancelled { throw CancellationError() }
            return Output(
                exitCode: status,
                stdout: String(decoding: stdout, as: UTF8.self),
                stderr: String(decoding: stderr, as: UTF8.self))
        } onCancel: {
            box.terminate()
            // If the process already exited, the post-exit check may have run before this cancellation.
            if box.hasExited { stopReading() }
        }
    }

    /// Streams a pipe's data through its readability handler until EOF.
    private static func chunks(from handle: FileHandle) -> (AsyncStream<Data>, AsyncStream<Data>.Continuation) {
        let (stream, cont) = AsyncStream<Data>.makeStream()
        handle.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                cont.finish()
            } else {
                cont.yield(data)
            }
        }
        return (stream, cont)
    }

    /// Splits chunks into lines (reported as they complete); returns all bytes only when `keep` is set.
    private static func consume(_ chunks: AsyncStream<Data>, keep: Bool, onLine: @Sendable (String) -> Void) async -> Data {
        var all = Data()
        var pending = Data()
        for await chunk in chunks {
            // After cancellation the result is discarded, so do not work through a backlog of buffered output.
            if Task.isCancelled { break }
            if keep { all.append(chunk) }
            var rest = chunk[...]
            while let nl = rest.firstIndex(of: 0x0A) {
                pending.append(rest[rest.startIndex..<nl])
                onLine(String(decoding: pending, as: UTF8.self))
                pending.removeAll(keepingCapacity: true)
                rest = rest[rest.index(after: nl)...]
            }
            pending.append(rest)
        }
        if !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)) }
        return all
    }
}
