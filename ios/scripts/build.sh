#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
xcodebuild -version | tee build/environment.log
swift test --package-path Core 2>&1 | tee build/core-tests.log
swift build --package-path Core --product RelayHarness 2>&1 | tee build/harness-build.log
python3 scripts/integration.py 2>&1 | tee build/protocol-tests.log
if ! command -v xcodegen >/dev/null; then HOMEBREW_NO_AUTO_UPDATE=1 brew install xcodegen; fi
xcodegen generate
xcodebuild -project iPhoneUSBInternet.xcodeproj -scheme iPhoneUSBInternet -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build/Device \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' \
  CURRENT_PROJECT_VERSION="${GITHUB_RUN_NUMBER:-1}" build 2>&1 | tee build/device-build.log
app=build/Device/Build/Products/Release-iphoneos/iPhoneUSBInternet.app
mkdir -p build/package/Payload
ditto "$app" build/package/Payload/iPhoneUSBInternet.app
(cd build/package && /usr/bin/zip -qry ../iPhone-USB-Internet-unsigned.ipa Payload)
(cd build && shasum -a 256 iPhone-USB-Internet-unsigned.ipa > SHA256SUMS.txt)
xcodebuild -project iPhoneUSBInternet.xcodeproj -scheme iPhoneUSBInternet -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath build/Simulator \
  CODE_SIGNING_ALLOWED=NO build 2>&1 | tee build/simulator-build.log
device=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(x["udid"] for v in d["devices"].values() for x in v if x["name"].startswith("iPhone")))')
xcrun simctl boot "$device" || true
xcrun simctl bootstatus "$device" -b
xcrun simctl install "$device" build/Simulator/Build/Products/Debug-iphonesimulator/iPhoneUSBInternet.app
xcrun simctl launch "$device" io.zuyis.iphoneusbinternet
sleep 4
xcrun simctl io "$device" screenshot build/preview.png
