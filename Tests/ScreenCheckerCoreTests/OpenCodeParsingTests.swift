import XCTest
@testable import ScreenCheckerCore

final class OpenCodeParsingTests: XCTestCase {
    // Raw strings keep the JSON-escaped quotes literal, like the real output.
    let ndjsonOutput = #"""
        {"type":"step_start","timestamp":1791545515950,"sessionID":"ses_redacted","part":{"id":"prt_1","type":"step-start"}}
        {"type":"text","timestamp":1791545528066,"sessionID":"ses_redacted","part":{"id":"prt_2","type":"text","text":"Maximum steps reached. Classification result:\n\n{\"is_distraction\": true, \"confidence\": 0.95, \"category\": \"shorts\", \"reason\": \"URL youtube.com/shorts and the Shorts feed in the screenshot are a distraction by policy.\"}\n\nDone."}}
        """#

    func testTextExtractionFromJSONEvents() {
        let text = OpenCodeOutputParser.text(fromJSONEvents: ndjsonOutput)
        XCTAssertTrue(text.contains("is_distraction"))
        XCTAssertTrue(text.contains("shorts"))
        XCTAssertFalse(text.contains("step_start"))
    }

    func testVerdictFromRealisticEventStream() {
        let text = OpenCodeOutputParser.text(fromJSONEvents: ndjsonOutput)
        let verdict = OpenCodeOutputParser.extractVerdict(from: text)
        XCTAssertEqual(verdict?.isDistraction, true)
        XCTAssertEqual(verdict?.confidence, 0.95)
        XCTAssertEqual(verdict?.category, "shorts")
        XCTAssertEqual(verdict?.reason?.contains("distraction"), true)
    }

    func testVerdictFromFencedJSON() {
        let text = """
        Sure, here is the classification:

        ```json
        {"is_distraction": true, "confidence": 0.9, "category": "social", "reason": "feed scrolling"}
        ```

        Let me know if you need anything else.
        """
        let verdict = OpenCodeOutputParser.extractVerdict(from: text)
        XCTAssertEqual(verdict?.isDistraction, true)
        XCTAssertEqual(verdict?.confidence, 0.9)
        XCTAssertEqual(verdict?.category, "social")
    }

    func testVerdictFromBareJSON() {
        let text = #"{"is_distraction": false, "confidence": 0.88, "category": "none", "reason": "Python docs"}"#
        let verdict = OpenCodeOutputParser.extractVerdict(from: text)
        XCTAssertEqual(verdict?.isDistraction, false)
        XCTAssertEqual(verdict?.confidence, 0.88)
    }

    func testVerdictWithStringValuedFields() {
        let text = #"{"is_distraction": "true", "confidence": "0.85", "category": "streaming"}"#
        let verdict = OpenCodeOutputParser.extractVerdict(from: text)
        XCTAssertEqual(verdict?.isDistraction, true)
        XCTAssertEqual(verdict?.confidence, 0.85)
    }

    func testNestedVerdictObject() {
        let text = #"prefix {"outer": {"is_distraction": true, "confidence": 0.7, "category": "other"}} suffix"#
        let verdict = OpenCodeOutputParser.extractVerdict(from: text)
        XCTAssertEqual(verdict?.isDistraction, true)
        XCTAssertEqual(verdict?.confidence, 0.7)
    }

    func testUnparseableOutputReturnsNil() {
        XCTAssertNil(OpenCodeOutputParser.extractVerdict(from: "model had a bad day"))
        XCTAssertNil(OpenCodeOutputParser.extractVerdict(from: ""))
        XCTAssertNil(OpenCodeOutputParser.extractVerdict(from: #"{"is_distraction": "maybe"}"#))
    }

    func testEventStreamWithoutTextParts() {
        let output = #"{"type":"step_start","part":{"type":"step-start"}}"#
        let text = OpenCodeOutputParser.text(fromJSONEvents: output)
        XCTAssertEqual(text, "")
        XCTAssertNil(OpenCodeOutputParser.extractVerdict(from: text))
    }

    func testJSONObjectsScannerHandlesStringsAndEscapes() {
        let text = #"noise {"a": "brace } inside string", "b": 1} tail {"c": 2}"#
        let objects = OpenCodeOutputParser.jsonObjects(in: text)
        XCTAssertEqual(objects.count, 2)
        XCTAssertEqual(objects[0], #"{"a": "brace } inside string", "b": 1}"#)
    }

    // MARK: URL normalization (verdict cache keys)

    func testYouTubeWatchURLKeepsVideoID() {
        let key = Monitor.normalizeURL("https://www.youtube.com/watch?v=ABC123&list=xyz")
        XCTAssertTrue(key.hasSuffix("/watch?v=abc123"))
    }

    func testOtherURLsCollapseToHostAndPath() {
        let key = Monitor.normalizeURL("https://www.example.com/articles/2026/10/09/some-long-title?page=3")
        XCTAssertEqual(key, "www.example.com/articles/2026/10/09/some-long-title")
    }
}
