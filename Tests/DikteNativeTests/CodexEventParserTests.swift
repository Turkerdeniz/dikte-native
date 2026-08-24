import XCTest
@testable import DikteNative

final class CodexEventParserTests: XCTestCase {
    func testParsesThreadAndFinalMessage() {
        var parser = CodexEventParser()
        parser.consume(line: #"{"type":"thread.started","thread_id":"abc-123"}"#)
        parser.consume(line: #"{"type":"item.completed","item":{"type":"agent_message","text":"Sonuç"}}"#)
        XCTAssertEqual(parser.threadID, "abc-123")
        XCTAssertEqual(parser.messages, ["Sonuç"])
    }
}
