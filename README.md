# Luna

Use an old iMac as a wireless extended display for a modern Mac — a
from-scratch, software-only replacement for Luna Display. Written for the
iMac Retina 5K (Late 2014), which has no Target Display Mode; it works the
same on other Intel iMacs (e.g. the Late 2015 models).

I made most of this with [Claude Code](https://claude.com/claude-code):
I described what I wanted my old iMac to do, and Claude designed, wrote,
and debugged the app with me.

## Install (no build needed)

Download both apps from the
[latest release](https://github.com/siavosh87/luna-display/releases/latest):

- **LunaReceiver** goes on the Mac that becomes the display.
- **LunaSender** goes on the Mac whose desktop you want to extend.

They are notarized, so they open normally — unzip, move to Applications,
launch, then jump to [Setup](#setup). Building from source is optional.

## How it works

1. **LunaSender** (the Mac whose display is extended, menu bar app) creates
   a *true Retina 5K virtual display* — 2560×1440 points backed by
   5120×2880 pixels — using the same private CoreGraphics API the
   commercial tools use. No dongle needed.
2. ScreenCaptureKit captures it at 60 fps; the hardware encoder compresses
   to low-latency H.264 at a 3840×2160 stream size.
3. **LunaReceiver** (the iMac, fullscreen app) advertises itself over
   Bonjour, receives the stream over TCP, and feeds compressed samples
   straight into `AVSampleBufferDisplayLayer` for hardware decode.

Why 4K on the wire when the display is 5K? A 2014/2015-era iMac can only
H.264-decode up to ~4K. Rendering the UI at 5K, downscaling to 4K for
transport, and upscaling back to the panel is the same trick macOS "scaled"
resolutions use — text stays much sharper than a non-Retina stream.

## Requirements

- **Sender**: macOS 13 or newer (Apple Silicon or Intel; needs
  ScreenCaptureKit and a hardware H.264 encoder — any Apple Silicon
  MacBook, M1 through M4 and later, qualifies).
- **Receiver**: macOS 10.15 Catalina or newer, Apple Silicon or Intel.
  The app is a universal binary; a Late 2014 or Late 2015 iMac on its
  stock maximum macOS works.
- Both Macs on the same network.

## Build from source (optional)

Double-click **`build.command`** — it opens a Terminal window and runs the
build for you. (If macOS blocks a downloaded copy the first time,
right-click it and choose *Open*, or approve it under System Settings →
Privacy & Security.) The equivalent by hand:

```sh
./make-apps.sh
```

Needs Xcode (or the command line tools with Swift 5.9+) — macOS offers to
install the command line tools on first use. Produces
`dist/LunaSender.app` and `dist/LunaReceiver.app`, both universal. When a
"Developer ID Application" identity exists in the login keychain the apps
are signed with it (and notarized when a `notarytool` keychain profile
named `luna` exists — see [`signing/README.md`](signing/README.md));
otherwise they are signed ad-hoc, which works fine for personal use. If a
copy of the sender already lives in `/Applications`, the fresh build is
deployed there — set `LUNA_NO_DEPLOY=1` to skip that (it kills a running
sender).

## Setup

**On the iMac (once):** copy `LunaReceiver.app` over (AirDrop, USB,
file sharing). A notarized build opens normally; other builds need
right-click → Open the first time (Gatekeeper). It goes fullscreen and
shows "waiting for a sender" with its address. Esc quits.
`LunaReceiver --headless` runs the server without any window.

**On the sender Mac:** launch `LunaSender.app`, click the ☾ menu bar
icon, and pick the iMac under "Receivers on network". The first connection
will trigger the Screen Recording permission prompt — grant it (System
Settings → Privacy & Security → Screen & System Audio Recording), then
connect again.

Both Macs must be on the same network. Wi-Fi works; wired is better. Best:
a Thunderbolt bridge (on a 2014/2015 iMac: TB3→TB2 adapter + TB2 cable) or
an Ethernet cable between them — both show up as regular network
interfaces. The sender automatically probes for a wired path first
(Thunderbolt bridge or Ethernet) and only uses Wi-Fi when no wired link
answers within ~2.5 s. The receiver listens on fixed port 52525, so its
address stays stable across relaunches.

While connected, the ☾ menu's status line shows which link the session
actually uses ("via Thunderbolt Bridge (bridge0)"), and the receiver names
it in its "Connected to …" line. ☾ → **Network Interface** lists every
usable interface; pick one to pin Luna to it — a live session redials the
receiver immediately, and if the receiver can't be reached over the pinned
interface the connection fails with a message in the menu rather than
silently switching. *Automatic* restores the wired-first behavior.

The receiver draws the mouse pointer itself from small position messages,
so the pointer moves without waiting for the video. It needs both apps from
the same build; an older receiver gets the pointer inside the video as before.

Display modes (☾ menu): Retina 5K scaled (default), Retina 4K (bigger UI),
or 2560×1440 non-Retina (lowest bandwidth — try this first on a 1080p or
21.5" iMac, or over a weak Wi-Fi link).

**Windowed mode (receiver):** the receiver normally takes over the whole
iMac screen. Press ⌘⇧F on the iMac (or View → Switch to Windowed Mode) to
drop it into a regular resizable window with the usual traffic-light
buttons — handy for taking screenshots of the streamed content with the
iMac's own keyboard/mouse (⌘⇧3/4/5) without touching the sender. ⌘⇧F
again or Esc returns to fullscreen; nothing changes unless you ask for it.

## Roadmap

- True 5K on the wire: tile the frame into 2–4 independent H.264 streams,
  each within the iMac's decoder limits, reassembled in a Metal layer.
- Adaptive bitrate from send-queue depth.
- Clipboard sync.

## Notes

- `CGVirtualDisplay` is a private API (the same one DeskPad, FluffyDisplay,
  and BetterDisplay use). Fine for personal use; not App Store material.
- macOS may periodically re-ask for the screen-recording permission.
- `LunaSender --selftest` exercises virtual display creation without
  needing any permissions.
- Dev harness (writes PASS/FAIL to a log file, exits 0 on pass):
  `LunaSender --test-disconnect host:port --test-log file` connects,
  streams briefly, then verifies full teardown (`nc -l 52525` is a fine
  mock receiver).
