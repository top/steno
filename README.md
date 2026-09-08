# Steno

A menu-bar speech-to-text recorder for macOS. It listens in the background, cuts
what it hears into utterances, transcribes them through an endpoint you choose,
and keeps the text in a local SQLite database.

It is a recorder, not an assistant. It does not summarize, answer, or act — it
writes down what was said.

[![Release](https://img.shields.io/github/v/release/top/steno)](https://github.com/top/steno/releases/latest)
![Platform](https://img.shields.io/badge/platform-macOS%2015%2B-lightgrey)
![Architecture](https://img.shields.io/badge/arch-universal%20(arm64%20%2B%20x86__64)-blue)
![Swift](https://img.shields.io/badge/swift-5.10-orange)

## Features

- **Menu-bar only.** No Dock icon, no main window. The icon reflects capture
  state (recording, yielded, paused, permission needed…).
- **Voice-activity segmentation.** Speech onset, silence-end, pre-roll, and
  min/max segment length are all configurable; silence is never sent anywhere.
  A pre-roll buffer keeps the audio just before onset so words aren't clipped.
- **Microphone arbitration.** Chooses what happens when another app wants the
  mic: always record, yield to any input app, yield to configured apps, or
  manual only. Apps that hold the mic permanently (noise-cancellation tools,
  for example) can be excluded by bundle ID so they never pause recording.
- **Playback policy.** Optionally pause capture while this Mac is playing audio.
- **Works offline.** Segments are spooled to disk the moment they close. With no
  network the queue simply parks — no retries are burned and nothing is marked
  failed — and once connectivity returns the backlog is transcribed in the order
  it was spoken. A backlog also survives quitting the app or a crash.
- **Bring your own transcription.** Any OpenAI-compatible
  `/audio/transcriptions` endpoint, or Apple's built-in speech recognition.
- **Optional LLM cleanup.** Send finished transcripts through any
  OpenAI-compatible `/chat/completions` endpoint to fix punctuation and casing,
  improve readability, or condense to notes. Off by default.
- **Local storage with full-text search.** SQLite with FTS5, plus version
  history for raw and optimized text.
- **Auditable.** Capture events, STT jobs, and clipboard writes are all
  recorded, so "did it work, and what did it do?" is answerable after the fact.
- **Export and delete.** Export all transcripts to a text file, or delete
  everything (segments and their audit records) in one action.
- **Launch at login**, and optionally start listening immediately.

## Requirements

- macOS 15 or newer
- Swift 5.10 toolchain (Xcode 16 or the standalone toolchain)
- An OpenAI-compatible transcription endpoint, or Apple speech recognition

## Install

### Download

Get the latest DMG from the [Releases](https://github.com/top/steno/releases)
page, then drag **Steno** to your Applications folder. One universal build runs
natively on both Apple Silicon and Intel Macs.

The app is signed ad-hoc rather than notarized, so the first launch needs a
right-click → **Open** to get past Gatekeeper.

### Build from source

```sh
git clone https://github.com/top/steno.git
cd steno
scripts/build-app.sh
```

This produces `Build/Steno.app` for your own architecture. Move it to
`/Applications` and launch it. Set `ARCHS="arm64 x86_64"` to build the universal
binary instead — that needs a full Xcode install, not just the Command Line
Tools.

> Use the app bundle, not `swift run`, for anything involving the microphone.
> macOS attaches privacy permissions to a signed bundle identity; a bare
> executable cannot hold a stable microphone grant.

## First run

1. Click the menu-bar icon → **Start listening**. macOS prompts for microphone
   access at this point, not at launch.
2. Open **Settings** from the same menu and configure a transcription provider
   (see below). The STT tab reports whether the current configuration is valid.

The app starts idle. Nothing is captured until you start listening.

## Configuration

Settings are organized into five tabs.

### General
Launch at login, start recording on launch, and auto-copy each finished
transcript to the clipboard. Also shows the database location, export/delete
actions, and pipeline counters (transcribed / failed / in progress).

### Recording
Segment timing — speech onset, silence end, pre-roll, and maximum/minimum
segment length — plus voice-activity sensitivity. Higher sensitivity catches
quieter speech at the cost of more false triggers.

### Arbitration
Microphone arbitration mode, recovery debounce, the excluded-apps list, and the
playback policy.

### STT

Two providers, and deliberately no per-vendor list:

**Custom API** — any OpenAI-compatible `/audio/transcriptions` endpoint. Fill in
the endpoint, model ID, timeout, and API key. Segments are uploaded as WAV in a
multipart request with a `Bearer` token, and the response is read from the
`text` field. Because this is the de-facto standard shape, it covers hosted
services, gateways, and local servers (`whisper.cpp`, LM Studio, and similar)
without any provider-specific code.

Endpoints must use HTTPS. Plain HTTP is permitted only for `localhost`,
`127.0.0.1`, and `::1`, so a local model server works without weakening
transport security for remote ones.

**Apple System Speech** — the system recognizer, with no configuration and no
network dependency. Defaults to on-device only; allowing Apple's service (which
may send audio to Apple's servers) is an explicit opt-in.

### LLM

Optional post-processing, disabled by default, through any OpenAI-compatible
`/chat/completions` endpoint. Three behaviors: punctuation and casing,
readability rewrite, or concise notes. Raw and optimized text are both kept, so
the original transcript is never lost to a rewrite.

## Data and privacy

- Transcripts live in `~/Library/Application Support/Steno/Steno.sqlite3`.
- **Audio is spooled to disk only until it has been transcribed.** Segments are
  written to `~/Library/Application Support/Steno/PendingAudio/` and deleted as
  soon as their transcript is stored. This is what makes an offline recording
  recoverable — audio held only in memory would be lost the moment the app quit.
  A segment whose transcription failed keeps its audio so it can be retried
  later rather than silently lost.
- **Audio is not retained after transcription unless you ask for it.** Enabling
  *Keep audio after transcription* in Settings saves each segment as a WAV file
  under `PendingAudio/Transcribed/` instead of deleting it. Off by default.
  Settings shows how much space both the pending and saved audio occupy.
- Deleting all transcripts deletes the spooled and saved audio along with them.
- Audio leaves your machine only if you select a remote transcription endpoint —
  or Apple System Speech with the Apple-service policy enabled. Apple's
  on-device-only mode and a `localhost` endpoint both keep audio local.
- Transcript text is sent to your LLM endpoint only while LLM optimization is
  enabled.
- API keys are stored in the app's settings, not the system Keychain.
- Clipboard writes are logged and never read back — the app does not inspect or
  restore your existing clipboard contents.

## How it works

```
AVAudioEngine → VAD/segmenter → audio spool → STT job queue → SQLite
                     ↑            (on disk)        ↓
               arbitration                  optional LLM cleanup
```

Capture is gated by an arbitration state machine that folds together user
intent, microphone permission, device availability, other apps' microphone use,
and playback state into a single capture decision, and logs every transition
with a reason code.

A closed segment is written to the audio spool before anything else happens to
it, and the file is removed only once its transcript is committed. The spool is
therefore the queue: whatever is still on disk at launch is unfinished work, and
gets requeued oldest-first.

Jobs run one at a time, retried up to three times with exponential backoff (1s,
2s, 4s). Remote transcription waits on a network path first (`NWPathMonitor`), so
being offline parks the queue rather than consuming its retry budget; endpoints
on `localhost` are never gated. Job state, attempt count, and errors are
persisted, so a failure is diagnosable rather than silent.

## Development

```sh
swift build                              # build
swift run ArbitrationStateMachineChecks  # assertion suite
scripts/build-app.sh                     # signed .app bundle
```

The checks target is a plain executable of `assert`-style checks — arbitration
state machine, settings validation and persistence, database schema, activity
summary, WAV encoding, and VAD onset behavior. No test framework required.

Layout:

- `Sources/StenoCore` — capture, VAD, arbitration, audio spool, STT/LLM
  providers, coordinator, SQLite layer. No UI.
- `Sources/StenoApp` — menu bar and settings UI (SwiftUI).
- `Tests/ArbitrationStateMachineChecks` — the assertion suite.

### Releasing

The version is maintained in exactly one place: `CFBundleShortVersionString` in
`Sources/StenoApp/Info.plist`.

Every push to `main` runs the checks and builds the universal DMG. The workflow
publishes a release tagged `v<version>` only when that tag does not exist yet,
so **bumping the version is what ships a release** — other pushes just verify
that `main` still builds and packages.

To cut a release: bump `CFBundleShortVersionString` (and `CFBundleVersion`),
commit, and push to `main`.

## Limitations

- System-output (playback) transcription and audible-output detection need the
  macOS 26 process-tap API and are not implemented; the UI hides the policies
  that would require them.
- Streaming/partial transcription is not supported — segments are transcribed
  after they close.
- The audio spool has no size cap. A long offline stretch is expected to
  accumulate (16-bit spooled audio runs roughly 100 MB per hour of speech at a
  48 kHz capture rate), and evicting it would defeat its purpose, so Settings
  reports the size rather than trimming it.
- A job that fails for a non-network reason (a wrong key, say) is retried at the
  next launch rather than the moment the cause is fixed.
- The app bundle is ad-hoc signed and not notarized.

## License

[MIT](LICENSE)
