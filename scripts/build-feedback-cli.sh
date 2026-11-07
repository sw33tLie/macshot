#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=${1:?Usage: build-feedback-cli.sh /absolute/output [arm64|x86_64|universal]}
architecture=${2:-$(uname -m)}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
python3 - "$work/FeedbackSkillTemplate.swift" <<'PY'
from pathlib import Path
import sys
template = Path('skills/macshot-feedback/SKILL.md').read_text()
Path(sys.argv[1]).write_text('enum FeedbackSkillTemplate { static let markdown = #"""\n' + template + '\n"""# }\n')
PY
sources=(cli/main.swift cli/SkillInstaller.swift "$work/FeedbackSkillTemplate.swift" macshot/Model/FeedbackNote.swift macshot/Model/FeedbackSessionProtocol.swift macshot/Model/LenientDecoding.swift macshot/Services/FeedbackExport.swift)
mkdir -p "$(dirname "$output")"
build_one() {
  xcrun swiftc -O -swift-version 5 -target "$1-apple-macosx12.3" "${sources[@]}" -o "$2"
}
if [[ "$architecture" == universal ]]; then
  build_one arm64 "$work/arm64"
  build_one x86_64 "$work/x86_64"
  xcrun lipo -create "$work/arm64" "$work/x86_64" -output "$output"
else
  build_one "$architecture" "$output"
fi
