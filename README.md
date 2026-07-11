# Stille Post

**🌐 Sprache / Language:** [English](README.md) · [Deutsch](README.de.md)

Local dictation app for macOS: Global hotkey, speech-to-text with Whisper, and text
cleanup with a local language model. The finished text lands right at your cursor.
Recordings never leave your machine.

Yes, this is probably the millionth Whisper dictation clone. The difference is the
bar it aims for: **No noticeable wait** after you stop speaking (even for long
dictations) and a cleanup stage that **cleans instead of rewriting**. Typical
dictation tools start processing only after you finish talking, and their cleanup
models paraphrase, shorten, or even "answer" your dictation. Both failure modes are
designed out here.

## How the wait disappears

Stille Post processes audio **while** you speak: A voice-activity detector cuts the
recording stream into segments at natural pauses, and each finished segment is
transcribed immediately, in parallel with the ongoing recording. When you stop,
speech recognition is essentially done; what remains is the text cleanup, which
deliberately runs **once over the whole dictation**. Only with full context can the
model punctuate correctly instead of leaving a spurious period at every pause. The
cleanup model is also pre-warmed when recording **starts**, so no model cold-start
ever lands in your wait time.

## How cleanup stays honest

1. A strict, example-backed system prompt: Remove filler words, false starts,
   stutters and duplications only; never paraphrase, never summarize, never answer
   questions contained in the dictation.
2. A **post-model sanity check**: if the cleaned version deviates strongly from the
   raw transcript in length (a telltale sign of shortening, inventing, or
   "answering"), the raw transcript is used automatically and the history entry is
   flagged. Cleanup can never destroy a dictation.
3. If cleanup fails entirely, the raw transcript is pasted, never nothing.
4. **Deviations are visible:** The overlay shows when cleanup switches to a backup
   endpoint or when the raw transcript was pasted; the history records the endpoint
   used and the cleanup duration for every dictation.

## Features

- **Global hotkey** (default ⌘⌥D, configurable) to start/stop recording.
- **Unmissable recording indicator:** A large red overlay at the mouse position
  (still visible when macOS screen zoom is active, since zoom follows the cursor)
  with a **live microphone level meter**, so you can see that audio is actually
  arriving. Plus clearly distinct start/stop/error sounds and a red menu bar icon.
- **Silence detection:** Pure silence is never sent to Whisper (no hallucinations
  during thinking pauses); after prolonged absence the recording stops automatically.
- **History window:** View and copy all dictations (including the raw transcript
  before cleanup), delete everything with one click.
- **Recordings are deleted immediately after successful transcription.** Only failed
  transcriptions keep their audio so you can hit "Retranscribe" in the history.
  Once it succeeds, the audio is deleted as well.
- **Automatic microphone selection:** Always uses the system default input device.
- **Privacy:** Speech recognition and cleanup run fully local. Optionally, cleanup
  can be delegated to any OpenAI-compatible provider. In that case only the
  transcribed **text** is sent, never audio.

## Scriptable without the GUI (scripts & AI agents)

The entire pipeline is usable headless, with the same logic and configuration:

```bash
stillepost-cli doctor                  # check dependencies (exit code 0 = ready)
stillepost-cli transcribe file.wav     # WAV -> cleaned text on stdout
stillepost-cli transcribe file.wav --raw
stillepost-cli cleanup "raw text"      # cleanup only ("-" reads stdin)
stillepost-cli history list --json     # machine-readable history
stillepost-cli history clear
stillepost-cli set-cleanup-key         # API key for cloud cleanup (reads stdin)
```

Diagnostics go to stderr, results to stdout, failures exit non-zero. Built for
pipes and automation. The `STILLEPOST_CONFIG` environment variable points to an
alternative config file (e.g. for tests).

## Installation

Requirements: macOS 14+, [Homebrew](https://brew.sh), [Ollama](https://ollama.com).

```bash
brew install whisper-cpp          # local Whisper server (whisper.cpp)
ollama pull qwen3.5:9b            # default cleanup model (~6 GB)
# Alternative if you have more RAM: gemma4:e4b (~10 GB loaded), slightly faster
# and more faithful in our tests; selectable via config.json/settings.
scripts/install-model.sh          # Whisper model large-v3-turbo (~1.6 GB)
scripts/build-app.sh --install    # builds the app and installs it to /Applications
open /Applications/StillePost.app
```

On first launch macOS asks for two permissions: **Microphone** (recording) and
**Accessibility** (pasting at the cursor via simulated ⌘V).

## Configuration

All settings are available as a dialog in the menu bar menu under **"Einstellungen …"**
(Settings). Underneath lives `~/Library/Application Support/StillePost/config.json`
(created on first launch, menu item "Konfigurationsdatei öffnen"). The file stays
hand-editable. The most important switches:

| Section | Field | Meaning |
|---|---|---|
| `hotkey` | `keyCode`, `modifiers` | recording hotkey (default ⌘⌥D) |
| `whisper` | `language` | `"auto"` or fixed, e.g. `"de"`. **Recommendation: Pin it.** With `auto`, Whisper guesses the language per speech segment and silently translates on misdetection |
| `cleanup` | `enabled` | cleanup on/off |
| `cleanup` | `provider` | `"ollama"` (local/own network) or `"openai"` (cloud, text only) |
| `cleanup` | `model` | Ollama model name |
| `cleanup` | `ollamaURL` | Ollama endpoint; may also be another machine on your own network |
| `cleanup.remote` | `baseURL`, `model` | OpenAI-compatible provider |
| `cleanup` | `fallbacks` | backup endpoints tried when the primary does not respond (see below) |
| `vad` | `autoStopAfterSilenceSec` | absence auto-stop (0 = off) |
| `ui` | `overlayPosition` | `"mouse"` or `"bottomCenter"` |

Setting up cloud cleanup (example; works with any OpenAI-compatible provider):

```jsonc
"cleanup": {
  "provider": "openai",
  "remote": { "baseURL": "https://api.example.com/v1", "model": "model-name" }
}
```

The API key does **not** go into the file. Store it in the keychain
(`stillepost-cli set-cleanup-key`) or in the `STILLEPOST_CLEANUP_API_KEY`
environment variable.

### Cleanup on a stronger machine (with fallback)

On a weaker laptop it pays off to hand cleanup to a stronger machine on your own
network: The model stays permanently warm there, and the laptop saves the ~8 GB of
RAM for the local model. `fallbacks` lists backup endpoints tried in order when the
primary does not respond (probe timeout 2 s; away from your home network, local
Ollama takes over almost without delay):

```jsonc
"cleanup": {
  "ollamaURL": "http://192.168.1.50:11434",   // strong machine on the LAN (primary)
  "model": "qwen3.5:9b",
  "fallbacks": [
    { "provider": "ollama", "ollamaURL": "http://127.0.0.1:11434", "model": "qwen3.5:9b" },
    { "provider": "openai", "remote": { "baseURL": "https://api.example.com/v1", "model": "model-name" } }
  ]
}
```

Prerequisite on the strong machine: Ollama must listen on the network interface
(`OLLAMA_HOST=0.0.0.0`, or the "Expose Ollama to the network" switch in the Ollama
app). Only transcribed TEXT travels over your network, never audio. Which endpoint
handled a cleanup is shown by `stillepost-cli cleanup`; `stillepost-cli doctor`
checks the whole chain.

## Development & tests

```bash
swift test            # unit tests (VAD, WAV, sanity check, history …)
scripts/e2e-test.sh   # end to end: say voice -> Whisper -> cleanup -> assertions
```

## Status

Early, but usable. Planned: A comparison benchmark (quality and latency) against
other local dictation tools and cloud services.
