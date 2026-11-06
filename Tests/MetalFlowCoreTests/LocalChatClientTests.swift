import Foundation
import Testing
@testable import MetalFlowCore

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest, Data) -> (Int, Data))?
    nonisolated(unsafe) static var lastURL: URL?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        Self.lastURL = request.url
        let (status, data) = Self.handler?(request, body) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite(.serialized) struct LocalChatClientTests {
    func makeClient() -> URLSessionChatClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSessionChatClient(session: URLSession(configuration: config), environment: [:])
    }

    @Test func requestBodyHasTheExpectedShape() async throws {
        nonisolated(unsafe) var captured = Data()
        StubURLProtocol.handler = { _, body in
            captured = body
            return (200, Data(#"{"choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}"#.utf8))
        }
        let messages = [
            ChatMessage(role: .system, content: "be brief"),
            ChatMessage(role: .user, content: "hi"),
            ChatMessage(role: .assistant, toolCalls: [ToolCall(id: "c1", name: "Read", arguments: #"{"path":"a"}"#)]),
            ChatMessage(role: .tool, content: "file text", toolCallID: "c1"),
        ]
        let tool = ToolSpec(name: "Read", description: "Read a file", parameters: #"{"type":"object","properties":{"path":{"type":"string"}}}"#)
        _ = try await makeClient().complete(provider: .ollama, model: "qwen2.5-coder:7b", messages: messages, tools: [tool])

        #expect(StubURLProtocol.lastURL?.absoluteString == "http://localhost:11434/v1/chat/completions")
        let json = try #require(JSONSerialization.jsonObject(with: captured) as? [String: Any])
        #expect(json["model"] as? String == "qwen2.5-coder:7b")
        #expect(json["stream"] as? Bool == false)
        let msgs = try #require(json["messages"] as? [[String: Any]])
        #expect(msgs.map { $0["role"] as? String } == ["system", "user", "assistant", "tool"])
        #expect(msgs[1]["content"] as? String == "hi")
        let calls = try #require(msgs[2]["tool_calls"] as? [[String: Any]])
        #expect(calls[0]["id"] as? String == "c1")
        let fn = try #require(calls[0]["function"] as? [String: Any])
        #expect(fn["name"] as? String == "Read")
        #expect(fn["arguments"] as? String == #"{"path":"a"}"#)
        #expect(msgs[3]["tool_call_id"] as? String == "c1")
        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools[0]["type"] as? String == "function")
        let tfn = try #require(tools[0]["function"] as? [String: Any])
        #expect(tfn["name"] as? String == "Read")
        #expect(tfn["description"] as? String == "Read a file")
        #expect((tfn["parameters"] as? [String: Any])?["type"] as? String == "object")
    }

    @Test func textToolCallIsSentBackAsTextWithoutToolCalls() async throws {
        nonisolated(unsafe) var captured = Data()
        StubURLProtocol.handler = { _, body in
            captured = body
            return (200, Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8))
        }
        let text = #"{"name":"Read","arguments":{"path":"a"}}"#
        let messages = [
            ChatMessage(role: .assistant, content: text, toolCalls: [ToolCall(id: "text_0", name: "Read", arguments: #"{"path":"a"}"#)]),
            ChatMessage(role: .tool, content: "file text", toolCallID: "text_0"),
            ChatMessage(role: .assistant, content: nil, toolCalls: [ToolCall(id: "call_1", name: "Read", arguments: #"{"path":"a"}"#)]),
        ]
        _ = try await makeClient().complete(provider: .ollama, model: "m", messages: messages, tools: [])
        let json = try #require(JSONSerialization.jsonObject(with: captured) as? [String: Any])
        let msgs = try #require(json["messages"] as? [[String: Any]])
        #expect(msgs[0]["tool_calls"] == nil)
        #expect(msgs[0]["content"] as? String == text)
        #expect(msgs[1]["role"] as? String == "tool")
        #expect(msgs[1]["tool_call_id"] as? String == "text_0")
        let calls = try #require(msgs[2]["tool_calls"] as? [[String: Any]])
        #expect(calls[0]["id"] as? String == "call_1")
    }

    @Test func omitsToolsWhenEmpty() async throws {
        nonisolated(unsafe) var captured = Data()
        StubURLProtocol.handler = { _, body in
            captured = body
            return (200, Data(#"{"choices":[{"message":{"content":"x"}}]}"#.utf8))
        }
        _ = try await makeClient().complete(provider: .lmstudio, model: "llama3", messages: [ChatMessage(role: .user, content: "hi")], tools: [])
        let json = try #require(JSONSerialization.jsonObject(with: captured) as? [String: Any])
        #expect(json["tools"] == nil)
        #expect(StubURLProtocol.lastURL?.absoluteString == "http://localhost:1234/v1/chat/completions")
    }

    @Test func parsesAToolCallReply() async throws {
        StubURLProtocol.handler = { _, _ in
            (200, Data(#"{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"Grep","arguments":"{\"pattern\":\"foo\"}"}}]},"finish_reason":"tool_calls"}]}"#.utf8))
        }
        let reply = try await makeClient().complete(provider: .ollama, model: "m", messages: [], tools: [])
        #expect(reply.content == nil)
        #expect(reply.finishReason == "tool_calls")
        #expect(reply.toolCalls == [ToolCall(id: "call_1", name: "Grep", arguments: #"{"pattern":"foo"}"#)])
    }

    @Test func parsesAPlainReply() async throws {
        StubURLProtocol.handler = { _, _ in
            (200, Data(#"{"choices":[{"message":{"role":"assistant","content":"Hello"},"finish_reason":"stop"}]}"#.utf8))
        }
        let reply = try await makeClient().complete(provider: .ollama, model: "m", messages: [], tools: [])
        #expect(reply == ChatReply(content: "Hello", toolCalls: [], finishReason: "stop"))
    }

    private func textReply(_ content: String, toolCalls: [ToolCall] = []) -> ChatReply {
        ChatReply(content: content, toolCalls: toolCalls, finishReason: "stop")
    }

    @Test func jsonTextForAKnownToolBecomesAToolCall() {
        let text = #"{"name": "read", "arguments": {"path": "hello.txt"}}"#
        let out = URLSessionChatClient.textToolCallFallback(textReply(text), toolNames: ["read", "grep"])
        #expect(out.toolCalls == [ToolCall(id: "text_0", name: "read", arguments: #"{"path":"hello.txt"}"#)])
        #expect(out.content == text)
    }

    @Test func jsonTextWithStringArgumentsBecomesAToolCall() {
        let text = #"{"name":"read","arguments":"{\"path\":\"a\"}"}"#
        let out = URLSessionChatClient.textToolCallFallback(textReply(text), toolNames: ["read"])
        #expect(out.toolCalls == [ToolCall(id: "text_0", name: "read", arguments: #"{"path":"a"}"#)])
    }

    @Test func jsonTextForAnUnknownToolStaysText() {
        let reply = textReply(#"{"name": "launch", "arguments": {"path": "x"}}"#)
        #expect(URLSessionChatClient.textToolCallFallback(reply, toolNames: ["read"]) == reply)
    }

    @Test func fencedJsonBecomesAToolCall() {
        let text = "```json\n{\"name\": \"read\", \"arguments\": {\"path\": \"hello.txt\"}}\n```"
        let out = URLSessionChatClient.textToolCallFallback(textReply(text), toolNames: ["read"])
        #expect(out.toolCalls == [ToolCall(id: "text_0", name: "read", arguments: #"{"path":"hello.txt"}"#)])
    }

    @Test func existingToolCallsAreNotChanged() {
        let existing = ToolCall(id: "call_1", name: "grep", arguments: "{}")
        let reply = textReply(#"{"name": "read", "arguments": {"path": "x"}}"#, toolCalls: [existing])
        #expect(URLSessionChatClient.textToolCallFallback(reply, toolNames: ["read", "grep"]) == reply)
    }

    @Test func proseIsNotChanged() {
        for text in ["Hello there", #"I will call {"name": "read", "arguments": {}} now"#, "{not json}", ""] {
            let reply = textReply(text)
            #expect(URLSessionChatClient.textToolCallFallback(reply, toolNames: ["read"]) == reply)
        }
    }

    @Test func replyParsingAppliesTheFallbackUsingTheRequestToolNames() async throws {
        StubURLProtocol.handler = { _, _ in
            (200, Data(#"{"choices":[{"message":{"role":"assistant","content":"{\"name\": \"read\", \"arguments\": {\"path\": \"hello.txt\"}}"},"finish_reason":"stop"}]}"#.utf8))
        }
        let spec = ToolSpec(name: "read", description: "d", parameters: "{}")
        let reply = try await makeClient().complete(provider: .ollama, model: "m", messages: [], tools: [spec])
        #expect(reply.toolCalls.map(\.name) == ["read"])
        let none = try await makeClient().complete(provider: .ollama, model: "m", messages: [], tools: [])
        #expect(none.toolCalls.isEmpty)
    }

    @Test func httpErrorSurfacesTheServerMessage() async throws {
        StubURLProtocol.handler = { _, _ in (500, Data(#"{"error":{"message":"boom"}}"#.utf8)) }
        await #expect(throws: LocalChatError.http(status: 500, message: "boom")) {
            _ = try await makeClient().complete(provider: .ollama, model: "m", messages: [], tools: [])
        }
    }

    @Test func httpErrorFallsBackToTheBodyText() async throws {
        StubURLProtocol.handler = { _, _ in (404, Data("  not found\n".utf8)) }
        await #expect(throws: LocalChatError.http(status: 404, message: "not found")) {
            _ = try await makeClient().complete(provider: .ollama, model: "m", messages: [], tools: [])
        }
    }

    @Test func bodyWithoutChoicesIsMalformed() async throws {
        StubURLProtocol.handler = { _, _ in (200, Data(#"{"id":"x"}"#.utf8)) }
        await #expect(throws: LocalChatError.malformed) {
            _ = try await makeClient().complete(provider: .ollama, model: "m", messages: [], tools: [])
        }
    }

    @Test func parsesProviderPrefixes() {
        let a = LocalProvider.parse(model: "ollama:qwen2.5-coder:7b")
        #expect(a?.provider == .ollama)
        #expect(a?.model == "qwen2.5-coder:7b")
        let b = LocalProvider.parse(model: "lmstudio:llama3")
        #expect(b?.provider == .lmstudio)
        #expect(b?.model == "llama3")
        #expect(LocalProvider.parse(model: "sonnet") == nil)
        #expect(LocalProvider.parse(model: "other:thing") == nil)
    }

    @Test func defaultBaseURLsAndOverrides() {
        #expect(LocalProvider.ollama.baseURL(environment: [:]).absoluteString == "http://localhost:11434/v1")
        #expect(LocalProvider.lmstudio.baseURL(environment: [:]).absoluteString == "http://localhost:1234/v1")
        #expect(LocalProvider.ollama.baseURL(environment: ["MF_OLLAMA_URL": "http://box:9/v1"]).absoluteString == "http://box:9/v1")
    }
}
