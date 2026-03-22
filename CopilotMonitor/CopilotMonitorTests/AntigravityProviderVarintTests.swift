import XCTest
@testable import CopilotMonitor

final class AntigravityProviderVarintTests: XCTestCase {
    private let provider = AntigravityProvider()

    func testReadVarintBoundaryValues() throws {
        try assertVarintRoundTrip(0)
        try assertVarintRoundTrip(1)
        try assertVarintRoundTrip(127)
        try assertVarintRoundTrip(128)
        try assertVarintRoundTrip(300)
    }

    func testReadVarintMaxUInt64() throws {
        let bytes: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]
        var index = 0
        let decoded = try provider.readVarint(from: bytes, index: &index)
        XCTAssertEqual(decoded, UInt64.max)
        XCTAssertEqual(index, bytes.count)
    }

    func testReadVarintThrowsOnTruncatedInput() {
        let bytes: [UInt8] = [0x80]
        var index = 0
        XCTAssertThrowsError(try provider.readVarint(from: bytes, index: &index))
    }

    func testParseProtobufMessageParsesVarintAndLengthDelimited() throws {
        let payload = Data([0x08, 0x96, 0x01, 0x12, 0x03, 0x61, 0x62, 0x63])
        let message = try provider.parseProtobufMessage(payload)

        guard let field1 = message[1]?.first else {
            XCTFail("Missing field 1")
            return
        }

        guard let field2 = message[2]?.first else {
            XCTFail("Missing field 2")
            return
        }

        switch field1 {
        case .varint(let value):
            XCTAssertEqual(value, 150)
        default:
            XCTFail("Expected varint for field 1")
        }

        switch field2 {
        case .lengthDelimited(let data):
            XCTAssertEqual(String(data: data, encoding: .utf8), "abc")
        default:
            XCTFail("Expected length-delimited for field 2")
        }
    }

    func testParseProtobufMessageThrowsOnUnsupportedWireType() {
        let payload = Data([0x0F])
        XCTAssertThrowsError(try provider.parseProtobufMessage(payload))
    }

    func testParseProtobufMessageThrowsOnMalformedLengthDelimitedField() {
        let payload = Data([0x12, 0x05, 0x61])
        XCTAssertThrowsError(try provider.parseProtobufMessage(payload))
    }

    private func assertVarintRoundTrip(_ expected: UInt64) throws {
        let encoded = encodeVarint(expected)
        var index = 0
        let decoded = try provider.readVarint(from: encoded, index: &index)
        XCTAssertEqual(decoded, expected)
        XCTAssertEqual(index, encoded.count)
    }

    private func encodeVarint(_ value: UInt64) -> [UInt8] {
        var remaining = value
        var bytes: [UInt8] = []

        repeat {
            var nextByte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 {
                nextByte |= 0x80
            }
            bytes.append(nextByte)
        } while remaining != 0

        return bytes
    }
}
