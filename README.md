# Two Tracks

A meeting notetaker for the Mac that keeps two transcripts side by side: what was said, in whatever language it was said, and the same thing in English.

Press **Start notetaker**. Two Tracks listens to your microphone (You) and to whatever your Mac is playing, such as the other side of a Zoom, Meet, Teams or WeChat call (Them). Each pause becomes a line. Whisper works out the language of each line on its own, so a call that moves between Chinese and English is written down as spoken, and the English for every other line appears next to it a moment later. Press **Stop** and the note gets a title and a summary.

- Transcription runs on your Mac (Whisper large-v3 turbo through [WhisperKit](https://github.com/argmaxinc/WhisperKit)). Audio never leaves the machine.
- Translation uses [Claude Code](https://claude.com/claude-code) if it is installed and signed in: one Claude session per note, so each line is translated knowing what came before, on your Claude plan with no API key. Without Claude Code it falls back to Apple's on-device Translation.
- Switch between notes in the sidebar, search them, and show both tracks, only the original, or only English.
- If you use Wispr Flow's Notetaker, its meetings appear in the sidebar too, read-only, with an English track added.

## Install

Requires macOS 15 or later on Apple silicon, and Xcode's command line tools.

```bash
git clone https://github.com/tario-you/two-tracks.git
cd two-tracks
scripts/build-app.sh --install
```

The first time you press Start notetaker, macOS asks for the microphone and for system audio recording, and Two Tracks downloads the speech model once (632 MB). To keep those permissions across rebuilds, sign with your own identity: `SIGN_IDENTITY="Apple Development: …" scripts/build-app.sh --install`.

Two Tracks adds itself to Login Items. Turn that off in System Settings › General › Login Items.

## How it works

| Piece | File |
|---|---|
| Mic with echo cancellation, and system audio through a Core Audio process tap | `Sources/TwoTracks/Audio.swift` |
| Cutting each stream into utterances at pauses, with a threshold that follows the noise floor | `Segmenter` in `Audio.swift` |
| Whisper with per-utterance language detection | `Transcriber.swift` |
| English track: batched Claude Code session, or Apple Translation | `Translator.swift` |
| Recording a note | `Recorder.swift` |
| Wispr Flow meetings | `Wispr.swift` |
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
