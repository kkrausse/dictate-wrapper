import Testing
@testable import DictateNemotron

struct DictationEngineTests {
    @Test func defaultsToFluidParakeetUnified1120ms() throws {
        let engine = try DictationEngine.selected(environment: [:])

        #expect(engine == .fluidParakeetUnified1120)
        #expect(engine.rawValue == "fluid-parakeet-unified-1120")
        #expect(engine.displayName == "FluidAudio Parakeet Unified 0.6B (1120 ms)")
    }

    @Test func previousFluidNemotronBackendRemainsAvailable() throws {
        let engine = try DictationEngine.selected(
            environment: ["DICTATE_ASR_BACKEND": "fluid-nemotron-1120"]
        )

        #expect(engine == .fluidNemotron1120)
    }

    @Test func obsoleteFluid560IdentifierIsRejected() {
        #expect(throws: (any Error).self) {
            try DictationEngine.selected(environment: ["DICTATE_ASR_BACKEND": "fluid-nemotron-560"])
        }
    }
}
