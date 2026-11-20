import XCTest
import Foundation
import Darwin

final class PairingUITests: XCTestCase {
    func request(port: UInt16, object: [String: Any]) throws -> [String: Any] {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "fixture.socket", code: 1) }
        defer { Darwin.close(fd) }
        var timeout = timeval(tv_sec: 12, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { throw NSError(domain: "fixture.connect", code: Int(errno)) }
        let data = try JSONSerialization.data(withJSONObject: object)
        var length = UInt32(data.count).bigEndian
        var message = Data(bytes: &length, count: 4); message.append(data)
        var offset = 0
        while offset < message.count {
            let sent = message.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: offset), message.count - offset, 0) }
            guard sent > 0 else { throw NSError(domain: "fixture.send", code: Int(errno)) }; offset += sent
        }
        func read(_ count: Int) throws -> Data {
            var data = Data(count: count), offset = 0
            while offset < count {
                let n = data.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress!.advanced(by: offset), count - offset, 0) }
                guard n > 0 else { throw NSError(domain: "fixture.receive", code: Int(errno)) }; offset += n
            }
            return data
        }
        let size = try read(4).reduce(0) { ($0 << 8) | Int($1) }
        guard size > 0, size <= 4096 else { throw NSError(domain: "fixture.frame", code: 1) }
        return try JSONSerialization.jsonObject(with: read(size)) as! [String: Any]
    }

    func testPairApproveStartPersistAndBackgroundStop() throws {
        let app = XCUIApplication()
        app.launch()
        let primary = app.buttons["primary-action"]
        XCTAssertTrue(primary.waitForExistence(timeout: 10))
        XCTAssertEqual(primary.label, "Pair with PC")
        primary.tap()
        XCTAssertTrue(app.staticTexts["Waiting for your PC"].waitForExistence(timeout: 5))
        let paired = expectation(description: "Keychain enrollment acknowledged")
        let token = String(repeating: "b", count: 64)
        DispatchQueue.global().async {
            do {
                let response = try self.request(port: 18764, object: ["op":"pair-native", "version":1, "name":"Simulator PC", "token":token])
                XCTAssertEqual(response["ok"] as? Bool, true)
                XCTAssertEqual(response["service"] as? String, "native-ios")
            } catch { XCTFail("Pair request: \(error)") }
            paired.fulfill()
        }
        XCTAssertTrue(app.alerts.buttons["Approve"].waitForExistence(timeout: 8))
        app.alerts.buttons["Approve"].tap()
        wait(for: [paired], timeout: 15)
        XCTAssertTrue(app.staticTexts["Paired with PC"].waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        XCTAssertTrue(primary.waitForExistence(timeout: 8))
        XCTAssertEqual(primary.label, "Start sharing", "Saved Keychain pairing survives relaunch")
        primary.tap()
        XCTAssertTrue(app.staticTexts["Ready for USB"].waitForExistence(timeout: 8))
        let ping = try request(port: 18766, object: ["op":"ping", "token":token])
        XCTAssertEqual(ping["ok"] as? Bool, true)
        XCTAssertTrue((ping["capabilities"] as? [String])?.contains("native-ios") == true)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertThrowsError(try request(port: 18766, object: ["op":"ping", "token":token]))
        app.activate()
        XCTAssertTrue(app.staticTexts["Paused while app was closed"].waitForExistence(timeout: 8))
        XCTAssertEqual(primary.label, "Start sharing")
    }
}
