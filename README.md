# Two Tracks

A meeting notetaker for the Mac that keeps two transcripts side by side: what was said, in whatever language it was said, and the same thing in English.

Press **Start notetaker**.

- **With [Wispr Flow](https://wisprflow.ai) running**, Start starts Wispr's own Notetaker (by pressing its notetaker shortcut) and Two Tracks follows the meeting live as Wispr transcribes it. Stop presses Wispr's Stop. Nothing is downloaded. Your older Wispr meetings are in the sidebar too.
- **Without Wispr Flow**, Two Tracks records itself: your microphone (You) and whatever the Mac plays, such as the other side of a Zoom, Meet, Teams or WeChat call (Them). Each pause becomes a line, transcribed on the Mac by Whisper large-v3 turbo through [WhisperKit](https://github.com/argmaxinc/WhisperKit), which downloads once (632 MB) the first time. Audio never leaves the machine.

Either way, each line is shown in the language it was spoken, and its English appears beside it a moment later.

- English comes from [Claude Code](https://claude.com/claude-code) if it is installed and signed in: one Claude session per note, so each line is translated knowing what came before, on your Claude plan with no API key. Newest lines go first, so a live meeting never waits behind a backlog. Without Claude Code, Apple's on-device Translation does it.
- Show both tracks, only the original, or only English. Search every note from the sidebar.
- Stopping a note of its own gives it a title and a summary; any note can be summarized from its Summary tab.

## Install

Requires macOS 15 or later on Apple silicon, and Xcode's command line tools.

```bash
git clone https://github.com/tario-you/two-tracks.git
cd two-tracks
scripts/build-app.sh --install
```

With Wispr Flow, the first Start asks to allow Two Tracks under Accessibility (to press Wispr's shortcut and its Stop button). Without it, macOS asks for the microphone and for system audio recording. With Wispr Flow installed, the build gives the app Wispr's icon with a 中/EN tag, drawn from your local copy. To keep those permissions across rebuilds, sign with your own identity: `SIGN_IDENTITY="Apple Development: …" scripts/build-app.sh --install`.

Two Tracks adds itself to Login Items. Turn that off in System Settings › General › Login Items.

## How it works

| Piece | File |
|---|---|
| Mic with echo cancellation, and system audio through a Core Audio process tap | `Sources/TwoTracks/Audio.swift` |
| Cutting each stream into utterances at pauses, with a threshold that follows the noise floor | `Segmenter` in `Audio.swift` |
| Whisper with per-utterance language detection | `Transcriber.swift` |
| English track: batched Claude Code session, or Apple Translation | `Translator.swift` |
| Recording a note | `Recorder.swift` |
| Wispr Flow meetings, and starting and stopping its Notetaker | `Wispr.swift`, `WisprControl.swift` |
| The window | `Views.swift` |

Notes are JSON files in `~/Library/Application Support/Two Tracks/notes`.

To check the pipeline without a microphone or a call, run a recording through it:

```bash
swift build -c release
.build/release/TwoTracks --probe meeting.wav
```

It prints each line with its language and English, and how long transcription and translation took.

## License

MIT
