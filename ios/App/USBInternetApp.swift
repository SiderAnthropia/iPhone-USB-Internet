import SwiftUI
import Security
import USBRelayCore

enum PairingKey {
    static let service = "io.zuyis.iphone-usb-internet.pairing"
    static var lastError: OSStatus?
    static func read() -> String? {
        let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword,
            kSecAttrService as String:service, kSecAttrAccount as String:"pc",
            kSecReturnData as String:true, kSecMatchLimit as String:kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let token = String(data: data, encoding: .utf8), Wire.validToken(token) else { return nil }
        return token
    }
    static func save(_ token: String) -> Bool {
        lastError = nil
        guard Wire.validToken(token) else { return false }
        let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword,
            kSecAttrService as String:service, kSecAttrAccount as String:"pc"]
        let attributes: [String: Any] = [kSecValueData as String:Data(token.utf8),
            kSecAttrAccessible as String:kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        let result = status == errSecItemNotFound ? SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) : status
        if result != errSecSuccess { lastError = result }
        return result == errSecSuccess
    }
}

final class RelayModel: ObservableObject {
    @Published var paired = PairingKey.read() != nil
    @Published var running = false
    @Published var pairing = false
    @Published var request: PairingRequest?
    @Published var status = PairingKey.read() == nil ? "Pair your PC" : "Ready when you are"
    @Published var detail = PairingKey.read() == nil ? "Connect your iPhone to Windows with a USB data cable, then pair below." : "Connect your iPhone to Windows with a USB data cable."
    @Published var stats = RelayStats()
    @Published var keepAwake = true { didSet { updateAwake() } }
    private var relay: RelayServer?
    private var pairServer: PairingServer?
    private var generation = UUID()

    func start() {
        guard !running, !pairing, let token = PairingKey.read() else { return }
        let relay = RelayServer(token: token)
        self.relay = relay; running = true; stats = RelayStats()
        generation = UUID(); let current = generation
        status = "Starting…"; detail = "Opening the USB connection."
        relay.onState = { [weak self] state in
            DispatchQueue.main.async {
                guard let self, current == self.generation else { return }
                self.status = state
                if state == "Ready for USB" {
                    self.detail = "On Windows, choose Check phone, then Connect PC. Keep this app open."
                } else if state != "Stopped" {
                    self.running = false; self.relay = nil; self.detail = "Check cellular data and close any old iSH relay, then try again."
                    self.updateAwake()
                }
            }
        }
        relay.onStats = { [weak self] stats in
            DispatchQueue.main.async { guard let self, current == self.generation else { return }; self.stats = stats }
        }
        updateAwake(); relay.start()
    }
    func stop(background: Bool = false) {
        generation = UUID(); relay?.stop(); relay = nil
        pairServer?.stop(); pairServer = nil; request = nil
        running = false; pairing = false; stats.sessions = 0
        status = background ? "Paused while app was closed" : "Stopped"
        detail = background ? "Keep this app visible during sharing. Tap Start, then reconnect in Windows." : "Your phone is ready for another connection."
        updateAwake()
    }
    func beginPairing() {
        guard !running, !pairing else { return }
        let server = PairingServer(); pairServer = server
        pairing = true; status = "Waiting for your PC"
        detail = "In Windows, choose Pair native iPhone app. You have two minutes."
        server.onRequest = { [weak self] request in self?.request = request }
        server.onFinished = { [weak self] success, message in
            guard let self else { return }
            self.pairing = false; self.paired = PairingKey.read() != nil
            self.status = success ? "Paired with PC" : "Pairing ended"
            self.detail = !success && PairingKey.lastError != nil ? "The app could not save pairing in Keychain (\(PairingKey.lastError!)). Re-sign it in Sideloadly, then pair again." : message
            self.pairServer = nil; self.updateAwake()
        }
        updateAwake(); server.start()
    }
    func approve(_ allow: Bool, id: UUID) {
        pairServer?.respond(id: id, allow: allow, persist: PairingKey.save)
    }
    func updateAwake() { UIApplication.shared.isIdleTimerDisabled = keepAwake && (running || pairing) }
    static func bytes(_ count: UInt64) -> String {
        count == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: Int64(min(count, UInt64(Int64.max))), countStyle: .decimal)
    }
}

@main struct USBInternetApp: App {
    @StateObject private var model = RelayModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onChange(of: phase) { phase in
                    if phase == .background { model.stop(background: true) }
                }
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: RelayModel
    let accent = Color(red: 0.30, green: 0.85, blue: 0.72)
    var body: some View {
        ZStack {
            Color(red: 0.045, green: 0.065, blue: 0.09).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        Image(systemName: "cable.connector").font(.title).foregroundStyle(accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("iPhone USB Internet").font(.headline)
                            Text("Made by Zuyis").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }.padding(.top, 16)
                    VStack(alignment: .leading, spacing: 16) {
                        Label(model.running ? "USB SHARING" : model.pairing ? "PAIRING" : "PHONE COMPANION", systemImage: "circle.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(accent)
                        Text(model.status).font(.largeTitle.bold())
                        Text(model.detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button {
                            if model.running || model.pairing { model.stop() }
                            else if model.paired { model.start() }
                            else { model.beginPairing() }
                        } label: {
                            Label(model.running ? "Stop sharing" : model.pairing ? "Cancel pairing" : model.paired ? "Start sharing" : "Pair with PC", systemImage: model.running || model.pairing ? "stop.fill" : model.paired ? "power" : "link")
                                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 10)
                        }.buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black)
                            .accessibilityIdentifier("primary-action")
                    }.padding(22).background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 24))
                    HStack(spacing: 12) {
                        metric("Downloaded", RelayModel.bytes(model.stats.download), "arrow.down")
                        metric("Uploaded", RelayModel.bytes(model.stats.upload), "arrow.up")
                    }
                    HStack { Text("Active sessions"); Spacer(); Text("\(model.stats.sessions)").monospacedDigit().foregroundStyle(accent) }.font(.subheadline)
                    VStack(alignment: .leading, spacing: 15) {
                        Text("Connect in three steps").font(.headline)
                        step("1", "Plug in your iPhone", "Unlock it and trust the computer if asked.")
                        step("2", "Use cellular data", "Turn cellular on. Keep Wi-Fi and Personal Hotspot off.")
                        step("3", "Start, then connect", "Keep this app visible. Check phone and Connect PC in Windows.")
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        HStack { Text("PC pairing").font(.headline); Spacer(); Text(model.paired ? "Saved" : "Needed").font(.caption).foregroundStyle(accent) }
                        Text(model.paired ? "Pair again to move an existing Windows pairing into this app. Approving a different PC replaces the phone’s saved pairing." : "Open the Windows app, then pair here. Compare the code on both screens before approving.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Pair with PC") { model.beginPairing() }.buttonStyle(.bordered).tint(accent).disabled(model.running || model.pairing)
                        Toggle("Keep screen awake while sharing", isOn: $model.keepAwake).font(.subheadline).tint(accent)
                    }.padding(20).background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 20))
                    Text("Sharing pauses when you lock the phone or leave the app. Install updates through Sideloadly using the same account and bundle settings to retain pairing.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("2.0.0 • Preview • Cellular over USB").font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }.padding(22)
            }
        }.preferredColorScheme(.dark)
        .alert(item: $model.request) { request in
            Alert(title: Text("Pair with \(request.name)?"),
                  message: Text("Compare this code with Windows:\n\n\(request.code)\n\nApprove only if both screens match."),
                  primaryButton: .default(Text("Approve"), action: { model.approve(true, id: request.id) }),
                  secondaryButton: .cancel(Text("Reject"), action: { model.approve(false, id: request.id) }))
        }
    }
    func metric(_ title: String, _ value: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).minimumScaleFactor(0.7).lineLimit(1).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(17).background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18))
    }
    func step(_ number: String, _ title: String, _ subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number).font(.caption.bold()).foregroundStyle(accent).frame(width: 26, height: 26).background(accent.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 4) { Text(title).font(.subheadline.weight(.medium)); Text(subtitle).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
