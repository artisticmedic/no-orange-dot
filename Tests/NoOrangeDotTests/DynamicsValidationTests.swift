import XCTest
@testable import NoOrangeDot

final class DynamicsValidationTests: XCTestCase {
    func testDefaultsAndEverySupportedBoundaryAreAccepted() throws {
        try Dynamics().validate()
        for (_, key, range) in Dynamics.limits {
            for value in [range.lowerBound, range.upperBound] {
                var dynamics = Dynamics()
                dynamics[keyPath: key] = value
                try dynamics.validate()
                XCTAssertEqual(try JSONDecoder().decode(Dynamics.self, from: JSONEncoder().encode(dynamics)), dynamics)
            }
        }
    }

    func testNonfiniteAndOutOfRangeValuesAreRejected() throws {
        for (_, key, range) in Dynamics.limits {
            for value in [Double.nan, .infinity, -.infinity, range.lowerBound - 1, range.upperBound + 1] {
                var dynamics = Dynamics()
                dynamics[keyPath: key] = value
                XCTAssertThrowsError(try dynamics.validate())
            }
        }
        XCTAssertThrowsError(try JSONDecoder().decode(Dynamics.self, from: Data(#"{"gateHoldMs":1e308}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(Dynamics.self, from: Data(#"{"compMakeupDB":1e308}"#.utf8)))
    }
}
