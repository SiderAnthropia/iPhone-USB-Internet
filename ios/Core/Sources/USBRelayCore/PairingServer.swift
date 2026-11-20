import Foundation
import Network

public struct PairingRequest: Identifiable {
    public let id: UUID
    public let name: String
    public let code: String
}

// This listener exists only during an explicit, time-limited pairing window.
// The application must approve the code and persist the key before acknowledging.
public final class PairingServer {
    public var onRequest: ((PairingRequest?) -> Void)?
    public var onFinished: ((Bool, String) -> Void)?
    var listener: NWListener?
    var pending: (UUID, String, Channel)?
    var channels: [UUID: Channel] = [:]
    var timer: DispatchWorkItem?
    public init() {}
    public func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        stop()
        do {
            let p = NWParameters.tcp
            p.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 18764)
            let listener = try NWListener(using: p)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.finish(false, "Pairing port unavailable. Close iSH and try again.") }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, self.pending == nil, self.channels.count < 4 else { connection.cancel(); return }
                let channel = Channel(connection), id = UUID()
                self.channels[id] = channel
                connection.start(queue: .main)
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self, weak channel] in
                    guard let self, self.pending?.0 != id else { return }
                    channel?.close(); self.channels.removeValue(forKey: id)
                }
                channel.readFrame(limit: 4096) { [weak self] data in
                    guard let self, self.listener != nil, self.channels[id] != nil else { return }
                    guard self.pending == nil, let data,
                          let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                          r["op"] as? String == "pair-native", Wire.integer(r["version"]) == 1,
                          let token = r["token"] as? String, Wire.validToken(token),
                          let name = r["name"] as? String, !name.isEmpty, name.utf8.count <= 80,
                          name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || " -_.".unicodeScalars.contains($0) }) else {
                        channel.close(); self.channels.removeValue(forKey: id); return
                    }
                    self.pending = (id, token, channel)
                    self.onRequest?(PairingRequest(id: id, name: name, code: Wire.pairingCode(token)))
                }
            }
            listener.start(queue: .main)
            let timer = DispatchWorkItem { [weak self] in self?.finish(false, "Pairing timed out. Tap Pair with PC to try again.") }
            self.timer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: timer)
        } catch { finish(false, "Could not open pairing. Close iSH and try again.") }
    }
    public func respond(id: UUID, allow: Bool, persist: (String) -> Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let (current, token, channel) = pending, current == id, listener != nil else { return }
        pending = nil; onRequest?(nil)
        let saved = allow && persist(token)
        channel.json(["ok":saved,"service":"native-ios","version":1,
                      "code":Wire.pairingCode(token), "error": saved ? "" : "Phone did not approve or save pairing."]) { [weak self] delivered in
            self?.finish(saved, saved ? (delivered ? "PC paired. Tap Start to share over USB." : "Pairing saved. Check the Windows result before starting.") : "Pairing was not saved.")
        }
    }
    public func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        timer?.cancel(); timer = nil
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        for channel in channels.values { channel.close() }
        channels.removeAll(); pending = nil; onRequest?(nil)
    }
    func finish(_ success: Bool, _ message: String) { stop(); onFinished?(success, message) }
}
