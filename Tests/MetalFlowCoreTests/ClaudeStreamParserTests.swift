import Foundation
import Testing
@testable import MetalFlowCore

func fixtureLines(_ name: String) throws -> [String] {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init)
}

func parseFixture(_ name: String) throws -> [AgentEvent] {
    var parser = ClaudeStreamParser()
    return try fixtureLines(name).flatMap { try parser.parse(line: $0) }
}

@Suite struct ClaudeStreamParserTests {
    @Test func parsesSuccessFixture() throws {
        let events = try parseFixture("success")
        guard case .started = events.first else { Issue.record("first event not started"); return }
        guard case .finished(let r)? = events.last else { Issue.record("last event not finished"); return }
        #expect(r.text.contains("OK"))
        #expect(!r.isError)
        #expect(!r.sessionID.isEmpty)
        #expect(r.turns >= 1)
        #expect(events.contains(.text("OK")))
    }

    @Test func parsesDeniedFixture() throws {
        let events = try parseFixture("denied")
        guard case .finished(let r)? = events.last else { Issue.record("last event not finished"); return }
        #expect(r.deniedTools == ["Bash", "Write"])
        #expect(events.contains { if case .toolUse(let name, _) = $0 { name == "Bash" } else { false } })
    }

    @Test func parsesResumeFixtureKeepsSessionID() throws {
        let events = try parseFixture("resume")
        guard case .started(let id)? = events.first, case .finished(let r)? = events.last else {
            Issue.record("unexpected shape"); return
        }
        #expect(r.sessionID == id)
    }

    /// Measured with real `claude` on 2026-11-02: resuming an unknown session prints this one line and no `init` event.
    @Test func lostSessionLineReadsAsALostSession() throws {
        let line = #"{"type":"result","subtype":"error_during_execution","duration_ms":0,"duration_api_ms":0,"is_error":true,"num_turns":0,"stop_reason":null,"session_id":"00000000-0000-4000-8000-000000000000","total_cost_usd":0,"errors":["No conversation found with session ID: 00000000-0000-4000-8000-000000000000"],"result_index":0}"#
        var parser = ClaudeStreamParser()
        let events = try parser.parse(line: line)
        guard events.count == 1, case .finished(let r) = events[0] else { Issue.record("expected one finished event"); return }
        #expect(r.text == "No conversation found with session ID: 00000000-0000-4000-8000-000000000000")
        #expect(r.isError)
        #expect(r.sessionLost)
    }

    @Test func otherErrorsAreNotALostSession() throws {
        var parser = ClaudeStreamParser()
        let plain = try parser.parse(line: #"{"type":"result","is_error":true,"num_turns":0,"result":"boom","errors":["No conversation found"]}"#)
        guard case .finished(let a)? = plain.first else { Issue.record("no result"); return }
        #expect(a.text == "boom", "a result text wins over errors")
        let turns = try parser.parse(line: #"{"type":"result","is_error":true,"num_turns":3,"errors":["No conversation found with session ID: x"]}"#)
        guard case .finished(let b)? = turns.first else { Issue.record("no result"); return }
        #expect(b.text == "No conversation found with session ID: x" && !b.sessionLost)
        let other = try parser.parse(line: #"{"type":"result","is_error":true,"num_turns":0,"result":"","errors":["usage limit","second"]}"#)
        guard case .finished(let c)? = other.first else { Issue.record("no result"); return }
        #expect(c.text == "usage limit\nsecond" && !c.sessionLost)
    }

    @Test func resultsSavedWithoutSessionLostDecodeAsFalse() throws {
        let old = #"{"sessionID":"s","text":"hi","isError":false,"deniedTools":[],"costUSD":0,"turns":1}"#
        let r = try JSONDecoder().decode(AgentResult.self, from: Data(old.utf8))
        #expect(!r.sessionLost)
        let lost = AgentResult(sessionID: "s", text: "t", isError: true, deniedTools: [], costUSD: 0, turns: 0, sessionLost: true)
        #expect(try JSONDecoder().decode(AgentResult.self, from: JSONEncoder().encode(lost)) == lost)
    }

    @Test func questionLineIsExtracted() {
        func result(_ text: String) -> AgentResult {
            AgentResult(sessionID: "s", text: text, isError: false, deniedTools: [], costUSD: 0, turns: 1)
        }
        #expect(result("I looked.\nQUESTION: Squash or merge?").question == "Squash or merge?")
        #expect(result("QUESTION: first\nmore\nQUESTION:  second  ").question == "second")
        #expect(result("nothing to ask").question == nil)
    }

    @Test func toolUseSummaryIsSortedCompactAndTruncated() throws {
        let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"b":1,"a":"x"}}]}}"#
        var parser = ClaudeStreamParser()
        #expect(try parser.parse(line: line) == [.toolUse(name: "Edit", summary: #"{"a":"x","b":1}"#)])
        let long = String(repeating: "z", count: 200)
        let big = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"c":"\#(long)"}}]}}"#
        guard case .toolUse(_, let summary)? = try parser.parse(line: big).first else { Issue.record("no toolUse"); return }
        #expect(summary.count == 80)
    }

    @Test func ignoresUnknownAndThrowsOnMalformed() throws {
        var parser = ClaudeStreamParser()
        #expect(try parser.parse(line: #"{"type":"rate_limit_event"}"#).isEmpty)
        #expect(try parser.parse(line: #"{"type":"system","subtype":"permission_denied","tool_name":"Write"}"#).isEmpty)
        #expect(try parser.parse(line: #"{"type":"user","message":{"content":[]}}"#).isEmpty)
        #expect(throws: ClaudeStreamError.self) { try parser.parse(line: "not json") }
    }

    @Test func resultCodableRoundTripOmitsQuestion() throws {
        let r = AgentResult(sessionID: "s", text: "QUESTION: q", isError: false, deniedTools: [], costUSD: 0.5, turns: 2)
        let data = try JSONEncoder().encode(r)
        #expect(!String(decoding: data, as: UTF8.self).contains("\"question\""))
        #expect(try JSONDecoder().decode(AgentResult.self, from: data) == r)
    }
}
