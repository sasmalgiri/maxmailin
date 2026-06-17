import XCTest
@testable import MaxMailCore

final class JMAPEventSourceTests: XCTestCase {

    // MARK: - URL building

    func testBuildEventSourceURLFillsTemplatedPlaceholders() {
        let raw = "https://api.example/events/{types}/{closeafter}/{ping}"
        let url = JMAPEventSource.buildEventSourceURL(rawTemplate: raw)
        XCTAssertEqual(url?.absoluteString,
                       "https://api.example/events/Email/no/30")
    }

    func testBuildEventSourceURLAppendsParamsWhenServerOmitsTemplate() {
        let raw = "https://api.example/events"
        let url = JMAPEventSource.buildEventSourceURL(rawTemplate: raw)
        XCTAssertEqual(url?.absoluteString,
                       "https://api.example/events?types=Email&closeafter=no&ping=30")
    }

    func testBuildEventSourceURLAppendsParamsWhenServerHasOtherQuery() {
        let raw = "https://api.example/events?foo=bar"
        let url = JMAPEventSource.buildEventSourceURL(rawTemplate: raw)
        XCTAssertEqual(url?.absoluteString,
                       "https://api.example/events?foo=bar&types=Email&closeafter=no&ping=30")
    }

    func testBuildEventSourceURLKeepsServerProvidedTypesParam() {
        // Server already pinned its own types — we don't second-guess it.
        let raw = "https://api.example/events?types=Mailbox,Email"
        let url = JMAPEventSource.buildEventSourceURL(rawTemplate: raw)
        XCTAssertEqual(url?.absoluteString,
                       "https://api.example/events?types=Mailbox,Email")
    }
}
