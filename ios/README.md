# Scarlet Talk — native iOS app (v1)

A tiny native app for the one thing Safari does worst: **live voice**.
The whole point is a proper `AVAudioSession` so the conversation flows
continuously — survives notifications, screen lock, route changes, and the
Action Button — none of which a web app can do.

## Architecture (deliberately thin)

Scarlet's brain stays 100% server-side. The app is only a **voice pipe + a
few screens**, reusing the servers we already run:

- **Unlock** → `POST app-api?op=unlock {code}` → device token (stored in the
  Keychain). Same tokens the web app mints; nothing new server-side.
- **Start a call** → `POST eleven-session` → signed ElevenLabs WebSocket URL
  for our agent. Identical to the web app.
- **Audio** → native `AVAudioEngine`: mic tap → 16 kHz mono PCM16 → base64
  `user_audio_chunk`; incoming `audio` events → `AVAudioPlayerNode`. Same
  ElevenLabs conversational protocol the web client speaks
  (`conversation_initiation_client_data`, `user_audio_chunk`, `audio`,
  `interruption`, `ping`/`pong`, `client_tool_call`).
- **Tools** → `client_tool_call` → `POST realtime-session?tool=NAME` (the
  existing authorized proxy) → `client_tool_result`. Zero new tool code.

Because the brain, tools, memory, drafting, and voice config all live on the
server, this app never needs to change when Scarlet gains a new skill.

## Why native fixes the flow bugs

- `AVAudioSession(.playAndRecord, mode: .voiceChat)` + `UIBackgroundModes:
  audio` → she keeps talking with the screen locked and through interruptions.
- `AVAudioSession.interruptionNotification` → we pause on a phone call /
  Siri and **resume cleanly** after, instead of dying.
- Real mic lifecycle → the mic is released the instant a call ends; no
  "still listening after close".
- The Action Button opens the app **directly** (no Safari, no landing page,
  no tap-anywhere fallback). Optional `AppIntent` adds "Hey Siri, talk to
  Scarlet".

## Build & ship — all in the cloud, nothing on Ido's Mac

GitHub-hosted macOS runners have Xcode preinstalled, so we build in CI:

1. `xcodegen` turns `project.yml` into the Xcode project.
2. `xcodebuild -archive` + export with **automatic signing** via an **App
   Store Connect API key** (Ido generates it once; stored as CI secrets
   `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`).
3. Upload to **TestFlight**; Ido installs on his iPhone from the TestFlight
   app. 90-day builds, no weekly re-signing.

See `.github/workflows/ios.yml` (added when the ASC key exists).

## Status

Scaffold committed. Audio engine + WS protocol are written against the
protocol we already implemented in JS; first CI build is the compile/tune
pass. Blocked only on Ido's Apple Developer account + ASC API key.
