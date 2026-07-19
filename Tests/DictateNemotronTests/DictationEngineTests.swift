import XCTest
@testable import DictateNemotron

final class DictationEngineTests: XCTestCase {
    func testDefaultsToFluidNemotron1120ms() throws {
        let engine = try DictationEngine.selected(environment: [:])

        XCTAssertEqual(engine, .fluidNemotron1120)
        XCTAssertEqual(engine.rawValue, "fluid-nemotron-1120")
        XCTAssertEqual(engine.displayName, "FluidAudio Nemotron 0.6B (1120 ms)")
    }

    func testObsoleteFluid560IdentifierIsRejected() {
        XCTAssertThrowsError(
            try DictationEngine.selected(environment: ["DICTATE_ASR_BACKEND": "fluid-nemotron-560"])
        )
    }
}
