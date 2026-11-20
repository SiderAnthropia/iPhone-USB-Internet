import Foundation
import Network
import Darwin

public struct RelayStats {
    public init() {}
    public var sessions = 0
    public var upload: UInt64 = 0
    public var download: UInt64 = 0
}

public final class RelayServer {
    let queue = DispatchQueue(label: "io.zuyis.usb-relay")
    let resolver = OperationQueue()
    let token: String
    let cellular: Bool
    let validator: (String) -> Bool
    let port: UInt16
    public let capacity = 128
    var listener: NWListener?
    var timer: DispatchSourceTimer?
    var sessions: [UUID: RelaySession] = [:]
    var stats = RelayStats()
    var pending = 0
    var active = 0
    var udpFlowCount = 0
    var running = false
    public var onState: ((String) -> Void)?
    public var onStats: ((RelayStats) -> Void)?
    public var onDiagnostic: ((String) -> Void)?

    public init(token: String, port: UInt16 = 18766, cellular: Bool = true,
                validator: @escaping (String) -> Bool = PublicInternet.allows) {
        self.token = token; self.port = port; self.cellular = cellular; self.validator = validator
        resolver.maxConcurrentOperationCount = 16
        resolver.name = "USB Relay DNS"
    }
    public func start() { queue.async { self.begin() } }
    public func stop() { queue.async { self.shutdown(); self.onState?("Stopped") } }
    private func begin() {
        guard listener == nil, Wire.validToken(token) else { onState?("Pair your PC first."); return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            let listener = try NWListener(using: parameters)
            self.listener = listener; running = true; stats = RelayStats()
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, self.running else { return }
                switch state {
                case .ready: self.onState?("Ready for USB")
                case .failed: self.shutdown(); self.onState?("Could not open USB port. Close iSH, then try Start again.")
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] c in
                guard let self, self.running, self.pending < 32,
                      self.sessions.count < self.capacity + 32 else { c.cancel(); return }
                let session = RelaySession(server: self, connection: c)
                self.sessions[session.id] = session; self.pending += 1
                session.start()
            }
            listener.start(queue: queue)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                for s in Array(self.sessions.values) where now > s.deadline { s.close() }
                self.stats.sessions = self.active
                self.onStats?(self.stats)
            }
            self.timer = timer; timer.resume()
        } catch { shutdown(); onState?("Could not start the USB listener.") }
    }
    private func shutdown() {
        running = false
        listener?.cancel(); listener = nil
        timer?.cancel(); timer = nil
        for s in Array(sessions.values) { s.close() }
        resolver.cancelAllOperations()
        stats.sessions = 0; onStats?(stats)
    }
    func parameters(udp: Bool) -> NWParameters {
        let p: NWParameters = udp ? .udp : .tcp
        if cellular { p.requiredInterfaceType = .cellular }
        return p
    }
    func resolve(host: String, port: UInt16, _ done: @escaping ([String]) -> Void) {
        guard !host.isEmpty, host.utf8.count <= 253,
              host.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,58].contains($0) }) else { done([]); return }
        if IPv4Address(host) != nil || IPv6Address(host) != nil { done(validator(host) ? [host] : []); return }
        guard resolver.operationCount < 32 else { done([]); return }
        resolver.addOperation { [weak self] in
            guard let self else { return }
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            var addresses: [String] = []
            if getaddrinfo(host, String(port), &hints, &result) == 0 {
                defer { freeaddrinfo(result) }
                var current = result
                while let entry = current {
                    var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen, &text, socklen_t(text.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let address = String(cString: text)
                        if self.validator(address), !addresses.contains(address) { addresses.append(address) }
                    }
                    current = entry.pointee.ai_next
                }
            }
            let resolved = Array(addresses.prefix(8))
            self.queue.async { done(resolved) }
        }
    }
}

final class RelaySession {
    let id = UUID()
    unowned let server: RelayServer
    let client: Channel
    var remote: Channel?
    var closed = false
    var established = false
    var udp = false
    var halfClosed = 0
    var deadline = ProcessInfo.processInfo.systemUptime + 15
    var flows: [String: UDPFlow] = [:]
    var queuedDatagrams: [Data] = []
    var sendingDatagram = false
    init(server: RelayServer, connection: NWConnection) { self.server = server; client = Channel(connection) }
    func start() {
        client.connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed(let error) = state {
                self.server.onDiagnostic?("Client failed: \(error)")
                // A terminal state may precede delivery of buffered receive data.
                // Established streams are drained by their receive callbacks.
                if !self.established { self.close() }
            }
        }
        client.connection.start(queue: server.queue)
        client.readFrame(limit: 4096) { [weak self] data in
            guard let self, !self.closed else { return }
            guard let data, let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let token = r["token"] as? String, Wire.equal(token, self.server.token) else { self.reject("Authentication failed"); return }
            if r["op"] as? String == "ping" {
                self.client.json(["ok":true, "version":3, "capabilities":["tcp","udp","async-relay","native-ios"],
                                  "max_sessions":self.server.capacity, "active":self.server.active]) { _ in self.close() }
                return
            }
            guard let op = r["op"] as? String, op == "tcp" || op == "udp" else { self.reject("Unknown operation"); return }
            guard self.server.active < self.server.capacity else { self.reject("Phone capacity reached", code: "capacity"); return }
            self.established = true; self.server.active += 1; self.server.pending -= 1
            if op == "udp" {
                self.udp = true; self.touch()
                self.client.json(["ok":true]) { ok in if ok { self.readDatagram() } else { self.close() } }
            } else {
                guard let host = r["host"] as? String, let port = Wire.integer(r["port"]), port > 0 else { self.reject("Invalid destination"); return }
                self.server.resolve(host: host, port: UInt16(port)) { addresses in
                    guard !self.closed else { return }
                    self.connect(addresses, port: UInt16(port))
                }
            }
        }
    }
    func reject(_ message: String, code: String = "request") {
        client.json(["ok":false,"error":message,"code":code]) { _ in self.close() }
    }
    func connect(_ addresses: [String], port: UInt16) {
        guard !closed else { return }
        guard let host = addresses.first else { reject("Phone could not reach a public internet destination. Check cellular data."); return }
        let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: server.parameters(udp: false))
        let channel = Channel(c); remote = channel
        var decided = false
        func failed() {
            guard !decided, !self.closed else { return }; decided = true
            channel.close(); self.connect(Array(addresses.dropFirst()), port: port)
        }
        c.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready:
                guard !decided else { return }; decided = true; self.touch()
                self.client.json(["ok":true]) { ok in
                    guard ok, !self.closed else { self.close(); return }
                    self.pump(self.client, channel, upload: true)
                    self.pump(channel, self.client, upload: false)
                }
            case .failed(let error):
                self.server.onDiagnostic?("Remote failed: \(error)")
                if !decided { failed() }
            default: break
            }
        }
        c.start(queue: server.queue)
        server.queue.asyncAfter(deadline: .now() + 3) { failed() }
    }
    func touch() { deadline = ProcessInfo.processInfo.systemUptime + (udp ? 90 : halfClosed > 0 ? 30 : 900) }
    func pump(_ source: Channel, _ destination: Channel, upload: Bool) {
        guard !closed else { return }
        source.connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            let bytes = data ?? Data()
            let finished = complete || error != nil
            destination.send(bytes, final: finished) { ok in
                guard ok, !self.closed else { self.server.onDiagnostic?("Write failed upload=\(upload), final=\(complete), size=\(bytes.count)"); self.close(); return }
                if upload { self.server.stats.upload += UInt64(bytes.count) } else { self.server.stats.download += UInt64(bytes.count) }
                if finished { self.halfClosed += 1; self.server.onDiagnostic?("EOF upload=\(upload) sent=\(self.server.stats.upload) received=\(self.server.stats.download)") }
                self.touch()
                if self.halfClosed == 2 { self.close() }
                else if !finished { self.pump(source, destination, upload: upload) }
            }
        }
    }
    func readDatagram() {
        guard !closed else { return }
        client.readFrame { [weak self] data in
            guard let self, !self.closed else { return }
            guard let data, let (host, port, payload) = try? Wire.datagram(data) else { self.close(); return }
            self.touch()
            let now = ProcessInfo.processInfo.systemUptime
            for (key, flow) in Array(self.flows) where now - flow.last > 60 { self.removeFlow(key, flow) }
            let key = "\(host):\(port)"
            if let flow = self.flows[key] { self.sendDatagram(flow, payload); return }
            guard self.flows.count < 16, self.server.udpFlowCount < 128 else { self.readDatagram(); return }
            self.server.resolve(host: host, port: port) { addresses in
                guard !self.closed else { return }
                guard let address = addresses.first, self.server.udpFlowCount < 128 else { self.readDatagram(); return }
                let c = NWConnection(host: NWEndpoint.Host(address), port: NWEndpoint.Port(rawValue: port)!, using: self.server.parameters(udp: true))
                let flow = UDPFlow(connection: c, host: address, port: port)
                self.flows[key] = flow
                self.server.udpFlowCount += 1
                var started = false
                c.stateUpdateHandler = { [weak self, weak flow] state in
                    guard let self, let flow, !self.closed else { return }
                    switch state {
                    case .ready:
                        guard !started else { return }; started = true
                        self.receiveDatagram(flow); self.sendDatagram(flow, payload)
                    case .failed:
                        self.removeFlow(key, flow)
                        if !started { started = true; self.readDatagram() }
                    default: break
                    }
                }
                c.start(queue: self.server.queue)
                self.server.queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                    guard let self, !started, !self.closed else { return }; started = true
                    self.removeFlow(key, flow); self.readDatagram()
                }
            }
        }
    }
    func sendDatagram(_ flow: UDPFlow, _ data: Data) {
        flow.last = ProcessInfo.processInfo.systemUptime
        flow.connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, !self.closed else { return }
            if error == nil { self.server.stats.upload += UInt64(data.count) }
            self.readDatagram()
        })
    }
    func receiveDatagram(_ flow: UDPFlow) {
        flow.connection.receiveMessage { [weak self, weak flow] data, _, _, error in
            guard let self, let flow, !self.closed, error == nil else { return }
            if let data, let frame = try? Wire.datagramReply(host: flow.host, port: flow.port, data: data),
               self.queuedDatagrams.count < 8 {
                self.queuedDatagrams.append(frame); self.flushDatagrams()
                self.server.stats.download += UInt64(data.count); self.touch()
            }
            self.receiveDatagram(flow)
        }
    }
    func flushDatagrams() {
        guard !closed, !sendingDatagram, !queuedDatagrams.isEmpty else { return }
        sendingDatagram = true
        client.send(Wire.frame(queuedDatagrams.removeFirst())) { [weak self] ok in
            guard let self else { return }; self.sendingDatagram = false
            if ok { self.flushDatagrams() } else { self.close() }
        }
    }
    func close() {
        guard !closed else { return }; closed = true
        client.close(); remote?.close()
        for (key, flow) in Array(flows) { removeFlow(key, flow) }
        flows.removeAll(); queuedDatagrams.removeAll()
        if established { server.active -= 1 } else { server.pending -= 1 }
        server.sessions.removeValue(forKey: id)
    }
    func removeFlow(_ key: String, _ flow: UDPFlow) {
        flow.connection.stateUpdateHandler = nil; flow.connection.cancel()
        if flows[key] === flow { flows.removeValue(forKey: key); server.udpFlowCount -= 1 }
    }
}

final class UDPFlow {
    let connection: NWConnection
    let host: String
    let port: UInt16
    var last = ProcessInfo.processInfo.systemUptime
    init(connection: NWConnection, host: String, port: UInt16) { self.connection = connection; self.host = host; self.port = port }
}
