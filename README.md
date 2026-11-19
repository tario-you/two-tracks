# WisprFree

Dictation for the Mac in the style of Wispr Flow, with speech recognition running on the Mac itself. Hold a key, speak,
and let go: the words land where you're typing, cleaned up and in the style you chose for that kind of app. It also takes
meeting notes: your side and theirs, transcribed live, then cleaned up, with the speakers named and a summary.

## What it does

- **Dictate anywhere.** Hold the talk key (fn by default; Right ⌥, Left ⌥, Right ⌘, Right ⌃ or Right ⇧ in Settings),
  speak, let go. Double-tap it, or press Space while holding it, for hands-free. Esc cancels. ⌃⌘V pastes the last
  dictation again, ⌃⌘C copies it.
- **The flow bar.** A small pill at the bottom of the screen shows a live waveform while you talk, a stop and a cancel
  button when hands-free, and a shimmer while the words are written.
- **Formatting after the words are heard.** Fillers and false starts come out, self-corrections are applied ("at 2,
  actually 3" becomes "at 3"), punctuation, lists, numbers, emails and spoken commands ("new line") are written the way
  people type. Your slang stays. The style follows the app: Formal, Casual, very casual or Excited for personal
  messages, work messages, email and everything else; AI chats and code editors get plain clean text.
- **Dictionary and snippets.** Words to spell right, phrases to swap, and short cues that expand into whole texts.
- **Many languages.** Whisper base names the language of each dictation. Parakeet writes English, Parakeet v3 24 other
  European languages, X-ASR Chinese; with Chinese among your languages, Chinese words inside English speech are kept.
- **Notetaker.** ⌥M starts and stops it. Your microphone and the Mac's sound (the other side of any call) are
  transcribed separately, live. When it stops, the transcript is cleaned up into paragraphs with the speakers named,
  titled and summarized. Ask questions about any meeting, or "What did I miss?" during one. Lines in another language
  get an English translation beside them.
- **Home.** Your dictation history, searchable, with words per minute, total words and your streak.
- **Coming from Wispr Flow?** On first launch WisprFree reads (never writes) Wispr Flow's local data: your dictation
  history, dictionary, snippets, styles, talk key and other settings, and your past Wispr meetings appear in the
  notetaker. While Wispr Flow runs, WisprFree stands by so one key never types twice.

## How it works

| Piece | File |
|---|---|
| The speech router: Whisper base (whisper.cpp) names the language; Parakeet, Parakeet v3 or X-ASR (sherpa-onnx) writes it | `Engine.swift` |
| Downloading the models once (about 1.6 GB) | `Models.swift` |
| The talk key, its double tap, Space, Esc and the shortcuts, through a Quartz event tap | `KeyTap.swift` |
| Recording, transcribing, formatting and pasting a dictation | `Dictation.swift` |
| Formatting: the model's instructions, the plain rules that stand in for it, styles per app, dictionary, snippets | `Formatter.swift` |
| Pasting at the cursor and reading the text before it (Accessibility), muting while dictating | `Inserter.swift` |
| Gemini on Vertex AI (gcloud's sign-in) for formatting; Claude Code on your Claude plan for meeting work | `LLM.swift` |
| The flow bar | `FlowBar.swift` |
| Home, Dictionary, Snippets, Style, Settings and first launch | `Hub.swift`, `Settings.swift` |
| History, dictionary and snippets in SQLite; reading Wispr Flow's | `Library.swift` |
| The notetaker: mic and system audio, segmenter, the cleaned-up transcript, questions, summaries, translation | `Audio.swift`, `Meeting.swift`, `Translate.swift`, `NotetakerViews.swift`, `Wispr.swift` |

Speech never leaves the Mac. Formatting sends the words of each dictation (never audio) to Gemini on your own Google
Cloud project: sign in once with `gcloud auth login` and set a project with `gcloud config set project …` (or name one
in Settings). Without it, dictation still works with plain rules. Meeting cleanup, summaries and questions use Claude
Code on your Claude plan when it's installed and signed in, and Gemini otherwise.

Data lives in `~/Library/Application Support/WisprFree`: `wisprfree.sqlite` (history, dictionary, snippets), `notes/`
(meetings) and `models/`. Notes that Two Tracks kept are copied in on first launch.

## Build and install

Requires macOS 15 or later on Apple silicon and Xcode's command line tools.

```bash
git clone https://github.com/tario-you/two-tracks.git
cd two-tracks
scripts/build-app.sh --install
```

`scripts/fetch-engine.sh` (run by the build when needed) downloads sherpa-onnx's macOS library and whisper.cpp's
framework, pinned to their checksums. To keep macOS's Microphone and Accessibility permissions across rebuilds, sign
with your own identity: `SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh --install`.

Checks without the window:

```bash
.build/release/WisprFree --dictate recording.wav --app com.apple.MobileSMS   # one dictation, with timings
.build/release/WisprFree --eval 50                                          # Wispr Flow's last 50 recordings, side by side
.build/release/WisprFree --probe meeting.wav                                # the notetaker's path on a recording
```

## License

MIT. EB Garamond and Figtree are under the SIL Open Font License (`Resources/Fonts`).
