# PorchKeep

A free, self-hosted, menu-bar NVR for a battery-powered eufy WiFi doorbell with
no HomeBase. Captures motion / ring events to your iCloud Drive, keeps a rolling
30-day archive, and offers on-demand live view.

> Personal-use, ad-hoc-signed Mac app. Built on top of the open-source
> [`eufy-security-ws`](https://github.com/bropat/eufy-security-ws) bridge and a
> bundled `ffmpeg`.

## What it does

- Sits in the macOS menu bar (no Dock icon).
- Listens for motion / person / ring events from your doorbell via the bridge.
- Spawns `ffmpeg` to record each event into a `.mp4` clip with a `.jpg`
  thumbnail and a `.json` sidecar in `~/Library/Mobile Documents/com~apple~CloudDocs/PorchKeep/clips/`.
- Prunes anything older than the retention window (default 30 days).
- Streams a HLS live view to `AVPlayer` on demand (this wakes the doorbell and
  uses battery, so it auto-stops after the idle timeout).
- Handles iCloud "dataless" placeholders — old clips get re-downloaded before
  playback.

## What it does not do

- Continuous 24/7 recording. The doorbell is battery-powered and physically
  cannot stream continuously.
- ONVIF/RTSP. There is no HomeBase, so the doorbell only speaks eufy's P2P
  protocol.
- Push notifications to your phone (the eufy app still does that).

## Requirements

- macOS 14 or later
- Apple silicon or Intel
- A working `node` (18+) and `ffmpeg` on `PATH` at build time — both get copied
  into the `.app` bundle so they don't need to be installed at runtime.
- An eufy account (preferably a *dedicated* one — see Setup) with the doorbell
  shared into it as a Member or Admin.

## Build

```sh
# 1. install eufy-security-ws + ffmpeg + node into Resources/
./scripts/install-bridge.sh

# 2. compile and package the .app
./scripts/build-app.sh

# 3. drag build/PorchKeep.app to /Applications and open it
open build/PorchKeep.app
```

First launch may need a right-click → Open (or an approval in System Settings →
Privacy & Security), because the app is ad-hoc-signed.

## Setup

A first-run wizard walks you through:

1. **Use a dedicated eufy account** — sign the bridge in with a different
   account from the one your phone uses, otherwise your phone session gets
   bumped. Share the doorbell to that account from the main account.
2. **Credentials + country** — saved in your macOS Keychain.
3. **2FA / captcha** — handled live; the wizard surfaces the captcha image and
   the verification code input.
4. **Doorbell discovery** — pick the doorbell once the bridge sees your devices.
5. **Archive + retention** — confirm the iCloud path and pick a retention
   window (7–90 days).
6. **Launch at login** — optional.

## Data layout

```
~/Library/Mobile Documents/com~apple~CloudDocs/PorchKeep/clips/
    event_2026-05-17T12-34-56-789Z_motion.mp4
    event_2026-05-17T12-34-56-789Z_motion.jpg
    event_2026-05-17T12-34-56-789Z_motion.json
    …

~/Library/Application Support/PorchKeep/
    eufy/                   ← bridge persistent dir (token cache, config)
    logs/porchkeep.log
```

## Troubleshooting

- **Bridge keeps reconnecting** — view the log (menu → View log…). eufy
  sometimes ships a firmware update that breaks the reverse-engineered client;
  upgrade `eufy-security-ws` (`./scripts/install-bridge.sh` after bumping the
  pinned version in `Resources/bridge/package.json`).
- **No events** — the doorbell only emits while it's awake. Walk in front of
  it. The bridge log line `motion detected` is your signal.
- **Captcha keeps coming back** — confirm the bridge's `persistentDir`
  (`~/Library/Application Support/PorchKeep/eufy/`) is writable; that's where
  the token is cached so 2FA doesn't fire on every launch.

## Credits

See `CREDITS`.
