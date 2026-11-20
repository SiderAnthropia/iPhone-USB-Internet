# iPhone USB Internet 2.0.0 preview

A Windows app and native iPhone companion for carrying PC internet traffic through the phone's cellular connection over USB. Made by **Zuyis**.

The native app replaces iSH and Python for daily use. Install its IPA through Sideloadly, pair over USB, then **Start sharing → Check phone → Connect PC**.

## Install

See [INSTALL.md](INSTALL.md). Requires Windows 10/11 x64, WebView2, Apple device support, iOS 16+, Sideloadly and a USB data cable.

1. Install the Windows setup EXE and sign/install the unsigned IPA through Sideloadly.
2. Close iSH. In **USB Internet** on the phone, tap **Pair with PC**.
3. In Windows **Setup & maintenance**, choose **Pair native iPhone app**. Compare the six-digit code and approve on the phone.
4. Keep cellular on, Wi-Fi and Personal Hotspot off. Tap **Start sharing** on the phone.
5. Choose **Check phone**, then **Connect PC** in Windows and approve its administrator prompt.

## Behavior

The native relay provides authenticated TCP/UDP through a loopback-only USB endpoint. It uses Apple's Network framework, requests cellular for outgoing connections, and permits public internet destinations. Windows retains its virtual adapter, SOCKS gateway, diagnostics, manual connection and route cleanup.

The native relay advertises 128 sessions; Windows reserves 16 for checks and uses up to 112 data sessions. Pending handshakes, DNS work, UDP flows and buffers are bounded. This is a conservative initial capacity, not a speed benchmark. Legacy iSH recovery remains under an advanced disclosure.

**Keep the iPhone app visible and the phone unlocked.** The app stops sharing when backgrounded and can prevent automatic screen sleep while active. Reopen it, tap Start sharing and reconnect after leaving it.

This is not a VPN or kill switch. Other Windows connections can remain available. Some games, VPNs and interface-bound apps may not work. Physical iPhone USB, cellular throughput, reconnect and live route-restoration qualification remain required. This unsigned build is an experimental preview.

## Development

Windows checks and packaging: [docs/BUILD.md](docs/BUILD.md). Native source and tests: `ios/`. On macOS with Xcode, run `bash ios/scripts/build.sh`. The workflow `.github/workflows/build-native-ios.yml` produces an unsigned IPA, simulator preview and validation logs. Sideloadly signs locally; no signing credentials belong in the repository.

Windows pairing uses DPAPI; the iPhone key uses Keychain. A pairing window opens only on request, expires after two minutes, and requires approval on the phone. No browsing-history log or telemetry is implemented.

Educational Purposes Only. Carrier billing and hotspot classification are unverified. Read [EDUCATIONAL USE.txt](EDUCATIONAL%20USE.txt), [PRIVACY.txt](PRIVACY.txt) and [LICENSE](LICENSE). PolyForm Noncommercial 1.0.0; commercial use requires permission from Zuyis. Independent of Apple, Microsoft, Sideloadly, iSH and carriers.
