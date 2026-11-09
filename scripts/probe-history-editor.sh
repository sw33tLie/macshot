#!/bin/bash
# Build the real screenshot editor/history services in a private source copy.
# Only the private copy's entry point and history-directory injection differ.
# No real captures, default history directory, or production preferences touched.
set -euo pipefail
cd "$(dirname "$0")/.."
probe_directory=$(mktemp -d "${TMPDIR:-/tmp}/macshot-history-editor-probe.XXXXXX")
cp -R macshot macshot.xcodeproj "$probe_directory/"
cp scripts/probe-history-editor.swift "$probe_directory/macshot/main.swift"
python3 - "$probe_directory" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
source = root / 'macshot/Services/ScreenshotHistory.swift'
text = source.read_text()
old = 'static let shared = ScreenshotHistory()'
new = '''static let shared: ScreenshotHistory = {
        let root = historyProbeDirectory()
        return ScreenshotHistory(directory: root,
        beforeIndexPublication: {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("fail-index").path) {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            let delay = root.appendingPathComponent("delay-index")
            if FileManager.default.fileExists(atPath: delay.path) {
                try FileManager.default.removeItem(at: delay)
                Thread.sleep(forTimeInterval: 10)
            }
        })
    }()'''
assert old in text
source.write_text(text.replace(old, new, 1))
PY
echo "PROBE DIRECTORY: $probe_directory"
xcodebuild -project "$probe_directory/macshot.xcodeproj" -scheme macshot -configuration Release \
  -derivedDataPath "$probe_directory/build" -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  PRODUCT_BUNDLE_IDENTIFIER=com.macshot.history-editor-probe \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) OFFLINE' \
  build > "$probe_directory/build.log" 2>&1
probe_bundle="$probe_directory/build/Build/Products/Release/macshot.app"
/usr/libexec/PlistBuddy -c "Add :HistoryProbeRun string $(basename "$probe_directory")" "$probe_bundle/Contents/Info.plist"
# Sign after the probe-only Info.plist change. File panels and scoped access
# need the same sandbox entitlements as the shipping application.
codesign --force --sign - --entitlements "$probe_directory/macshot/macshot.entitlements" "$probe_bundle"
codesign --verify --deep --strict "$probe_bundle"
echo "PROBE APP: $probe_bundle"
open -n --stdout "$probe_directory/run.log" --stderr "$probe_directory/run.err" "$probe_bundle"
