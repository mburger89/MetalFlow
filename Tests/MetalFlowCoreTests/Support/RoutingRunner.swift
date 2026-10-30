import Foundation
@testable import MetalFlowCore

/// Routes `gh` to a fake and everything else to real processes.
struct RoutingRunner: CommandRunner {
    let gh: FakeCommandRunner
    let process = ProcessRunner(resolver: ExecutableResolver(searchPath: ["/usr/bin", "/bin", "/opt/homebrew/bin", "/usr/local/bin"]))

    private func target(_ c: Command) -> any CommandRunner {
        c.executable == "gh" ? gh : process
    }

    func run(_ c: Command) async throws -> CommandResult { try await target(c).run(c) }
    func lines(_ c: Command) -> AsyncThrowingStream<String, Error> { target(c).lines(c) }
}
