import XCTest
import Network
@testable import USBRelayCore

final class WireTests: XCTestCase {
    func testPublicDestinations() {
        for address in ["1.1.1.1", "8.8.8.8", "2606:4700:4700::1111"] { XCTAssertTrue(PublicInternet.allows(address), address) }
        for address in ["localhost", "0.0.0.0", "10.1.2.3", "127.0.0.1", "100.64.1.2", "169.254.1.1", "172.31.1.1", "192.168.1.1", "192.0.2.1", "198.18.1.1", "198.51.100.1", "203.0.113.1", "224.0.0.1", "255.255.255.255", "::", "::1", "::ffff:1.1.1.1", "fc00::1", "fe80::1", "ff02::1", "2001:db8::1", "2002:0808:0808::1", "2001::1", "64:ff9b::7f00:1"] { XCTAssertFalse(PublicInternet.allows(address), address) }
    }
    func testFramingAndAuthentication() {
        XCTAssertEqual(Wire.frame(Data([1,2,3])), Data([0,0,0,3,1,2,3]))
        XCTAssertTrue(Wire.validToken(String(repeating: "a", count: 64)))
        XCTAssertFalse(Wire.validToken(String(repeating: "g", count: 64)))
        XCTAssertFalse(Wire.validToken(String(repeating: "a", count: 63)))
        XCTAssertTrue(Wire.equal("abcdef", "abcdef")); XCTAssertFalse(Wire.equal("abcdef", "abcdeg"))
        XCTAssertNil(Wire.integer(true)); XCTAssertNil(Wire.integer(1.5)); XCTAssertNil(Wire.integer(-1)); XCTAssertNil(Wire.integer(65536))
        XCTAssertEqual(Wire.integer(443), 443)
        XCTAssertEqual(Wire.pairingCode(String(repeating: "a", count: 64)), "891902")
    }
    func testDatagrams() throws {
        for address in ["1.1.1.1", "2606:4700:4700::1111"] {
            let bytes = try Wire.datagramReply(host: address, port: 53, data: Data([4,5,6]))
            let (host, port, payload) = try Wire.datagram(bytes)
            XCTAssertEqual(port, 53); XCTAssertEqual(payload, Data([4,5,6]))
            XCTAssertTrue(PublicInternet.allows(host))
        }
        let domain = Data([0,0,0,3,3,97,98,99,0,53,7])
        XCTAssertEqual(try Wire.datagram(domain).0, "abc")
        for data in [Data(), Data([0,0,1,1,1,1,1,1,0,53]), Data([0,0,0,3,255,1]), Data([0,0,0,8]), Data([0,0,0,1,1,1,1,1,0,0])] { XCTAssertThrowsError(try Wire.datagram(data)) }
    }
}
