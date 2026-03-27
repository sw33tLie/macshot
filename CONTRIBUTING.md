# Contributing to macshot

Thanks for your interest in contributing! macshot is open to bug fixes, improvements, and new features.

## Before you start

- **Bug fixes:** Open a PR directly with a clear description of what's broken and how you fixed it.
- **New features / large changes:** Open an issue first to discuss the approach. This avoids wasted effort if the feature doesn't fit the project direction.
- **Small improvements** (UI polish, performance, code cleanup): PRs welcome without prior discussion.

## Development setup

1. Open `macshot.xcodeproj` in Xcode
2. Build & Run (Cmd+R)
3. Grant Screen Recording permission when prompted

The project uses synchronized file groups — just create `.swift` files in `macshot/` and Xcode picks them up.

## Guidelines

- **Pure AppKit.** No SwiftUI (except `BeautifyRenderer` which requires it for mesh gradients). No Electron, no web views.
- **No new dependencies** unless absolutely necessary. Prefer Apple frameworks.
- **Minimum target is macOS 12.3.** Use `@available` guards for newer APIs.
- **Test on single and multi-monitor setups** if your change touches coordinates, overlays, or screen capture.
- **Don't add features to the PR beyond what it claims to fix/add.** Keep PRs focused.
- **Match existing code style.** No SwiftLint, no formatter — just follow what's already there.

## PR checklist

- [ ] Builds without warnings
- [ ] Tested manually (there are no unit tests)
- [ ] Doesn't break existing behavior
- [ ] Commit message describes *what* and *why*

## Questions?

Open an issue or start a discussion.
