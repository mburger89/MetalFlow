import Foundation

/// Flows shipped with the app.
public enum BuiltinFlows {
    /// Plan with Opus, implement with three models in parallel, gate on `swift test`, judge, then pick.
    public static let fixGitHubIssue = Flow(
        name: "Fix GitHub issue",
        nodes: [
            Node(id: "issue", title: "Issue", kind: .flowInput(FlowInputConfig(name: "issue", source: .githubIssue)), position: Point(x: 24, y: 60)),
            Node(id: "repo", title: "Repo", kind: .repo, position: Point(x: 24, y: 300)),
            Node(id: "plan", title: "Plan", kind: .prompt(PromptConfig(
                model: "opus",
                prompt: "Read this GitHub issue and the code in this repository ({repo}), then write a short numbered plan to fix it. Do not edit files.\n\nIssue:\n{issue}",
                candidates: [],
                allowedTools: ["Read", "Grep", "Glob"],
                maxTurns: nil)), position: Point(x: 264, y: 140)),
            Node(id: "implement", title: "Implement", kind: .prompt(PromptConfig(
                model: "sonnet",
                prompt: "Fix this GitHub issue by following the plan. Keep the public API unchanged, add a test that fails before your change, and stop when swift test passes.\n\nIssue:\n{issue}\n\nPlan:\n{plan}",
                candidates: ["sonnet", "opus", "haiku"],
                allowedTools: ["Read", "Edit", "Write", "Grep", "Glob", "Bash(swift build:*)", "Bash(swift test:*)"],
                maxTurns: nil)), position: Point(x: 504, y: 185)),
            Node(id: "gate", title: "swift test", kind: .gate(ShellConfig(command: "swift test")), position: Point(x: 744, y: 185)),
            Node(id: "judge", title: "Recommend", kind: .judge(PromptConfig(
                model: "opus",
                prompt: "You are judging candidate fixes for this issue. Prefer candidates whose tests pass, then the smallest correct diff. Explain briefly, then end with a final line `RECOMMEND: <lane>`.\n\nIssue:\n{issue}\n\nCandidates:\n{candidates}",
                candidates: [],
                allowedTools: ["Read"],
                maxTurns: nil)), position: Point(x: 984, y: 90)),
            Node(id: "pick", title: "Pick & merge", kind: .pick, position: Point(x: 984, y: 330)),
        ],
        wires: [
            Wire(from: "issue", to: "plan", input: "issue"),
            Wire(from: "repo", to: "plan", input: "repo"),
            Wire(from: "plan", to: "implement", input: "plan"),
            Wire(from: "issue", to: "implement", input: "issue"),
            Wire(from: "implement", to: "gate", input: "code"),
            Wire(from: "gate", to: "judge", input: "results"),
            Wire(from: "issue", to: "judge", input: "issue"),
            Wire(from: "judge", to: "pick", input: "recommendation"),
        ])
}
