# WristMemo

Press the Apple Watch Ultra Action button, start talking. No taps.

A native watchOS 26 voice memo app built around a WidgetKit **Control**, which is
the only supported way for third-party code to own the Action button.

## Status

Draft. Compiles clean against the watchOS 26.5 SDK (Xcode 26.6) with no errors
or warnings. **Not yet run on hardware** — the machine it was built on has no
watchOS simulator runtime installed, so the timing and Action button behaviour
still need a device pass. See [Verifying on hardware](#verifying-on-hardware).

## What happens on a press

1. Action button → the assigned control fires `StartRecordingIntent`.
2. The intent's `supportedModes = .foreground(.immediate)` brings the watch app
   forward at once.
3. The app sees the pending request and starts recording — haptic, red
   indicator, running timer.
4. **Stop & Save** commits the memo; **Cancel** discards it; **Pause** holds.
5. The memo is compressed to AAC, stored on the watch, and queued for the iPhone.

Design rationale: [DESIGN.md](DESIGN.md). What Apple does not allow:
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

Set your team on all three targets, then run the **WristMemo Watch App** scheme.

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

`group.com.wristmemo.shared` is used only as a cross-process fallback for the
launch hand-off. If you would rather not provision it, remove
`CODE_SIGN_ENTITLEMENTS` from the two watch targets — the app still starts
recording via the in-process path.

Bundle identifiers are `com.wristmemo.app*`; change them to your own before
running on a device.

## Verifying on hardware

The parts that need a real Ultra:

- [ ] Control appears under Settings › Action Button
- [ ] Press launches straight into the recording screen
- [ ] Time from press to first audio sample feels instant
- [ ] First-run microphone prompt, then auto-start after granting
- [ ] Recording survives a wrist drop (`WKBackgroundModes: audio`)
- [ ] Incoming call pauses and resumes cleanly
- [ ] Force-quit mid-recording → memo recovered on next launch
- [ ] Memo arrives on the paired iPhone

## Layout

```
Shared/          intent + hand-off, compiled into both watch targets
WatchControls/   the ControlWidget
WatchApp/        recorder, storage, sync, SwiftUI
iOSApp/          companion library
Config/          Info.plists and entitlements
```
