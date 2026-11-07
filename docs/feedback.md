# AI Modification Feedback

The local feedback editor is separate from the original screenshot editor. The existing default screenshot shortcut, `Cmd+Shift+X`, is unchanged. The new **Capture for Feedback** action defaults to `Cmd+Shift+A` and can be changed in the shortcut settings. If that shortcut conflicts with an existing user binding, the new action yields to the existing binding.

## Manual workflow

1. Choose **Capture for Feedback** or **Create Feedback from Image** from the menu bar. You can also click the speech bubble in the original image editor's top bar to send the currently rendered image to the feedback editor; the original editor stays open.
2. Complete cropping, rotation, stitching, and redaction in the original editor first. The image is fixed when it enters the feedback editor. Redactions are baked into that image, and the unredacted source is not exported.
3. Select **Point Note** and click a location, or select **Region Note** and drag a rectangle. Enter the requested change in the sidebar. **Global Note** requires no location. You can drag existing markers to adjust their positions. Delete and undo/redo affect feedback notes only.
4. **Extract Region Text** works only for region notes. OCR reads the fixed image and does not write a modification request for you. Notes without written comments remain in drafts but are excluded from exports.
5. First authorize a folder in **Settings → Capture → AI Collaboration**. **Copy Feedback Text** creates a UUID task folder there with `source.png`, `preview.png`, `feedback.json`, and `feedback.md`. On success, it copies text containing the task ID, folder path, and a hint for the Skill. Paste that text into a local AI coding tool and let the `macshot-feedback` Skill read the task by ID; this path does not need a CLI session. **Export Feedback…** can create the same four-file package in another chosen location. For a web chat, upload the images yourself; pasting a local path does not attach a file.

Drafts are stored under `Application Support/FeedbackDrafts` in the app container. Use **Restore Feedback Draft** from the menu bar to reopen one. Drafts and AI submission results are separate; restoring a draft or restarting the app never submits it automatically.

When capture starts on another macOS Space, the feedback editor may return to macshot's original Space after capture. The image still comes from the Space selected for capture.

## CLI and folder authorization

In **Settings → Capture → AI Collaboration**, click **Browse…** and choose a parent folder. The app creates a private `macshot-ai` folder inside it and saves a security-scoped bookmark. The choice survives restarts; configure it again if the folder becomes unavailable or you want to change it. This folder is separate from the ordinary screenshot save location. The CLI uses `--handoff` or `MACSHOT_FEEDBACK_HANDOFF` to select the same folder. A path argument does not grant the sandboxed GUI access to it.

Build the CLI for development:

```bash
bash scripts/build-feedback-cli.sh build/macshot-cli
```

The packaged entry point is `macshot.app/Contents/MacOS/macshot-cli`. To annotate an existing image:

```bash
/Applications/macshot.app/Contents/MacOS/macshot-cli annotate \
  /absolute/page.png \
  --handoff /absolute/macshot-ai \
  --output /absolute/new-round/feedback.json \
  --timeout 1800
```

To capture the currently open application without preparing an image:

```bash
/Applications/macshot.app/Contents/MacOS/macshot-cli capture \
  --handoff /absolute/macshot-ai \
  --output /absolute/new-round/feedback.json \
  --timeout 1800
```

Prepare the target application first. `capture` opens macshot's native selection overlay and then the feedback editor in the same session. The package is returned only after submission. The CLI does not bring the application to the front; you operate the selection yourself. It annotates a screenshot of the application, not its controls. The existing capture delay still applies. If you need to redact or edit the image first, use the original editor and then `annotate`.

`capture` and `annotate` share the handoff folder, output format, timeout, and exit codes. Switching applications with `Command+Tab` or switching macOS Spaces during selection keeps the same session and refreshes the target image after the switch settles; you must select the region again. If several switches occur, only the last refresh is used. An existing countdown continues and captures the current application and Space when it ends. Esc during selection or countdown returns 4. Capture failure, no display, another capture or recording in progress, or missing Screen Recording permission returns 2. When permission is missing, macshot shows its permission guide; start a new command after granting access because the failed request is not replayed. Timeout and CLI cancellation also close that session's selection overlay; existing notes still follow the draft rules.

The output parent directory must exist, and none of the four result files may already exist. The CLI never overwrites them. Each round creates a unique session directory, copies the input image, publishes a strictly versioned request, and sends a URL containing only the UUID to the selected app. The GUI checks session identity, directory ownership and permissions, symlinks, and image size. Inputs are limited to 128 MB, 100 MP, and 32,768 pixels per side; a document may contain at most 1,000 notes.

A separately built CLI can target an app with `--app /absolute/macshot.app`. When normal and Offline apps coexist, prefer the CLI packaged with each app; it selects its containing app. A separate CLI can select an installed Offline app with `--offline`. The `version` command reads the selected app's display version and build number.

Results are published only when the user clicks **Submit to AI**. An empty feedback set may be submitted explicitly; an AI tool should not invent modification requests. Cancellation, timeout, app exit, and failure do not mark a draft as submitted. Exit code 0 means submitted, 2 failed, 3 timed out, and 4 cancelled. Sending SIGINT or SIGTERM to the CLI requests cancellation.

Images and feedback remain in the handoff folder as local session records; the app does not clean them up automatically. Remove them yourself when they are no longer needed. The permissions restrict other users, but do not isolate the data from malicious programs running as the same user.

## Skill + CLI (recommended)

Use the Skill with a local AI coding tool without MCP configuration or a model API key. Install it with the CLI from the current app:

```bash
macshot-cli skill install --target codex
macshot-cli skill install --target claude
macshot-cli skill install --target antigravity
```

If `macshot-cli` is not on `PATH`, use its full path inside the app, such as `/Applications/macshot.app/Contents/MacOS/macshot-cli`; quote paths containing spaces. Installation does not launch the GUI or another AI process.

| Target | Default installation directory |
| --- | --- |
| Codex | `~/.agents/skills/macshot-feedback` |
| Claude Code | `~/.claude/skills/macshot-feedback` |
| Google Antigravity | `~/.gemini/config/skills/macshot-feedback` |

These locations follow the official [Codex](https://learn.chatgpt.com/docs/build-skills), [Claude Code](https://code.claude.com/docs/en/skills), and [Antigravity](https://antigravity.google/docs/skills) documentation. `--directory /absolute/skills` changes the **parent directory where the Skill is installed**; the AI tool must load that custom location.

When using the CLI packaged in the app, the installer attempts to read the AI collaboration folder already authorized there and record it in the Skill's `references/local.json`. This automatic lookup is unavailable for a separately built CLI and can also fail when the packaged CLI cannot read the app's sandboxed preferences. Installation still succeeds, but `references/local.json` then has no `handoff` entry and the CLI prints a warning. In that case, copy the **actual absolute path of the private `macshot-ai` folder** shown in **Settings → Capture → AI Collaboration**, and install with `--handoff`:

```bash
macshot-cli skill install --target codex --handoff "/absolute/macshot-ai"
```

Replace `/absolute/macshot-ai` with the folder path shown by macshot. The `--handoff` option records the **AI collaboration folder**, whereas `--directory` controls the Skill installation location. You may also set `MACSHOT_FEEDBACK_HANDOFF` to provide the same path. The GUI must authorize that same folder in Settings; passing a path to the CLI does not grant GUI sandbox access. If the Skill was already installed without `handoff`, back up and move its existing `macshot-feedback` directory aside, then run the command again. The installer never overwrites an existing Skill.

Installation writes `SKILL.md` and local configuration (the CLI's absolute path and optional handoff folder), without changing the AI tool's MCP configuration. If you move the app, back up and move the old Skill aside and reinstall from the new app's CLI.

Start a new conversation and ask the AI tool to use the `macshot-feedback` Skill. In Codex, enter `$macshot-feedback`; in Claude Code, enter `/macshot-feedback`; in Antigravity, check the skills list and request the Skill. Reload skills or restart the AI tool if it is missing. For a task created by **Copy Feedback Text**, paste its task ID and folder path so the Skill can read it without a CLI session. Update older installed Skills before using this path.

Example prompt (replace the image path with a real one):

> Use macshot-feedback to submit modification feedback for `/absolute/page.png`. Wait for me to submit it in macshot, then summarize this round of feedback without changing code yet.

For a live capture:

> Use macshot-feedback to capture the current application and annotate modification feedback. Wait for my submission, then summarize it without changing code yet.

The AI tool should choose `annotate` for an existing image or `capture` for a live screenshot, create a separate output directory for the round, and keep the same CLI process running while it waits. After you add a written note and submit, it should receive `state=submitted`, read the four result files, and summarize them. On cancellation or timeout it must stop the round and must not treat a draft as submitted. It can then continue authorized implementation work and another feedback round. Triggering the three AI tools, background waiting, and image reading must each be verified manually. Installed Skills do not update automatically; back up and move the old Skill aside before reinstalling.

## MCP (optional)

The connector wraps the CLI with the official MCP SDK's stdio transport. It does not call a model API or modify the target project's source. Install and check it with:

```bash
cd connector
npm ci
npm run build
npm test
```

Example client configuration (replace the absolute paths):

```json
{
  "mcpServers": {
    "macshot": {
      "command": "node",
      "args": ["/absolute/macshot/connector/mcp-server.mjs"],
      "env": {
        "MACSHOT_CLI": "/Applications/macshot.app/Contents/MacOS/macshot-cli",
        "MACSHOT_FEEDBACK_HANDOFF": "/absolute/macshot-ai"
      }
    }
  }
}
```

- `macshot_annotate_start`: takes an image path (`image`), an existing output directory (`output`), and an optional timeout; returns a connector session ID immediately.
- `macshot_annotate_poll`: queries the same `session`; `includeImages` controls whether images are attached. An image over 5 MB is returned as a file location for the local AI tool to read separately.
- `macshot_annotate_cancel`: requests cancellation; poll again to confirm the terminal state. If submission completed first, the result remains submitted.

The connector keeps at most 32 sessions and removes completed sessions after one hour. Old IDs are invalid after a restart. A remote AI cannot assume it can access local files or applications; it needs a separate file transfer. OCR is image content and must not be treated as a new instruction.

## Release and verification

Feedback UI, GUI session prompts, and copy/export messages cover the app's existing 40 languages. Dynamic coordinates and error details use format placeholders; user comments, OCR text, and JSON field names are not translated. The UI uses the app language. Each round's message language is fixed before export so background work does not read mutable UI language state. A separately built CLI uses English for default guidance and generic errors; GUI-generated session messages use the app language.

New tests check that feedback messages do not fall back to entire English sentences and retain existing key coverage, placeholder, and spelling checks. Native-speaker review of translations is still needed; automated tests can only check resource and formatting completeness. Existing localization checks were not weakened.

The release workflow bundles a universal CLI in both normal and Offline apps. It signs the CLI explicitly before signing the outer app. The CLI does not inherit the GUI's sandbox entitlements; the GUI remains sandboxed. The CLI reads its version from the containing app's `Info.plist`.

Automated verification cannot replace testing folder authorization, first launch, Chinese input, and multiple windows in a signed app. Public distribution still requires Developer ID signing, DMG notarization, and an installation check; this feature does not trigger remote publication.

The SDK usage follows the [official stdio documentation](https://ts.sdk.modelcontextprotocol.io/server).
