---
description: Find every L("…") key missing from any locale and dispatch a parallel translator fleet to fix them.
---

You are invoked to sync localization across all macshot locale files.
The repo lives at `/Users/sw33tlie/Documents/GitHub/macshot`.

## Plan

1. **Find missing keys per locale** — run a Python one-liner that:
   - Grabs every `L("…")` key that appears in the Swift sources under `macshot/`.
   - Reads each `macshot/<lang>.lproj/Localizable.strings`, normalizing `\UXXXX` escapes so they compare equal to literal characters.
   - Emits a JSON-ish table of `{locale: [missing_keys_sorted]}`.

   Use this exact script (pipe it through `python3`):

   ```python
   import re, os, json
   d = '/Users/sw33tlie/Documents/GitHub/macshot/macshot'
   code = set()
   for root, _, files in os.walk(d):
       if '.lproj' in root: continue
       for f in files:
           if not f.endswith('.swift'): continue
           with open(os.path.join(root, f), encoding='utf-8', errors='ignore') as fh:
               for m in re.finditer(r'L\("([^"]+)"\)', fh.read()):
                   code.add(m.group(1))
   def keys_of(path):
       with open(path, encoding='utf-8') as fh: c = fh.read()
       c = re.sub(r'\\U([0-9a-fA-F]{4})', lambda m: chr(int(m.group(1), 16)), c)
       return {m.group(1) for m in re.finditer(r'^"([^"]+)"\s*=', c, re.M)}
   result = {}
   for sub in sorted(os.listdir(d)):
       if not sub.endswith('.lproj') or sub == 'Base.lproj': continue
       p = os.path.join(d, sub, 'Localizable.strings')
       if not os.path.exists(p): continue
       missing = sorted(code - keys_of(p))
       if missing: result[sub.replace('.lproj','')] = missing
   print(json.dumps(result, indent=2, ensure_ascii=False))
   ```

2. **If `en` is in the missing map**, handle it specially and FIRST:
   - English is the canonical source — add the missing keys to
     `macshot/en.lproj/Localizable.strings` directly, using the English
     string as both key and value. Insert near semantically-related
     existing entries (e.g. "Add X" near other "Add …" keys). Do NOT
     dispatch a translator for English.
   - After adding, re-run the Python diff so the resulting task list
     no longer mentions `en`.

3. **If the remaining map is empty**, report "All locales in sync." and stop.

4. **Dispatch a parallel translator fleet** for the remaining locales.
   Split locales into 5 groups by language family so each agent gets
   a coherent workload:

   - Group A (European Tier-1): `de, fr, es, it, pt-BR, pt, nl, pl`
   - Group B (Asian): `ja, ko, zh-Hans, zh-Hant, th, vi, id, ms, fil`
   - Group C (Nordic): `da, sv, nb, fi`
   - Group D (Slavic): `ru, uk, cs, sk, sr, bg, hr`
   - Group E (Remaining): `ar, he, fa, tr, hu, ro, el, ca, hi, bn, ta`

   For each group that has at least one locale with missing keys,
   dispatch a `general-purpose` agent in parallel (single message, N
   `Agent` tool calls). Each agent's prompt includes:
   - The exact locale paths it owns.
   - The precise missing keys per locale (copied from the Python output).
   - Context for each key: what the string means in the UI (use your
     knowledge of the macshot codebase — effects menu, video editor,
     settings, etc.). Keep the explanation tight: one sentence per
     key is usually enough.
   - Style rules: match the verb form and casing of the semantically-
     closest existing entries in each file (e.g. if adding "Add Freeze"
     and the file already has "Add Speed" = "Aggiungi velocità", use
     "Aggiungi fermo immagine"). Preserve `%@` / `%d` format
     specifiers and surrounding whitespace exactly. Keep brand names
     (macshot, GIF, imgbb, S3, etc.) untranslated.
   - Instruction to insert each new key near semantically-related
     existing entries (e.g. new "Add X" goes near other "Add …" keys),
     not appended blindly to the end. Agents should Read each file
     first to pick the right spot.
   - Instruction to verify with grep that the new keys are present
     after the edit, and report a short summary (under 300 words total).

5. **After all agents complete**, run the Python diff again and confirm
   every locale is in sync. Report any remaining gaps.

6. **Do NOT run a build** — this command only touches `.strings` files.
   The next build will pick them up automatically.

7. **Do NOT commit** unless the user asked you to. Stop after verification.

## Edge cases

- If the Python script errors, fix the script (don't guess the missing
  keys from memory — always derive from actual file contents).
- If the user invokes this with zero missing keys, that's fine — just
  say "All locales in sync." and stop without dispatching anything.
- If a single locale has >20 missing keys, mention it in the agent's
  prompt so the translator knows it's a bigger batch; no special
  handling needed.
- If a locale has a non-standard escape convention (e.g. `\uXXXX` with
  lowercase u instead of `\UXXXX`), leave the existing content alone —
  just add the new keys in the canonical `\U` form. A past translator
  fleet has already found and normalized these cases where it mattered.
