#!/bin/bash
# Exercise the OCR XPC service inside a real, sandboxed, signed app bundle.
# Builds a private copy whose main.swift runs scripted OCR scenarios, with
# OCR_FAULT_INJECTION so the service can be made to hang, fail or return
# nothing (the ways Vision misbehaves on macOS 27). Prints PROBE PASSED/FAILED
# and checks that the service process exits with the app.
set -euo pipefail
cd "$(dirname "$0")/.."
probe_directory=$(mktemp -d "${TMPDIR:-/tmp}/macshot-ocr-probe.XXXXXX")
cp -R macshot macshotOCRService macshot.xcodeproj "$probe_directory/"
cp scripts/probe-ocr-service.swift "$probe_directory/macshot/main.swift"
echo "PROBE DIRECTORY: $probe_directory"
xcodebuild -project "$probe_directory/macshot.xcodeproj" -scheme macshot -configuration Release \
  -derivedDataPath "$probe_directory/build" -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  MACSHOT_BUNDLE_ID=com.macshot.ocr-service-probe \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) OFFLINE OCR_FAULT_INJECTION' \
  build > "$probe_directory/build.log" 2>&1 || { tail -40 "$probe_directory/build.log"; exit 1; }
probe_bundle="$probe_directory/build/Build/Products/Release/macshot.app"
# Sign like the release workflow: the service keeps its own signature (no
# sandbox), the app is signed last with its sandbox entitlements, no --deep.
codesign --force --options runtime --sign - "$probe_bundle/Contents/XPCServices/macshotOCR.xpc"
codesign --force --options runtime --sign - --entitlements "$probe_directory/macshot/macshot.entitlements" "$probe_bundle"
codesign --verify --deep --strict "$probe_bundle"
echo "PROBE APP: $probe_bundle"
status=0
"$probe_bundle/Contents/MacOS/macshot" 2>"$probe_directory/run.err" | tee "$probe_directory/run.log" || status=$?
service_pid=$(sed -n 's/^SERVICE PID //p' "$probe_directory/run.log" | tail -1)
sleep 2
if [[ -n "$service_pid" && "$service_pid" != nil ]] && kill -0 "$service_pid" 2>/dev/null; then
  echo "FAIL: service process $service_pid outlived the app"
  status=1
else
  echo "ok: service process exited with the app"
fi
exit $status
