import Foundation
import USBRelayCore

let args = CommandLine.arguments
let token = String(repeating: "a", count: 64)
let allowLoopback = args.contains("--allow-loopback")
let relay = RelayServer(token: token, cellular: false,
                        validator: { PublicInternet.allows($0) || (allowLoopback && $0 == "127.0.0.1") })
relay.onState = { state in print(state); fflush(stdout) }
relay.start()
let pairing = PairingServer()
pairing.onRequest = { request in
    guard let request else { return }
    pairing.respond(id: request.id, allow: request.name != "Reject", persist: { Wire.validToken($0) })
}
pairing.start()
dispatchMain()
