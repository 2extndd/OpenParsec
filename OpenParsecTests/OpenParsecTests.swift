import XCTest
@testable import OpenParsec

final class OpenParsecTests: XCTestCase {
    func testApplicationViewStatesRemainStable() {
        let states: [ViewType] = [.login, .main, .parsec, .test]

        XCTAssertEqual(states.map { String(describing: $0) }, ["login", "main", "parsec", "test"])
    }
}
