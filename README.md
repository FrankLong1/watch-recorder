# WristMemo

Press the Apple Watch Ultra Action button, start talking. No taps.

A native watchOS 26 voice memo app built around a WidgetKit **Control**, which is
the only supported way for third-party code to own the Action button.

## Status

Draft, and **running**. Verified on the Apple Watch Ultra 3 simulator
(watchOS 26.5): launches straight into recording, live timer and meter, and
crash recovery reconstructs a valid AAC memo from a hard-killed session.

Not yet on real hardware — the Action button itself has no simulator
equivalent, so press-to-record latency and control assignment still need an
Ultra. Setup and the remaining checklist: [DEVICE_TESTING.md](DEVICE_TESTING.md).

## What happens on a press

1. Action button → the assigned control fires `StartRecordingIntent`.
2. The intent's `supportedModes = .foreground(.immediate)` brings the watch app
   forward at once.
3. The app sees the pending request and starts recording — haptic, red
   indicator, running timer.
4. **Stop** commits the memo; **Cancel** discards it. (Pause still exists
   internally for phone-call interruptions, but is not a button.)
5. The memo is compressed to AAC, stored on the watch, and queued for the iPhone.

Design rationale: [DESIGN.md](DESIGN.md). How the press-to-recording time is
attacked and hidden: [LATENCY.md](LATENCY.md). What Apple does not allow:
[LIMITATIONS.md](LIMITATIONS.md).

## Assigning it to the Action button

On the watch, after installing the app once:

1. **Settings › Action Button**
2. Tap **Action**, choose **Control**
3. Tap the control preview, then pick **WristMemo → Record Voice Memo**
4. Optionally set **Press Duration** to *Short Press*

Or from the iPhone: **Watch app › Action Button**, same choices.

The app must have been launched at least once so the control is registered, and
the microphone permission prompt has to be answered once before a press can
record without interaction.

It also appears in **Control Center** (side button) and can be added to the
**Smart Stack**. On non-Ultra watches, use the Siri phrase "Start a memo in
WristMemo" or add the Shortcuts action.

## Building

```bash
open WristMemo.xcodeproj
```

Signing is already configured (Team `44X645LJ6H`); run the
**WristMemo Watch App** scheme.

Command line, without signing:

```bash
xcodebuild -project WristMemo.xcodeproj -target "WristMemo Watch App" \
  -sdk watchsimulator26.5 -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

### Targets

| Target | Platform | Role |
|---|---|---|
| `WristMemo` | iOS 26 | Companion — receives, lists and plays synced memos |
| `WristMemo Watch App` | watchOS 26 | Recording app |
| `WristMemoControls` | watchOS 26 | Control extension (the Action button entry point) |

### App Group

`group.com.franklong.wristmemo` is only a cross-process fallback for the launch
hand-off, and it is **off by default** — a free/personal Apple ID team cannot
provision App Groups, and the in-process path is what actually carries the
request. With a paid membership, add `CODE_SIGN_ENTITLEMENTS =
Config/Watch{App,Controls}.entitlements` back to the two watch targets.

Bundle identifiers are `com.franklong.wristmemo*` and signing uses Team
`44X645LJ6H`. Change both if you are building under a different account.

## Verifying on hardware

See [DEVICE_TESTING.md](DEVICE_TESTING.md) — it covers the Mac setup that is
already done, the Developer Mode / pairing steps that need your hardware, and
what remains unverified.

## Layout

```
Shared/          intent + hand-off, compiled into both watch targets
WatchControls/   the ControlWidget
WatchApp/        recorder, storage, sync, SwiftUI
iOSApp/          companion library
Config/          Info.plists and entitlements
```
