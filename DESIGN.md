# Design

## The experience

```
Action button  ──▶  Control  ──▶  App Intent  ──▶  watch app foregrounds
                                                          │
                                                          ▼
                                          recording starts, haptic fires
                                                          │
                                    ┌─────────────────────┴─────────────┐
                                    ▼                                   ▼
                              Stop & Save                            Cancel
                                    │                                   │
                          compress → store → sync                   discard
```

One press. No taps. The first frame the user sees is already recording.

## Why this architecture

### Controls, not a URL scheme or a Shortcut

watchOS 26 is the first release where third-party code can own the Action
button, and Controls are the mechanism. A `ControlWidget` in a watch extension
appears in Settings › Action Button, in Control Center, and in the Smart Stack.
There is no other supported API for the Action button — the pre-26 route was a
Shortcuts shortcut, which added a launch hop and a visible Shortcuts UI.

`ControlWidgetButton` rather than `ControlWidgetToggle`: a toggle would have to
report live recording state from the extension's process, which cannot observe
the app's audio session. A button models "start a new memo" honestly, and
stopping belongs in the app where the recording lives.

`StaticControlConfiguration` because the control has nothing to configure.
`AppIntentControlConfiguration` is the upgrade path if per-control options are
ever wanted (quality, destination folder).

### App Intents are required, and a custom one is needed

Controls act through App Intents — there is no closure-based alternative. The
custom intent, `StartRecordingIntent`, does almost nothing:

```swift
static let supportedModes: IntentModes = .foreground(.immediate)
```

`supportedModes` is the watchOS 26 replacement for `openAppWhenRun`, which is
now deprecated. `.immediate` foregrounds the app the instant the button is
pressed instead of waiting for `perform()` to return — that difference is most
of the "instantaneous" feel.

The intent does **not** record. It cannot: watchOS only lets a foreground app
open the microphone. So its job is to bring the app forward and leave a marker.

### Not `AudioRecordingIntent`

`AudioRecordingIntent` exists (watchOS 11+) and looks like the obvious fit, but
Apple's documentation is explicit:

> In iOS, iPadOS, and watchOS, when you adopt the `AudioRecordingIntent`
> protocol, you must start a Live Activity when you begin the audio recording
> and keep it active as long as you record audio. If you don't start a Live
> Activity, the audio recording stops.

A watchOS app cannot originate a Live Activity, so adopting that protocol would
guarantee the recording stops. It is designed for controlling a recording that
is *already* running — pausing from a Live Activity, for example. Plain
`AppIntent` + foreground mode is correct here.

### AVFoundation, in two stages

`AVAudioRecorder` is the right recorder — `AVAudioEngine` would mean hand-rolling
file writing for no benefit, and the WatchKit recorder UI is long deprecated.

The format choice is the interesting part:

| Stage | Format | Why |
|---|---|---|
| Capture | 16-bit PCM in CAF | No trailing index or `moov` atom, so a file left by a killed process is still fully decodable |
| Stored | AAC `.m4a`, 32 kbit/s mono | ~10× smaller — matters for watch storage and for `transferFile` speed |

Compression happens once, at stop. Any capture found at launch that was never
compressed is treated as a crash and recovered into a memo. That is what makes
"save reliably even if interrupted" true rather than aspirational: the bytes are
on disk in a decodable format the whole time.

### Navigation

There is none. `RootView` switches on permission state, then on recording phase.
A `NavigationStack` push would animate, and when the app is launched by the
Action button the recording UI has to be the first thing drawn — not the second.

### Hand-off between processes

The system decides which process performs an intent, so the request is written
two ways and both converge on one flag:

1. **In-process** — `.foreground(.immediate)` performs the intent inside the app,
   so a `NotificationCenter` post reaches `RecorderModel` directly. This is the
   path that runs in practice.
2. **App Group timestamp** — read during start-up, for the case where the intent
   ran elsewhere (Shortcuts) and the app launched afterwards. Requests older
   than 20 seconds are ignored so opening the app later from the app grid never
   starts a surprise recording.

The App Group is a fallback, not a requirement. Drop the entitlement and the app
still works.

## Files

```
Shared/            in both the watch app and the control extension
  SharedConfig            identifiers
  RecordingLaunchRequest  the hand-off channel
  StartRecordingIntent    the intent behind the control

WatchControls/     the control extension
  ControlsBundle          @main WidgetBundle
  StartRecordingControl   ControlWidget → ControlWidgetButton

WatchApp/
  RecorderModel           state machine: permission, phase, interruptions, battery
  RecordingEngine         AVAudioRecorder + watch audio session
  AudioCompressor         PCM → AAC, off the main actor
  MemoStore               disk layout, index, crash recovery
  WatchSyncClient         WCSession.transferFile with retry
  Views/                  RootView, RecordingView, HomeView, PermissionView

iOSApp/            companion: receives, lists and plays synced memos
```

## State machine

```
idle ──startRecording()──▶ starting ──▶ recording ⇄ paused
                              │             │         │
                              │             └─stop────┤
                              ▼                       ▼
                           failed                  saving ──▶ saved ──▶ idle
                                                      ▲
                        interruption / battery ≤5% ───┘
```

Interruptions pause rather than stop, so a short Siri invocation doesn't split
a memo in two. If the microphone can't be reclaimed, whatever was captured is
saved instead of discarded.

## Permission

`AVAudioApplication.requestRecordPermission` (watchOS 10+, replacing the
deprecated `AVAudioSession.requestRecordPermission`). The prompt is never shown
pre-emptively at launch — it appears the first time the user actually asks for a
memo, so the request has context. If the user was mid-request when the prompt
appeared, the recording starts the moment they allow it.
