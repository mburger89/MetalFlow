import Testing
@testable import MetalFlowKit

@Suite struct LocalModelInspectorTests {
    @Test func validatesLocalModelNames() {
        #expect(isValidLocalModel("ollama:x"))
        #expect(isValidLocalModel("lmstudio:y:z"))
        #expect(!isValidLocalModel("sonnet"))
        #expect(!isValidLocalModel("ollama:"))
        #expect(!isValidLocalModel("foo:bar"))
    }
}
