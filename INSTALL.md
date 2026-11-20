# Install iPhone USB Internet 2.0.0 preview

## Windows

Disconnect the current connection and close USB Internet. Run **iPhone-USB-Internet-Setup.exe**. The existing Windows pairing is retained. WebView2 and Apple device support are required. The installer is unsigned.

If Sideloadly already works for Lens AR Lab, use that Apple driver/signing setup. Otherwise follow the current prerequisites at [Sideloadly](https://sideloadly.io/).

## Install the iPhone app

1. Connect and unlock an iPhone running iOS 16+. Trust the computer if asked.
2. Open Sideloadly and select the iPhone.
3. Drag **iPhone-USB-Internet-unsigned.ipa** into Sideloadly, use your Apple account, and click **Start**. Enter credentials only in the signing application.
4. Follow iOS prompts to trust the developer under **Settings → General → VPN & Device Management**, and enable **Privacy & Security → Developer Mode** if required.
5. Open **USB Internet** on the phone. It is separate from Lens AR Lab.

Free-account signing normally lasts seven days and is subject to Apple's app limits. Sideloadly can refresh it while the required PC/device setup is available. Keep the IPA. Install updates over the existing app with the same Apple account and bundle-ID settings to retain pairing.

## Pair once

1. Stop the old iSH relay and close iSH. Both relays use the same ports.
2. In **USB Internet**, tap **Pair with PC**. The pairing window lasts two minutes.
3. In Windows, expand **Setup & maintenance** and choose **Pair native iPhone app**.
4. Compare the six-digit code on both screens, then approve on the phone only if they match.
5. Wait for the Windows success message.

Your existing Windows key is reused and saved in iOS Keychain. Approving a different PC replaces the phone's previous key. Pairing does not change routing. If signing changes or reinstallation loses the key, pair again.

## Connect each time

1. Plug in and unlock the phone. Keep **cellular on**, **Wi-Fi off**, and **Personal Hotspot off**.
2. Open **USB Internet** and tap **Start sharing**. Wait for **Ready for USB**.
3. Keep the app visible. **Keep screen awake while sharing** prevents automatic locking. Manually locking or leaving the app stops sharing.
4. Choose **Check phone** in Windows, then **Connect PC** after it passes. Approve the administrator prompt with the same Windows account that owns the pairing.
5. When finished, choose **Disconnect** in Windows and **Stop sharing** on the phone.

## Troubleshooting

| Problem | Action |
| --- | --- |
| Pairing port unavailable | Stop and close iSH; tap Pair with PC again. |
| Phone not found | Unlock, trust the PC, check the cable and Apple device support; use the paired phone. |
| Pairing timeout | Repeat Pair with PC on the phone, then Pair native iPhone app in Windows. |
| Authentication fails | Disconnect Windows, stop sharing and pair again. |
| USB passes but HTTPS fails | Check cellular service, the app's cellular-data permission and phone VPN. Keep Wi-Fi off. |
| Sharing paused | Reopen the app, Start sharing, then reconnect in Windows. |
| App will not launch | Refresh/re-sign in Sideloadly with the same settings. |
| PC internet fails after a forced crash | Close the app and restart Windows before reconnecting. |

## Validation and limits

The macOS build tests the actual Swift relay with framing/authentication, filtering, TCP/UDP sockets, concurrent connections, large transfers, half-close and pairing. It builds the device IPA and launches the simulator. Windows uses offline controller/routing/security and browser UI tests.

These checks do not prove physical iPhone USB connectivity, cellular throughput, battery use, reconnect or live Windows route restoration. Test those on the phone before relying on this preview. No locked-screen/background operation is promised. Other Windows connections remain available as fallback; this is not a VPN or kill switch. Some games, VPNs and interface-bound apps may not work. Carrier billing/hotspot classification is unverified.

Uninstall Windows through Settings. Pairing/preferences remain for reinstallation. Never publish pairing files or session folders. Remove the old iSH script yourself if retiring it.
