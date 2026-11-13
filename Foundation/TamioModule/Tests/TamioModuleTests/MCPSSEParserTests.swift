//
//  MCPSSEParserTests.swift
//  TamioModuleTests
//

@testable import TamioModule
import XCTest

final class MCPSSEParserTests: XCTestCase {
    func testMultiLineDataAndEvent() {
        var parser = MCPSSEParser()
        XCTAssertNil(parser.consume(line: "event: message"))
        XCTAssertNil(parser.consume(line: #"data: {"a":1}"#))
        XCTAssertNil(parser.consume(line: "data: second"))
        let event = parser.consume(line: "")
        XCTAssertEqual(event?.event, "message")
        XCTAssertEqual(event?.data, #"{"a":1}"# + "\nsecond")
    }

    func testCommentsAndCRLF() {
        var parser = MCPSSEParser()
        XCTAssertNil(parser.consume(line: ": keep-alive"))
        XCTAssertNil(parser.consume(line: "data: one\r"))
        XCTAssertEqual(parser.consume(line: "\r")?.data, "one")
    }

    func testBlankLineWithoutDataDispatchesNothing() {
        var parser = MCPSSEParser()
        XCTAssertNil(parser.consume(line: ""))
        XCTAssertNil(parser.consume(line: "event: endpoint"))
        XCTAssertNil(parser.consume(line: ""))
    }
}
