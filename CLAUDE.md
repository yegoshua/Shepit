# CLAUDE.md

Shepit — a macOS menu-bar dictation app: hold a hotkey, speak, and the recognized text is pasted into the focused window. Speech recognition runs locally via WhisperKit (Core ML) with whisper-large-v3-turbo.

## Commands

Xcode is not required — everything builds with SwiftPM and the Command Line Tools.

```bash
./scripts/bundle.sh && open build/Shepit.app   # build and run the .app
swift build -c release                         # compile only
./scripts/test.sh                              # run tests (Swift Testing)
```

Pure, framework-free logic lives in the `ShepitCore` target and is tested there; `Shepit` holds the AppKit/AVFoundation/WhisperKit adapters.

`bundle.sh` signs with the self-signed "Shepit Dev" code-signing certificate from the login keychain so macOS keeps Accessibility/Microphone permissions across rebuilds. Without it, it falls back to ad-hoc signing and the permissions reset on every rebuild. Startup diagnostics go to `~/Library/Logs/Shepit.log`.

## Agent skills

### Issue tracker

Issues and specs live in GitHub Issues of `yegoshua/Shepit` (via `gh`). See `docs/agents/issue-tracker.md`.

### Triage labels

Default five roles: needs-triage, needs-info, ready-for-agent, ready-for-human, wontfix. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.
