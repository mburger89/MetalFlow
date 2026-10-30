import Testing
@testable import MetalFlowCore

@Suite struct TemplateTests {
    @Test func fillReplacesKnownAndKeepsUnknown() {
        #expect(Template.fill("A {x} {y}", with: ["x": "1"]) == "A 1 {y}")
    }

    @Test func doubleBraceIsLiteral() {
        #expect(Template.fill("{{x} {x}", with: ["x": "1"]) == "{x} 1")
    }
}
