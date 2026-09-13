# CLAUDE.md

Shepit — a macOS menu-bar dictation app: hold a hotkey, speak, and the recognized text is pasted into the focused window. Speech recognition runs locally via WhisperKit (Core ML) with whisper-large-v3-turbo.

## Commands

Xcode is not required — everything builds with SwiftPM and the Command Line Tools.

```bash
./scripts/bundle.sh && open build/VoiceType.app   # build and run the .app
swift build -c release                            # compile only
```

Ad-hoc code signing makes macOS forget the Accessibility permission after every rebuild; re-enable it in System Settings → Privacy & Security → Accessibility.

## Agent skills

### Issue tracker

Issues and specs live in GitHub Issues of `yegoshua/Shepit` (via `gh`). See `docs/agents/issue-tracker.md`.

### Triage labels

Default five roles: needs-triage, needs-info, ready-for-agent, ready-for-human, wontfix. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.
