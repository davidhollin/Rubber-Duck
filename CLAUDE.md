# Rubber Duck (Duck Duck Duck) — Claude Code Context

You are running inside the **Rubber Duck** project (`ideo/Rubber-Duck`). A physical rubber duck companion is watching this session, evaluating your work, and reacting with opinions via voice, animations, and hardware actuators.

## What's happening

- Every prompt you receive and every response you generate is scored on **creativity, soundness, ambition, elegance, and risk**. By default this uses Apple Foundation Models on-device (~3B, free, sub-second). Optionally switches to Anthropic API (Claude Haiku) or Google Gemini Flash for higher-quality scoring.
- The duck widget (a liquid glass SwiftUI duck floating on the desktop) animates based on those scores and speaks gut reactions out loud.
- If you are running in a tmux session named "duck", the user can speak voice commands to you by saying "ducky [command]".

## Hooks active in this project

These fire automatically for your session:

| Hook | Script | Purpose |
|------|--------|---------|
| **UserPromptSubmit** | `scripts/on-user-prompt.sh` | Sends user's prompt to eval service |
| **Stop** | `scripts/on-claude-stop.sh` | Sends your response to eval service |
| **PermissionRequest** | `scripts/on-permission-request.sh` | Blocks and asks user via voice (yes/no). Just proceed normally. |
| **SessionStart** | `plugin/hooks/on-session-start.sh` | Pings `/health` to mark plugin connected |
| **SessionEnd** | `plugin/hooks/on-session-end.sh` | `POST /session-end` to acknowledge |
| **PreCompact** | `plugin/hooks/on-pre-compact.sh` | Triggers Jeopardy thinking melody |
| **PostCompact** | `plugin/hooks/on-post-compact.sh` | Stops thinking melody |
| **StopFailure** | `plugin/hooks/on-stop-failure.sh` | Reacts to API errors |

## Architecture overview

```
Widget (SwiftUI, macOS 26) — owns everything: eval server, speech, serial, duck UI
    |
    HTTP+WebSocket (localhost:3333, MiniServer — zero-dep Network.framework)
    |
    hooks (shell scripts POST to /evaluate, /permission)
    |
You (Claude Code) — this session
    |
    (optional) Hardware duck — Teensy 4.0 or ESP32-S3 via USB serial
```

## Safety rules

- **NEVER use `pkill -f`**. The `-f` flag matches the full command line of all processes and can kill system processes like WindowServer, crashing the entire GUI. Use `killall <name>` or `pkill <name>` (without `-f`) instead.
- **Mac App Store sandbox**: The widget must work under App Sandbox. It may ONLY read/write files inside `~/Library/Application Support/DuckDuckDuck/` (via FileManager container APIs). It must NEVER access `~/.claude/`, `~/Documents/`, `~/Library/Preferences/`, or any path outside its sandbox container. All state (API key, PID, logs, session timestamps) belongs in Application Support. The only way to detect the plugin is via the `/health` HTTP ping — never read Claude's settings files.
- **Network allowlist**: `localhost:3333` (own server), `api.anthropic.com` (Haiku eval), `generativelanguage.googleapis.com` (Gemini eval) only.
- **GPL isolation**: `firmware/rubber_duck_c3/` (ESP32-C3 with AudioTools GPL dep) is gitignored and excluded from this repo. Do not re-add it.

## Dev workflow

| Command | What it does |
|---------|-------------|
| `cd widget && make run` | Release build + icon compile + app bundle + launch |
| `cd widget && make debug` | Debug build + run in terminal (no app bundle) |
| `cd widget && make sandbox` | Release build + App Sandbox entitlements + launch |
| `cd widget && make dmg` | Full distribution: sign + notarize + DMG |
| `cd widget && make plugin-zip` | Export plugin zip for manual upload |
| `./scripts/duck-session` | Launch Claude Code in tmux with duck watching |

- Build stack: swift-tools-version 6.2, macOS 26, Swift 5 language mode (concurrency compat)
- Zero external dependencies — Network.framework for HTTP/WS, CryptoKit for WebSocket SHA-1
- The widget's right-click menu has "Start Claude Session" to launch a terminal Claude Code in tmux.

## Project structure

```
Rubber-Duck/
├── widget/                          SwiftUI macOS app (the duck)
│   ├── Makefile                     Build, bundle, sign, notarize, DMG
│   ├── Package.swift                SPM — single target, zero deps
│   ├── Sources/RubberDuckWidget/    ~43 Swift files
│   ├── Info.plist                   Bundle metadata
│   ├── RubberDuck.entitlements      Developer ID signing
│   ├── Sandbox.entitlements         App Sandbox restrictions
│   ├── Playground/                  LLM eval prompt tuning
│   └── assets/duckIcon.icon         Apple Icon Composer bundle
├── scripts/                         Hook scripts + session launcher
├── plugin/                          Claude Code plugin (hooks.json + scripts)
├── plugin-gemini/                   Gemini CLI integration (experimental)
├── firmware/                        Arduino sketches (8 board variants)
├── hardware/                        PCB (Eagle) + enclosure (3MF/STEP)
├── docs/                            Design docs, research notes
├── Ducky.sch                        Eagle schematic
├── TODO.md                          Tracked backlog
└── README.md                        Public docs
```

## Widget — key files

### Core services
| File | Role |
|------|------|
| `RubberDuckWidgetApp.swift` | `@main` entry, service wiring, lifecycle |
| `DuckCoordinator.swift` | Orchestrates side effects: eval → expression + serial + speech |
| `DuckServer.swift` | HTTP+WS server on `:3333` — all routes, evaluator dispatch, permission gate |
| `MiniServer.swift` | Zero-dep HTTP/1.1 + RFC 6455 WebSocket (Network.framework + CryptoKit) |
| `DuckConfig.swift` | Centralized config — port, API keys, volume, eval provider, listen mode |
| `DuckProtocol.swift` | Shared types: `EvalResult`, `PermissionEvent`, score structs |

### Evaluation
| File | Role |
|------|------|
| `LocalEvaluator.swift` | Apple Foundation Models (~3B on-device). Two-pass V5: scores first, then reaction with sentiment context |
| `ClaudeEvaluator.swift` | Claude Haiku via Anthropic API (URLSession, no SDK) |
| `GeminiEvaluator.swift` | Gemini Flash via Google API |
| `EvalService.swift` | Eval state management — publishes scores, reaction, sentiment |
| `EvalPromptBuilder.swift` | Constructs eval prompts for each provider |
| `LocalEvalTransport.swift` | In-process transport for eval results |
| `WebSocketTransport.swift` | Remote transport for eval results |

### Speech & permissions
| File | Role |
|------|------|
| `SpeechService.swift` | Unified facade: STT, TTS, wake word, permissions |
| `STTEngine.swift` | `SFSpeechRecognizer` + `AVAudioEngine` audio tap |
| `TTSEngine.swift` | macOS `say` subprocess — strips markdown/emoji, pronunciation fixes |
| `WakeWordProcessor.swift` | "ducky" detection for voice commands |
| `PermissionGate.swift` | Actor: FIFO queue of permission requests, blocks until voice/timeout |
| `PermissionVoiceGate.swift` | Yes/no/ordinal voice matching |
| `PermissionClassifier.swift` | Foundation Models classifier for ambiguous input |
| `DuckVoices.swift` | 40+ macOS voices, wildcard mode (score-gated pool → LLM picks tone) |
| `AudioDeviceDiscovery.swift` | CoreAudio device listener — hot-plug Teensy/ESP32 detection |

### Serial / hardware
| File | Role |
|------|------|
| `SerialManager.swift` | Publishes device state, wraps transport |
| `SerialTransport.swift` | USB serial: text protocol + binary audio frames |
| `SerialMicEngine.swift` | Mic input via serial (ESP32-C3 route) |
| `SerialTTSEngine.swift` | TTS output via serial (ESP32-C3 route) |
| `MelodyEngine.swift` | Jeopardy thinking melody during compaction |

### UI
| File | Role |
|------|------|
| `DuckView.swift` | Liquid glass duck face with `.glassEffect()` — eyes, beak, wings |
| `ExpressionEngine.swift` | Maps scores → visual state (eye shape, hue, glow, beak) |
| `DuckTheme.swift` | Design tokens: colors, sizes, spring constants |
| `StatusBarManager.swift` | Menu bar icon + context menu (mode, voice, volume, settings) |
| `HelpView.swift` | In-app help overlay |
| `PreferencesView.swift` | Settings window |
| `SetupChecklistView.swift` | First-run onboarding checklist |

### Other
| File | Role |
|------|------|
| `TmuxBridge.swift` | Injects voice commands into Claude CLI via `tmux send-keys` |
| `UpdateChecker.swift` | Polls GitHub Releases API for app + plugin updates |
| `DuckHelpService.swift` | LLM-powered chatbot for duck questions |
| `LaunchGreeting.swift` | Startup greeting logic |
| `DuckLog.swift` | Logging utilities |
| `ResourceBundle.swift` | Bundle resource access |
| `RecognitionRestartController.swift` | STT watchdog — restarts stuck recognition |
| `AudioBackend.swift` | Audio backend abstraction |
| `WebSocketBroadcaster.swift` | Broadcasts eval state to dashboard clients |

### Resources
| File | Role |
|------|------|
| `Resources/dashboard.html` | Browser dashboard at `localhost:3333` — live eval history |
| `Resources/viewer.html` | Three.js 3D duck viewer at `localhost:3333/viewer` |

## Server routes (DuckServer, localhost:3333)

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/evaluate` | Receive hook payload, dispatch to evaluator |
| POST | `/permission` | Receive permission request, block until voice approval (30s timeout) |
| POST | `/session-end` | Acknowledge session close |
| POST | `/stop-failure` | React to API errors |
| POST | `/compact` | Trigger thinking melody (phase=pre/post) |
| GET | `/health` | Status check |
| GET | `/plugin-check?v=N` | Detect stale plugin version |
| GET | `/` | Dashboard HTML |
| GET | `/viewer` | Three.js 3D viewer |
| WS | `/ws` | WebSocket broadcast for dashboard |

## Eval scoring

**Five dimensions** (all -1.0 to 1.0):
- **creativity** — novelty of approach
- **soundness** — technical rigor
- **ambition** — scope of what's attempted
- **elegance** — craft and clarity
- **risk** — danger level (negative = safe, positive = risky)

**Sentiment formula**: `soundness*0.3 + elegance*0.25 + creativity*0.2 + ambition*0.15 - risk*0.1`

**Two-pass V5 eval** (LocalEvaluator): Score dimensions first (model focuses on numbers), then generate reaction + summary with sentiment context (prevents cheerful reaction on negative scores).

**Providers**: Foundation Models (free, on-device, M3+), Claude Haiku (~$0.001/eval), Gemini Flash (free tier).

## Serial protocol (widget → firmware)

**Text mode** (default, newline-terminated):
```
{U|C},creativity,soundness,ambition,elegance,risk\n   — eval scores
P,1\n                                                  — permission requested
P,0\n                                                  — permission resolved
W,1\n                                                  — wake word detected
W,0\n                                                  — wake word resolved
VOL,0.65\n                                             — volume (0.0-1.0)
```

**Binary audio mode** (between `A,16000,16,1\n` and `A,0\n`):
```
0x01 [len_hi] [len_lo] [PCM bytes...]   — audio frame
0x02 [text ending in \n]                 — control message
```

## Firmware variants

| Variant | Board | Key feature | Folder |
|---------|-------|-------------|--------|
| S3 | Seeed XIAO ESP32-S3 | Reference design | `rubber_duck_s3/` |
| S3 Waveshare | Waveshare ESP32-S3-Zero | Alternate pinout | `rubber_duck_s3_waveshare/` |
| S3 Telyart | Telyart ESP32-S3 | Custom board | `rubber_duck_s3_telyart/` |
| S3 Ducky | Seeed XIAO ESP32-S3 | PDM mic (Adafruit) | `rubber_duck_s3_ducky/` |
| S3 LED | Seeed XIAO ESP32-S3 | WS2812 NeoPixel ring | `rubber_duck_s3_led/` |
| S3 Telyart Crab | Telyart ESP32-S3 | WS2812 + crab animations | `rubber_duck_s3_telyart_crab/` |
| S3 UAC | Seeed XIAO ESP32-S3 | USB Audio Class (experimental) | `rubber_duck_s3_uac/` |
| Teensy 4.0 | Teensy 4.0 | USB Audio (legacy) | `rubber_duck_teensy40/` |

Each firmware variant is an Arduino `.ino` project with modular files: `Config.h` (pins/features), `SerialProtocol.ino`, `ServoControl.ino`, `AudioStream.ino`, `MicCapture.ino`, `StoredAudio.ino`, `Easing.ino`.

## Plugin system

The Claude Code plugin lives in `plugin/`:
- `.claude-plugin/plugin.json` — marketplace metadata (name: `duck-duck-duck`, author: Daniel Deruntz / IDEO)
- `hooks/hooks.json` — 8 hook definitions with timeouts (5-35s)
- `hooks/on-*.sh` — hook scripts identical to `scripts/` but self-contained
- `hooks/duck-env.sh` — finds active widget port from disk

**Install path**: `~/.claude/plugins/cache/duck-duck-duck-marketplace/duck-duck-duck/`  
**Bundled**: Plugin is copied into app's `Contents/Resources/plugin/` at build time.

## Hot-unplug hardware → fallback to local audio

When the USB device (Teensy/ESP32) is unplugged mid-session, the widget detects the change via `AudioDeviceDiscovery.DeviceChangeListener` (CoreAudio property listener) and switches to local Mac mic + speakers. Plugging back in switches back.

## Style notes

- The duck has personality. It's opinionated, occasionally snarky, but ultimately helpful.
- Eval reactions are short (max 10 words) gut reactions like "Now THAT'S what I'm talking about" or "Did a toddler write this?"
- The default TTS voice is "Boing" — intentionally goofy.
- Wildcard voice mode: score narrows voice pool → LLM picks tone from labels → maps to macOS voice.
- ExpressionEngine: No scale/rotation transforms — they break `.glassEffect()` liquid glass refraction. Use eyeHeight, hueShift, glow, beakOpen only.

## Key architecture patterns

- **Zero external dependencies** — Network.framework + CryptoKit only. URLSession for API calls.
- **Actor-based concurrency** — PermissionGate (FIFO queue), LocalEvaluator (inference isolation). Swift 5 language mode for compat.
- **Transport abstraction** — `EvalTransport` protocol (LocalEvalTransport, WebSocketTransport) decouples eval delivery from source.
- **Service-oriented** — DuckCoordinator orchestrates; DuckServer handles routes; SpeechService facades STT/TTS/permissions; SerialManager wraps hardware.
- **Graceful fallback** — Foundation Models unavailable → guides to API key. Service unreachable → hooks return permissive defaults. Teensy unplugged → system audio.

## Licenses

- Software: MIT (IDEO, 2025-2026)
- Hardware: CERN Open Hardware Licence v2 — Permissive
