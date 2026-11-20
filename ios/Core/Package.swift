// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "USBRelayCore",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "USBRelayCore", targets: ["USBRelayCore"]),
               .executable(name: "RelayHarness", targets: ["RelayHarness"])],
    targets: [.target(name: "USBRelayCore"),
              .executableTarget(name: "RelayHarness", dependencies: ["USBRelayCore"]),
              .testTarget(name: "USBRelayCoreTests", dependencies: ["USBRelayCore"])])
