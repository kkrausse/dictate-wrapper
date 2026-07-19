import XCTest
@testable import DictateNemotron

final class DictationEngineTests: XCTestCase {
    func testDefaultsToFluidParakeetUnified1120ms() throws {
        let engine = try DictationEngine.selected(environment: [:])

        XCTAssertEqual(engine, .fluidParakeetUnified1120)
        XCTAssertEqual(engine.rawValue, "fluid-parakeet-unified-1120")
        XCTAssertEqual(engine.displayName, "FluidAudio Parakeet Unified 0.6B (1120 ms)")
    }

    func testPreviousFluidNemotronBackendRemainsAvailable() throws {
        let engine = try DictationEngine.selected(
            environment: ["DICTATE_ASR_BACKEND": "fluid-nemotron-1120"]
        )

        XCTAssertEqual(engine, .fluidNemotron1120)
    }

    func testObsoleteFluid560IdentifierIsRejected() {
        XCTAssertThrowsError(
            try DictationEngine.selected(environment: ["DICTATE_ASR_BACKEND": "fluid-nemotron-560"])
        )
    }
}
