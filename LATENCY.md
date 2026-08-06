# Fighting latency

The demo is one thing: press the Action button, be recording. Everything in this
file serves that.

## Where the time actually goes

```
  press ──▶ system resolves control ──▶ app process launches ──▶ SwiftUI comes up
                                                                       │
                                        audio session activates ◀───────┤
                                                                       │
                                        recorder prepares ◀────────────┤
                                                                       ▼
                                                              first sample on disk
```

Split into what the app can and cannot touch:

| Segment | Who controls it | Rough share |
|---|---|---|
| Press → process exec | **System.** Only influenceable by staying resident. | Dominant on a cold launch |
| Process exec → app code running | System (dyld, Swift runtime, SwiftUI) | Large |
| App code → session active | **App** | ~100–500 ms if done badly, near-free if overlapped |
| Session active → `record()` returns | **App** | Small once pre-armed |

The uncomfortable conclusion: **most of the latency is launch, and the biggest
lever is not launching at all** — being warm already.

## What is implemented

### 1. Start from `init`, not from a view

`RecorderModel.init` runs while the App struct is being built, before SwiftUI
lays out a single view. The launch request is claimed there and recording
starts there. Doing it in `RootView.task` — the obvious place — costs a whole
frame plus view construction first.

Side benefit: the recording UI is the **first frame drawn**, so there is no
visible flash of the home screen.

### 2. Overlap session activation with launch

`AVAudioSession.activate(options:completionHandler:)` is fired synchronously
from `init`, not wrapped in a `Task`. During launch the main actor is saturated
bringing SwiftUI up, so anything scheduled with `Task` queues *behind* it.
Calling the completion-handler API directly gets the request in flight
immediately, and the completion lands the moment the actor frees up.

Measured in the simulator: activation requested at 4969 ms, `didFinishLaunching`
at 10541 ms, session active at 11268 ms. The request was in flight ~5.5 seconds
before launch finished. Serially it would have started only after.

Because a speculative early activation can legitimately fail (app not frontmost
yet), a failure is retried once at record time rather than failing the memo.

### 3. Category configured early, activation deferred

Apple's guidance is explicit: configure the session as early as possible,
because once it is activated it is too late, and changing category mid-flight is
expensive. So `setCategory(.record)` happens in `init`; activation is separate
because activating lights the microphone indicator.

### 4. Pre-arm the recorder while idle

When the app is foreground and idle it builds the *next* `AVAudioRecorder` and
calls `prepareToRecord()`, which does the file creation and encoder setup up
front. A press then costs little more than `record()`.

### 5. Nothing slow on the hot path

This was the biggest self-inflicted wound. The original `bootstrap()` did, in
order: load the memo index, activate WatchConnectivity, **transcode any orphaned
capture**, and only then handle the launch request. A single recovered memo
could put a multi-second transcode between the button press and the microphone
opening.

Now everything non-essential runs *after* recording is underway. Recovery has to
exclude the in-flight capture, or it would eat the file being recorded into.

### 6. Stay warm: complication + background refresh

Apple's documented behaviour:

- Apps in the **Dock** are kept in memory.
- A **complication on the active face** tells the system to keep the app in a
  ready-to-launch state — it tries to keep it resident.
- **Background refresh** wakes the app periodically; the budget is roughly one
  wake per hour, shared across Dock apps.

So the project ships an `accessoryCircular` / `accessoryCorner` complication
(`RecordComplication`) and schedules a refresh every 45 minutes. Neither is a
guarantee — they are nudges that make a warm launch more likely.

**For the demo, this is the single highest-value action:** put the complication
on the active watch face and the app in the Dock.

## Hiding what is left

Perceived latency is not measured latency. These are cheap and effective:

### Implemented

- **Haptic before confirmation.** `Haptics.recordingStarted()` fires when the
  attempt begins, not when `record()` returns. The haptic is the user's
  acknowledgement that the press registered; withholding it until the microphone
  is confirmed makes the whole interaction feel slower than it is. A failure
  haptic follows if it does not work out.
- **Optimistic UI.** The recording chrome — red dot, timer, meter — renders
  during `.starting`, so the screen says "recording" the instant it appears. The
  timer itself only counts from the real audio start, so the *number* stays
  honest even though the chrome is eager.
- **No navigation animation.** No `NavigationStack` push into the recording
  screen; a transition would add perceived delay on top of real delay.
- **Fixed-width digits** so the timer does not jitter, which reads as smoother.

### Worth trying

- **A short rising tone** on start. Audio feedback is perceived earlier than
  visual and masks a gap well. Costs a speaker route, so it may fight the
  recording — test before adopting.
- **Pre-rendered first frame.** watchOS snapshots apps for the Dock. If the
  snapshot showed the recording screen, the visual transition would be instant
  even while the process is still coming up.
- **Progressive disclosure.** Draw the dot and timer first, defer the meter for
  a frame or two. Less work before the first frame.
- **Deliberate honesty at the edge.** If start ever exceeds ~1 s, showing a
  distinct "starting…" state beats a frozen fake timer.

## Ideas considered and rejected

| Idea | Why not |
|---|---|
| Record from the background so no launch is needed | watchOS only opens the microphone for a foreground app. Hard block. |
| `AudioRecordingIntent` to record from the control | Requires an active Live Activity, which a watch app cannot originate. Recording would stop. |
| Keep the session activated while idle | Lights the microphone indicator permanently. Misleading, and a privacy smell. |
| `WKExtendedRuntimeSession` to stay alive | No audio-recording session type; the types that exist are invalidated when the app backgrounds. |
| Pre-roll buffer so audio predates the press | Nothing is running before launch. Cannot capture what was never recorded. |
| Lower sample rate for faster encoder setup | Setup cost is dominated by file creation, already handled by pre-arming. Would cost quality for nothing. |

## Measuring it

In-process instrumentation cannot see the press — the process does not exist
yet. `Latency` marks time since process exec (via `sysctl`), which is the
closest observable proxy:

```
[latency] model init
[latency] activation requested
[latency] didFinishLaunching
[latency] session active
[latency] start requested
[latency] first sample
```

On device:

```bash
log stream --predicate 'subsystem == "com.franklong.wristmemo"'
```

In DEBUG the recording screen also prints `NNNms to first sample`.

**Two cautions.**

1. All numbers so far are from the **simulator, Debug**. They are inflated and
   noisy — cold launches measured 1.9 s, 2.2 s and 5.3 s to `model init` on
   identical runs. Treat the *deltas* as signal and the absolutes as garbage.
   Release on device will be far quicker.
2. For the real press-to-recording number, instrument nothing: **film it**. A
   240 fps slow-motion video of thumb-on-button to red-dot-on-screen gives the
   number the demo is actually judged on, including the system launch the app
   cannot see.

## If it still feels slow on device

In rough order of expected payoff:

1. Build **Release**, not Debug. Debug launches are dramatically slower.
2. Put the complication on the active face and the app in the Dock — turns cold
   launches into warm ones.
3. Check whether the app is being jettisoned between presses; if so, the warmth
   levers are not working and nothing else will save it.
4. Trim launch work further — the root view could branch to a bare recording
   view with no `List` types referenced at all on the recording path.
5. Consider dropping the level meter from the first frame.
