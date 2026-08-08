# Design

## The experience

```
        ┌─────────────────────┐              ┌─────────────────────┐
        │                     │   press ──▶  │                     │
        │       READY         │              │     RECORDING       │
        │       (grey)        │  ◀── press   │       (red)         │
        │                     │              │                     │
        └─────────────────────┘              └─────────────────────┘
                  ▲                                     │
                  └──── compress → store → sync ────────┘
                              (invisible)

  start = Action button · tap READY
  stop  = Double Tap · tap screen · wrist-down timeout · exit app
```

**The app is one button the size of the screen.** Grey READY starts, red
RECORDING stops. The Action Button is launch-or-start only: it starts from idle
and does nothing during a live memo. Double Tap only stops; lowering the wrist
for eight seconds or exiting the app stops an abandoned capture. There is no
timer, meter, cancel, confirmation, list, transcript, settings screen or
navigation — every one of those was removed rather than never built. What is
left is the only thing the user has to do: decide when to start talking and when
to stop.

Everything a memo needs afterwards happens without them, and *while they are
already recording the next one*: a stop returns to grey immediately and the
compression, the transfer to the phone, the upload and the eventual deletion all
run behind the screen. Nothing about a finished memo is ever waited on.

**Red means bytes are hitting the disk.** It is driven by the `.recording`
phase, which the model enters only once `AVAudioRecorder` is actually writing —
so the couple of hundred milliseconds an audio session takes to activate are
grey, not red. The one haptic that means "speak" fires on that same transition.

Haptics have exactly two meanings:

| | |
|---|---|
| microphone open, speak | `.start` — same instant the screen turns red |
| recording ended, for any reason | `.stop` |

Warnings, save receipts, and failures are intentionally silent haptically; they
remain visible on screen or in logs. A person should only have to learn “speak”
and “finished.”

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

There is none, and now there is not even a second view to navigate to.
`RootView` renders `RecordScreen` unconditionally; recording is a colour, not a
destination. This started as a latency argument — a `NavigationStack` push
animates, and an Action-button launch has to draw the recording state as its
first frame — and ended as the whole design.

### What was removed, and why each one had to go

Every item here existed and worked. They were removed because each one asks the
user to manage something that manages itself, and together they turned a capture
appliance into an app.

| Removed | Why |
|---|---|
| Memo list on the watch | A list implies something to do with it. The useful artifact is the transcript, in Postgres; playback and history belong on the phone, which has the screen for them. |
| Swipe-to-delete | Deletes the sole copy of a thought, from the smallest target on the smallest screen. Retention deletes it correctly on its own. |
| Save confirmation (Delete / Done) | Asked a keep-or-discard question about a memo that was already on disk. The answer was always Done. |
| `Saving…` | Made the user wait on compression to start their next thought — the exact moment they are most likely to have one. |
| Cancel / discard | The one control that could destroy a recording, sitting next to the one that saves it. An unwanted memo costs a transcription; a lost one costs the thought. |
| Elapsed timer | Encourages watching the watch while talking to it. The duration cap ends runaway capture safely. |
| Level meter | Decoration. It confirms the microphone works, which the red screen already promises. |
| Auto-stop settings toggle | A setting on a device with no room for settings. Silence auto-stop is now simply on. |
| Permission screen | A prompt with no context. The first press asks for the microphone, which is where the request belongs. |

What survived the cut is the list of things that end a recording *without* the
user: silence, the duration cap, a critical battery, and a lost microphone.
Those are the real interface, and they are all haptic.

### Memos delete themselves

Neither device is long-term storage for audio, and neither deletes anything
that has not provably moved on. `Retention` holds the whole rule:

| Device | Deletes when | Never deletes |
|---|---|---|
| Watch | 24 h after the **phone** took delivery | anything not `.synced` |
| Phone | 24 h after the **ingest service** returned `204 No Content` | anything not `.uploaded` |

The window is measured from the hand-off, not from when the memo was recorded,
so a memo that syncs three days late still gets its full day. A missing
timestamp means "has not moved on" and never expires — which is what makes a
week with no network safe: nothing is uploaded, so nothing is deleted, on
either device.

Because each hop only deletes behind a copy that already exists further along,
at least one device holds every memo until the transcript exists.

The watch's `transferFile` completion is not the first hand-off. It only says
WatchConnectivity has finished with its inbox. The phone first atomically
commits the audio and sidecar, then queues a UUID-only `transferUserInfo`
receipt back to the watch. Only that receipt marks a memo `.synced` and starts
watch retention. Content still travels one way; status travels both ways.

The sweep runs on launch, on returning to the foreground, and on the watch's
background refresh — watchOS will not reliably fire a timer for this, and a
sweep is cheap and idempotent.

### Hand-off between processes

`.foreground(.immediate)` means the system performs the intent inside the app's
own process, so the hand-off is a plain in-process latch: `perform()` sets a
flag and posts a notification, and `RecorderModel` reads the flag in `init`.

It is a latch rather than only a notification because ordering is not
guaranteed — the intent can run before `RecorderModel` exists, and a
notification posted then would be dropped. A flag set before and read after
works either way; the notification just makes an already-running app react
immediately instead of at the next scene-phase change.

An earlier version also wrote the request to an App Group container as a
"cross-process fallback". That was cargo cult: the entitlement is not enabled,
and `UserDefaults(suiteName:)` silently vends a store inside the app's own
container when it isn't, so the fallback was the in-process path wearing a
disguise. Deleted.

## Files

```
src/swift_app/
  Shared/                 code compiled into more than one Apple target
    Capture/               launch latch + Control intent
    Media/                 duration inspection + PCM → AAC conversion
    Policy/                retention rules
    Transfer/              shared delivery records
    Support/               identifiers, formatting, and logging
  WatchApp/
    App/                   app lifecycle and shortcuts
    Capture/               recorder state, engine, and capture format
    Completion/            haptics and silence stopping
    Storage/               memo disk layout, index, and recovery
    Transfer/              WatchConnectivity hand-off
    UI/                    bootstrap + the single record screen
    Diagnostics/           time-to-first-sample instrumentation
  iOSApp/                  companion app, library, and ingest client
  WatchControls/Widgets/   ControlWidget and complication extension
  Tests/                   unit and UI test bundles
```

## State machine

```
              ┌──────────────── stop() ◀──── screen / Double Tap / wrist-down
              │                              exit / silence / 10 min cap
              ▼                              battery ≤5% / mic lost
   idle ──▶ starting ──▶ recording ⇄ paused
   grey      grey          RED       grey        interruption
     ▲                                            (call, Siri)
     └── on failure to start
```

Four states, and only one of them is red. The machine covers the microphone and
nothing else: there is no `saving` or `saved`, because `stop()` returns to
`idle` synchronously and hands the commit to a task that owns everything it
needs. Two memos can be compressing while a third records.

Failures are not a state. A compressor that gives up posts a `notice` — one
word, three seconds, over the grey — which is skipped entirely if a recording is
already underway, so a dead memo can never interrupt a live one.

`paused` is grey on purpose. A call has taken the microphone, nothing is being
written, and red would be a lie. Interruptions pause rather than stop, so a
short Siri invocation doesn't split a memo in two; if the microphone can't be
reclaimed, whatever was captured is saved rather than discarded.

## Permission

`AVAudioApplication.requestRecordPermission` (watchOS 10+, replacing the
deprecated `AVAudioSession.requestRecordPermission`). The prompt is never shown
pre-emptively at launch — it appears the first time the user actually asks for a
memo, so the request has context. If the user was mid-request when the prompt
appeared, the recording starts the moment they allow it.

There is no permission screen. An undetermined microphone looks exactly like a
ready one, because the first press is what asks for it. A *denied* microphone is
the one thing the screen has to spell out — `MIC OFF / ALLOW IN SETTINGS` —
since no amount of pressing can fix it from here.
