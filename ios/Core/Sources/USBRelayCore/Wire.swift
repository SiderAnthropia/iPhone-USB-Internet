import Foundation
import Network
import Darwin
import CryptoKit
import CoreFoundation

public enum RelayError: Error { case invalid, denied, closed, capacity }

public enum Wire {
    public static let maximum = 65536
    public static func frame(_ data: Data) -> Data {
        var n = UInt32(data.count).bigEndian
        var result = Data(bytes: &n, count: 4)
        result.append(data)
        return result
    }
    public static func integer(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite, n.doubleValue == Double(n.int64Value),
              n.int64Value >= 0, n.int64Value <= 65535 else { return nil }
        return n.intValue
    }
    public static func validToken(_ token: String) -> Bool {
        token.utf8.count == 64 && token.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    public static func equal(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    public static func pairingCode(_ token: String) -> String {
        let hash = SHA256.hash(data: Data(token.utf8))
        let n = hash.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return String(format: "%06u", n % 1_000_000)
    }
    public static func datagram(_ data: Data) throws -> (String, UInt16, Data) {
        let b = Array(data)
        guard b.count >= 4, b[0...2].allSatisfy({ $0 == 0 }) else { throw RelayError.invalid }
        var i = 4
        let host: String
        switch b[3] {
        case 1:
            guard b.count >= 10 else { throw RelayError.invalid }
            host = b[4..<8].map(String.init).joined(separator: "."); i = 8
        case 4:
            guard b.count >= 22 else { throw RelayError.invalid }
            host = stride(from: 4, to: 20, by: 2).map { String(UInt16(b[$0]) << 8 | UInt16(b[$0+1]), radix: 16) }.joined(separator: ":"); i = 20
        case 3:
            guard b.count >= 5, b[4] > 0, b.count >= 7 + Int(b[4]) else { throw RelayError.invalid }
            i = 5 + Int(b[4])
            guard let s = String(bytes: b[5..<i], encoding: .ascii) else { throw RelayError.invalid }
            host = s
        default: throw RelayError.invalid
        }
        let port = UInt16(b[i]) << 8 | UInt16(b[i+1])
        guard port > 0 else { throw RelayError.invalid }
        return (host, port, Data(b[(i+2)...]))
    }
    public static func datagramReply(host: String, port: UInt16, data: Data) throws -> Data {
        var result = Data([0, 0, 0])
        if let a = IPv4Address(host) { result.append(1); result.append(a.rawValue) }
        else if let a = IPv6Address(host) { result.append(4); result.append(a.rawValue) }
        else { throw RelayError.invalid }
        result.append(UInt8(port >> 8)); result.append(UInt8(port & 255)); result.append(data)
        guard result.count <= maximum else { throw RelayError.invalid }
        return result
    }
}

public enum PublicInternet {
    public static func allows(_ host: String) -> Bool {
        if let a = IPv4Address(host) {
            let b = Array(a.rawValue)
            if b[0] == 0 || b[0] == 10 || b[0] == 127 || b[0] >= 224 { return false }
            if b[0] == 100 && (64...127).contains(b[1]) { return false }
            if b[0] == 169 && b[1] == 254 || b[0] == 172 && (16...31).contains(b[1]) { return false }
            if b[0] == 192 && (b[1] == 168 || b[1] == 0 || b[1] == 2) { return false }
            if b[0] == 198 && (b[1] == 18 || b[1] == 19 || b[1] == 51 && b[2] == 100) { return false }
            if b[0] == 203 && b[1] == 0 && b[2] == 113 { return false }
            return true
        }
        if let a = IPv6Address(host) {
            let b = Array(a.rawValue)
            // Only global unicast; exclude Teredo, 6to4, documentation, benchmarking and ORCHID.
            guard b[0] & 0xe0 == 0x20 else { return false }
            if b[0] == 0x20 && b[1] == 0x02 { return false }
            if b[0] == 0x20 && b[1] == 0x01 {
                if b[2] == 0 && b[3] < 0x20 { return false }
                if b[2] == 0x0d && b[3] == 0xb8 { return false }
                if b[2] == 0 && b[3] & 0xf0 == 0x20 { return false }
            }
            if b[0] == 0x3f && b[1] == 0xff && b[2] < 0x10 { return false }
            return true
        }
        return false
    }
}

final class Channel {
    let connection: NWConnection
    var ended = false
    init(_ c: NWConnection) { connection = c }
    func exact(_ count: Int, _ done: @escaping (Data?) -> Void) {
        guard !ended else { done(nil); return }
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
            guard error == nil, let data, data.count == count else { done(nil); return }
            done(data)
        }
    }
    func readFrame(limit: Int = Wire.maximum, _ done: @escaping (Data?) -> Void) {
        exact(4) { [weak self] data in
            guard let self, let data else { done(nil); return }
            let n = data.reduce(0) { ($0 << 8) | Int($1) }
            guard n > 0 && n <= limit else { done(nil); return }
            self.exact(n, done)
        }
    }
    func send(_ data: Data, final: Bool = false, _ done: @escaping (Bool) -> Void) {
        guard !ended else { done(false); return }
        connection.send(content: final && data.isEmpty ? nil : data, contentContext: final ? .finalMessage : .defaultMessage,
                        isComplete: true, completion: .contentProcessed { done($0 == nil) })
    }
    func json(_ value: [String: Any], _ done: @escaping (Bool) -> Void) {
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { done(false); return }
        send(Wire.frame(data), done)
    }
    func close() { ended = true; connection.stateUpdateHandler = nil; connection.cancel() }
}
