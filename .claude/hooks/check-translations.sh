#!/bin/bash
# PostToolUse hook: sync new L("…") keys into en.lproj/Localizable.strings
#
# Fires after Edit / Write / MultiEdit on a .swift file under macshot/.
# Extracts every L("<key>") call from the edited file, diffs against the
# keys already in en.lproj, and appends any new ones to en.lproj so the
# canonical English strings file never drifts behind the code.
#
# Non-English locales are NOT touched — translating those is a judgment
# call best made in a dedicated agent fleet, not silently by a hook. The
# hook prints a short reminder when new keys are added so the author
# knows to trigger translators before the next release.
#
# Exit codes and stderr output:
#   - stdout is ignored by Claude Code.
#   - stderr is surfaced to the assistant as a system reminder IF we
#     exit non-zero. We use exit 2 (the "non-blocking stderr" convention
#     per hooks docs) when there's something to report; exit 0 otherwise.

set -eu

# ---------------------------------------------------------------------------
# Read the tool payload from stdin. Claude passes a JSON object with the
# tool name, the inputs, and (for PostToolUse) the result. We only need
# the file path.
# ---------------------------------------------------------------------------
payload=$(cat)

# Extract file_path from tool_input. jq is installed by default on macOS.
file_path=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty')

# Guard: only Swift sources under macshot/ matter.
[[ -z "$file_path" ]] && exit 0
[[ "$file_path" != *.swift ]] && exit 0
[[ "$file_path" != *"/macshot/"* ]] && exit 0
[[ ! -f "$file_path" ]] && exit 0

# ---------------------------------------------------------------------------
# Locate en.lproj relative to this hook (checked-in alongside the script).
# ---------------------------------------------------------------------------
hook_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$hook_dir/../.." && pwd)"
en_file="$repo_root/macshot/en.lproj/Localizable.strings"
[[ ! -f "$en_file" ]] && exit 0

# ---------------------------------------------------------------------------
# Extract every L("…") call from the edited file. The pattern is strict
# enough to avoid false positives inside comments or doc strings that
# mention "L(" in prose.
#
# Known limitation: multi-line string literals inside L(...) won't be
# caught. In practice macshot doesn't use those for localized strings.
# ---------------------------------------------------------------------------
keys_in_file=$(grep -oE 'L\("[^"]+"\)' "$file_path" | sed -E 's/^L\("(.*)"\)$/\1/' | sort -u || true)
[[ -z "$keys_in_file" ]] && exit 0

# ---------------------------------------------------------------------------
# Build the set of keys already present in en.lproj.
# The file uses "key" = "value"; syntax, one entry per line.
# ---------------------------------------------------------------------------
en_keys=$(grep -oE '^"[^"]+"' "$en_file" | sed -E 's/^"(.*)"$/\1/' | sort -u)

# Keys in the code but NOT in en.lproj.
missing=$(comm -23 <(printf '%s\n' "$keys_in_file") <(printf '%s\n' "$en_keys") || true)
[[ -z "$missing" ]] && exit 0

# ---------------------------------------------------------------------------
# Append missing keys to en.lproj. Each new entry uses the English key
# as both key and value, which is the convention the file already uses
# for every other line. Insert a separator comment the first time so it's
# visually clear these were auto-added.
# ---------------------------------------------------------------------------
marker='/* --- Auto-appended by .claude/hooks/check-translations.sh --- */'
if ! grep -qF "$marker" "$en_file"; then
    printf '\n%s\n' "$marker" >> "$en_file"
fi

count=0
while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    # Escape any double quotes in the key for the .strings value side.
    # In practice keys don't contain quotes (they're user-facing text),
    # but belt-and-suspenders.
    escaped=$(printf '%s' "$key" | sed 's/"/\\"/g')
    printf '"%s" = "%s";\n' "$escaped" "$escaped" >> "$en_file"
    count=$((count + 1))
done <<< "$missing"

# ---------------------------------------------------------------------------
# Report what happened. Exit 2 so Claude surfaces stderr as a system
# message — that's the expected way to "warn without blocking" from a
# PostToolUse hook.
# ---------------------------------------------------------------------------
{
    echo "[translation-hook] $count new L() key(s) added to en.lproj/Localizable.strings:"
    printf '%s\n' "$missing" | sed 's/^/  - /'
    echo "Other 39 locales still need translations — dispatch translator agents before shipping."
} >&2
exit 2
