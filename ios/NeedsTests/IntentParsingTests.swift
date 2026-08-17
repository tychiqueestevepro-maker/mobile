import XCTest
@testable import Needs

final class IntentParsingTests: XCTestCase {
    func testNeedIntentDecodesServerWireFormat() throws {
        let json = #"""
        {
          "id": "30000000-0000-0000-0000-000000000001",
          "category": "trash_bags",
          "normalized_query": "large durable black trash bags",
          "attributes": {"size":"large","color":"black","durability":"high"},
          "quantity": 1,
          "confidence": 0.95,
          "clarification": null
        }
        """#.data(using: .utf8)!

        let intent = try NeedsJSON.decoder().decode(NeedIntent.self, from: json)
        XCTAssertEqual(intent.category, "trash_bags")
        XCTAssertEqual(intent.normalizedQuery, "large durable black trash bags")
        XCTAssertEqual(intent.attributes["durability"], "high")
        XCTAssertEqual(intent.quantity, 1)
        XCTAssertEqual(intent.confidence, 0.95, accuracy: 0.001)
    }

    func testDeterministicParserExtractsCurrentIntent() async throws {
        let parser = DeterministicIntentParsingService()
        let intent = try await parser.parse("I need big black trash bags that won't rip")

        XCTAssertEqual(intent.category, "trash_bags")
        XCTAssertEqual(intent.attributes["size"], "large")
        XCTAssertEqual(intent.attributes["color"], "black")
        XCTAssertEqual(intent.attributes["durability"], "high")
        XCTAssertNil(intent.clarification)
    }

    func testAmbiguousBatteryRequestAsksOneQuickQuestion() async throws {
        let parser = DeterministicIntentParsingService()
        let intent = try await parser.parse("Get me batteries")

        XCTAssertEqual(intent.category, "batteries")
        XCTAssertEqual(intent.clarification?.prompt, "Which size?")
        XCTAssertEqual(intent.clarification?.options, ["AA", "AAA", "Other"])
    }
}
