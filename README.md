# Stille Post

**🌐 Sprache / Language:** [English](README.md) · [Deutsch](README.de.md)

Local dictation app for macOS: Global hotkey, speech-to-text with Whisper, and text
cleanup with a local language model. The finished text lands right at your cursor.
Recordings never leave your machine.

The complete interface — menu, settings, history, overlays, model download, and
user-facing errors — is available in English and German. macOS chooses the language
from the system or per-app language preferences. CLI diagnostics are localized as
well.

## Menu bar & history

| | |
|:---:|:---:|
| ![Menu bar menu](assets/en/menu.png) | ![History window](assets/en/history.png) |
| *Menu bar: start/stop, history, settings, quit* | *History: every dictation (raw + cleaned), copy with one click* |

## Ready in five minutes

The signed app package runs on **Apple Silicon Macs with macOS 13 or later**.
The current local version of Ollama requires **macOS 14 or later**. Local speech
recognition still works without Ollama; Stille Post then pastes Whisper's raw text.

### 1. Install Homebrew

If Homebrew is not installed yet, follow the short instructions at
[brew.sh](https://brew.sh).

### 2. Install Whisper

```bash
brew install whisper-cpp
```

This installs the local speech-recognition engine. Stille Post downloads its speech
model separately on first launch.

### 3. Install and start Ollama

[Download Ollama for macOS](https://ollama.com/download/mac), move it to
`/Applications`, and open it once. Ollama only cleans up the finished text; audio is
never sent to it.

### 4. Download the cleanup model

```bash
ollama pull gemma4:e4b-it-qat
```

The default model uses about 6 GB of disk space and is suitable for most Macs with
16–32 GB of memory. It won a comparison of local models on fidelity and speed (see
[docs/cleanup-model-benchmark.md](docs/cleanup-model-benchmark.md)); for this narrow
task a small, disciplined model cleans better than the large ones.

### 5. Install Stille Post

1. Download the current DMG from
   [GitHub Releases](https://github.com/DanielMuellerIR/stille_post/releases/latest).
2. Open the DMG and drag **Stille Post** to **Applications**.
3. Start Stille Post. Accept the `large-v3-turbo` download (~1.6 GB), then grant
   **Microphone** and **Accessibility** access when macOS asks.

Now place the cursor in a text field, press **⌘⌥D**, speak, and press **⌘⌥D**
again. The text is pasted at the cursor.

Stille Post checks for signed updates at most once per day and never installs one
without permission. Use **“Check for Updates …”** in the menu to check immediately;
after confirmation, Sparkle handles download, replacement, and relaunch.

> **Why are there two model downloads?** `large-v3-turbo` recognizes speech and
> produces the raw transcript. `gemma4:e4b-it-qat` then removes filler words, false
> starts, and repetitions. Both run locally.

## What makes Stille Post different

- **Fast completion:** Whisper transcribes while recording is still in progress.
- **Cleanup without rewriting:** The language model removes speech artifacts but is
  instructed not to shorten, paraphrase, or answer the dictation.
- **Safe fallback:** If the cleaned result looks implausible or the service is
  unavailable, Stille Post uses Whisper's raw transcript.
- **Local and transparent:** Audio always stays on the Mac. History shows the raw
  text, final text, and cleanup endpoint used.
- **Visible recording state:** An overlay, live microphone meter, menu bar icon, and
  distinct sounds show what is happening.
- **No audio buildup:** Successful recordings are deleted immediately; failed ones
  remain available for retranscription.

## How the short wait works

A voice-activity detector splits the recording at natural pauses. Each completed
segment is transcribed immediately while recording continues. After stopping, the
language model cleans up the **complete** transcript exactly once, preserving context
and sentence boundaries. The cleanup model is warmed when recording begins.

## How cleanup is kept in check

1. The system prompt only permits removal of filler words, false starts, stutters,
   and repetitions — no paraphrasing, summarizing, or answering.
2. A word-fidelity check aligns the raw and cleaned words and rejects any adding,
   replacing, translating, or reordering. Allowed are deletions (filler words),
   punctuation, and capitalization, plus tightly bounded repairs of Whisper artifacts
   (compounds split at speech pauses, a single mishearing, a short inflection ending);
   model and version identifiers stay untouchable. The length check remains active as
   an additional safeguard.
3. A failed cleanup also falls back to the raw text.
4. The overlay and history identify backup endpoints and raw-text fallbacks.

Which local models clean most faithfully, and how the check is designed, is
documented with reproducible measurements in
[docs/cleanup-model-benchmark.md](docs/cleanup-model-benchmark.md).

### Which Whisper model?

Two, deliberately — a long model list would only shift the decision onto you:

| Model | Size | When |
|---|---|---|
| `large-v3-turbo` | ~1.6 GB | **Default.** Best mix of quality and speed. |
| `large-v3` | ~3.1 GB | Only if foreign words and jargon have to land better. Slower. |

Smaller models are not offered: worse recognition is not a trade anyone wants, and
turbo is not that big.

## Configuration

All settings are available as a dialog in the menu bar menu under **“Settings …”**.
Underneath lives `~/Library/Application Support/StillePost/config.json`
(created on first launch, menu item “Open configuration file”). The file stays
hand-editable.

The dialog is organized into four tabs, so the common cases never require editing
JSON (the cleanup model shown is the default):

| | |
|:---:|:---:|
| ![General tab](assets/en/settings-general.png) | ![Cleanup tab](assets/en/settings-cleanup.png) |
| *General — recording hotkey & overlay* | *Cleanup — provider, model, context, fallbacks* |
| ![Speech recognition tab](assets/en/settings-speech.png) | ![Recording tab](assets/en/settings-recording.png) |
| *Speech recognition — language & Whisper server* | *Recording — microphone, silence detection & auto-stop* |

The most important switches:

| Section | Field | Meaning |
|---|---|---|
| `hotkey` | `keyCode`, `modifiers` | recording hotkey (default ⌘⌥D). In the General tab, “Record hotkey” records the combination you press — no need to look up key codes |
| `audio` | `inputDeviceUID`, `inputDeviceName` | selected microphone; an empty UID follows the macOS system default. The UI stores the stable CoreAudio UID; the name is only used for a readable display |
| `whisper` | `language` | `"auto"` or fixed, e.g. `"en"`. **Recommendation: Pin it.** With `auto`, Whisper guesses the language per speech segment and silently translates on misdetection |
| `cleanup` | `enabled` | cleanup on/off |
| `cleanup` | `provider` | `"ollama"` (local/own network) or `"openai"` (cloud, text only) |
| `cleanup` | `model` | Ollama model name |
| `cleanup` | `ollamaURL` | Ollama endpoint; may also be another machine on your own network |
| `cleanup` | `keepAlive` | how long Ollama keeps the model in memory after a dictation: `"2h"` (default), `"20m"`, `"0"` (unload at once) or `"-1"` (never unload). Sent with every request — nothing to configure in Ollama |
| `cleanup.remote` | `baseURL`, `model` | OpenAI-compatible provider |
| `cleanup` | `fallbacks` | backup endpoints tried when the primary does not respond (see below) |
| `vad` | `autoStopAfterSilenceSec` | absence auto-stop (0 = off) |
| `ui` | `overlayPosition` | `"mouse"` or `"bottomCenter"` |

### Using an iPhone or another microphone

The **Recording** tab can select any input device reported by macOS directly.
**System Default** continues to follow System Settings → Sound → Input. If an
explicitly selected device disappears, Stille Post does not silently record from a
different microphone; it reports the problem when recording starts.

An iPhone appears as a regular input device through Apple’s Continuity Camera:
lock the iPhone and place it stably near the Mac, then refresh the device list in
Stille Post. A USB connection is more reliable than wireless for long dictations.

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

### Cleanup on another machine (with fallback)

On a RAM-constrained laptop it pays off to hand cleanup to another machine on your own
network — not for a "bigger" model (for this narrow task a small, disciplined model
actually cleans better, see the benchmark), but so the laptop keeps its ~6 GB of RAM
free. The same `gemma4:e4b-it-qat` runs there; the same model stays local as fallback.

**On the serving machine** (it does not need Stille Post):

1. Pull the model: `ollama pull gemma4:e4b-it-qat`
2. Make Ollama listen on the network interface, not just on localhost: set
   `OLLAMA_HOST=0.0.0.0`, or use "Expose Ollama to the network" in the Ollama app.
3. Check from another Mac: `curl http://<ip-of-the-strong-mac>:11434/api/version`

That is all — model, context size and keep-alive are sent by Stille Post with every
request, so there is nothing else to set up in Ollama.

**On every Mac you dictate on:** install Stille Post, then open Settings → Cleanup
and enter the serving machine's endpoint (`http://<ip>:11434`), the model and, if you
like, a keep-alive. `stillepost-cli doctor` checks the whole chain and tells you
whether the endpoint answers and the model is present.

**How long the model stays loaded** is the “Keep loaded” (`keep_alive`) dropdown in
the same tab.
The default of 2 hours is a compromise: dictate again within that window and the
model answers instantly; after that Ollama frees the RAM by itself. "Permanently"
never lets go — the right choice if you have RAM to spare. The wait rarely shows
either way, because Stille Post starts warming the model the moment you press the
hotkey: it loads while you are still speaking.

`fallbacks` lists backup endpoints tried in order when the primary does not respond
(probe timeout 2 s; away from your home network, local Ollama takes over almost
without delay):

```jsonc
"cleanup": {
  "ollamaURL": "http://192.168.1.50:11434",   // another machine on the LAN (primary)
  "model": "gemma4:e4b-it-qat",
  "keepAlive": "2h",                          // "-1" = keep loaded forever
  "fallbacks": [
    { "provider": "ollama", "ollamaURL": "http://127.0.0.1:11434", "model": "gemma4:e4b-it-qat" },
    { "provider": "openai", "remote": { "baseURL": "https://api.example.com/v1", "model": "model-name" } }
  ]
}
```

Only transcribed TEXT travels over your network, never audio — speech recognition
always runs on the machine you dictate on. Which endpoint handled a cleanup is shown
by `stillepost-cli cleanup` and in the history window.

## Scriptable without the GUI

The entire pipeline is available through the CLI with the same logic and configuration:

```bash
stillepost-cli doctor                  # check dependencies (exit code 0 = ready)
stillepost-cli install-model           # fetch the Whisper model (resumable)
stillepost-cli transcribe file.wav     # WAV -> cleaned text on stdout
stillepost-cli transcribe file.wav --raw
stillepost-cli cleanup "raw text"      # cleanup only ("-" reads stdin)
stillepost-cli history list --json
stillepost-cli history clear
stillepost-cli set-cleanup-key         # store API key from stdin in the keychain
```

Diagnostics go to stderr, results to stdout, and failures exit non-zero. The CLI is
inside the app bundle and is not added to your PATH automatically:

```bash
sudo ln -sf /Applications/StillePost.app/Contents/MacOS/stillepost-cli \
            /usr/local/bin/stillepost-cli
```

Without the link, use
`/Applications/StillePost.app/Contents/MacOS/stillepost-cli doctor`. Set
`STILLEPOST_CONFIG` to use an alternative configuration file.

## Development & tests

```bash
git clone https://github.com/DanielMuellerIR/stille_post.git
cd stille_post
scripts/build-app.sh --notarize --install  # notarize, verify, then install atomically
swift test            # unit tests (VAD, WAV, sanity check, history …)
scripts/e2e-test.sh   # end to end: say voice -> Whisper -> cleanup -> assertions
```

The Sparkle feed and release automation are documented in
[`docs/sparkle-release.md`](docs/sparkle-release.md).

## Status

Early, but usable. Planned: A comparison benchmark (quality and latency) against
other local dictation tools and cloud services.
