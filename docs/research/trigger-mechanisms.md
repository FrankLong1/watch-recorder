# Watch Recorder — Trigger Mechanisms & Processing Model

**Status:** research memo, pre-implementation
**Date:** 2026-08-05
**Target:** watchOS 26, Apple Watch Ultra 2 (dev device)

Everything below is either **[verified]** against Apple docs / shipping apps, or
**[inferred]** and flagged as needing on-device confirmation. Don't architect
around an `[inferred]` line without testing it first.

---

## 1. The core problem

A capture app lives or dies on time-to-record. Every trigger below is a
different answer to "how does the user get from wrist-down to recording."
They are not alternatives to choose between — they are **tiers**, and the app
should ship all of them over one shared intent.

---

## 2. Hardware matrix

| Watch | Chip | Action button | Double Tap | Wrist flick |
|---|---|---|---|---|
| Ultra 1 (2022) | S8 | Yes | **No** | **No** |
| Ultra 2 (2023) | S9 | Yes | Yes | Yes |
| Ultra 3 (2025) | S10 | Yes | Yes | Yes |
| Series 9 / 10 / 11 | S9–S11 | No | Yes | Yes |
| SE 3 (2025) | S10 | No | Yes *[inferred]* | Yes *[inferred]* |
| Series 8 and earlier, SE 2 | ≤S8 | No | No | No |

Roughly 90% of Apple Watches in the wild are **not** Ultras. The Action button
is the best interaction but the smallest audience. Plan accordingly.

---

## 3. Triggers

### 3.1 Action button — Ultra only

**Mechanism.** A dedicated physical button on the left side of the 49mm case.
Present on every Ultra since 2022.

**Two integration generations:**

| | Path | UX cost |
|---|---|---|
| watchOS ≤ 25 | Action button → "Shortcut" → user-built Shortcut → your App Intent | User must assemble the Shortcut themselves |
| **watchOS 26** | Ship a `ControlWidget` → appears in Control Center gallery → user assigns directly | One assignment, no Shortcut wrapper |

**Build the `ControlWidget` path.** *[verified]* watchOS 26 added third-party
Control Center controls, and Ultra users can bind them to the Action button.

```swift
struct RecordControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.app.record") {
            ControlWidgetButton(action: ToggleRecordingIntent()) {
                Label("Record", systemImage: "mic.fill")
            }
        }
    }
}
```

**Design rule — steal Apple's semantics.** Every Apple Action button
assignment (Workout, Stopwatch, Waypoint, Backtrack, Dive, Flashlight)
**toggles a session state**. None of them navigate to a screen. So:

- press → start recording
- press again → stop

If the button lands the user on a screen with a decision to make, it's wrong.

**Longevity risk: low.** The Action button has shipped on every Ultra, expanded
across the iPhone line, and watchOS 26 just added developer API for it. Apple
does not ship developer surface for a control it's retiring.

**Bonus tier** *[verified]*: iPhone-only controls appear on the watch and
execute on the phone, even with no watchOS app installed. Not our primary path
(we want standalone watch capture) but it's a free fallback.

---

### 3.2 Double Tap — S9 and later

**Mechanism.** Pinch index finger and thumb twice. Sensed by fusing
accelerometer, gyroscope, and **optical heart sensor blood-flow data** through
an ML model on the Neural Engine. The sensor fusion is why it needs S9+.

> **Read this before anything else in this section.** Double Tap is **not
> bindable to an app**. There is no Settings → Gestures → Double Tap → *Your
> App*, and no Double Tap trigger in Shortcuts. The distinction:
>
> | | Action button | Double Tap |
> |---|---|---|
> | What you get | **Global binding** — you own the trigger | **Contextual targeting** — you own what it hits once already visible |
> | Fires from screen-off | Yes | No |
> | Can launch the app | Yes | **No** |
> | User assigns it to you | Yes, in Settings | **No such setting** |
>
> `.handGestureShortcut(.primaryAction)` means "*of the buttons currently on
> screen, mine is the one the gesture should hit.*" It is a disambiguation API,
> not a binding API. If our surface isn't already showing, the modifier is inert.

**API** *[verified]* — `.handGestureShortcut(_:isEnabled:)`, watchOS 11+,
**SwiftUI only** (no UIKit/WatchKit equivalent):

```swift
Button(intent: ToggleRecordingIntent()) {
    Label(isRecording ? "Stop" : "Record",
          systemImage: isRecording ? "stop.fill" : "mic.fill")
}
.handGestureShortcut(.primaryAction, isEnabled: true)
```

Valid on `Button` and `Toggle`, in an app, a Widget, or a Live Activity.

**Four constraints that shape the UI:** *[verified]*

1. **Only one element at a time** can be `.primaryAction` — not one per view,
   one period. Swap it with `isEnabled:` as state changes.
2. **The control must be on screen.** If scrolled out of view, the double tap
   **scrolls toward it instead of firing**. Record button must be above the fold.
3. **The system draws the affordance.** watchOS auto-highlights the outline of
   the button that will fire. Can't be built or suppressed.
4. **Double tap is the only gesture available to apps.** Pinch, clench,
   double-clench, wrist flick are reserved for AssistiveTouch / the system.

**Where it fires:**

| Context | Works |
|---|---|
| App frontmost | Yes |
| Widget frontmost in Smart Stack | Yes |
| Live Activity in Smart Stack | Yes |
| Screen off / wrist down | No |
| App not running | **No — cannot launch an app** |

**It is a confirm gesture, not a launch gesture.**

**As a START trigger it is weak.** Something must put our surface on screen
first — a crown scroll, or a double tap (the default watch-face assignment).
Realistically:

```
raise wrist → double tap (opens Smart Stack) → double tap (fires widget) → recording
```

Two gestures, plus a **pinned widget** as a prerequisite. Unpinned, Smart Stack
ordering is relevance-driven and non-deterministic — the widget may be third in
the stack and the gesture just scrolls. Pinning must be an explicit first-run
onboarding step, not a tip buried in settings. Even then, this is contingent on
open question #2 below.

**As a STOP trigger it is excellent — and this is the real use.** While
recording, our surface (app or Live Activity) is *already frontmost*, which is
exactly the precondition Double Tap needs. So:

```
raise wrist → double tap → stopped
```

One input, no pinning, no navigation, and no precise finger tap on a 49mm screen
while mid-sentence. It also covers the exact conditions where tapping fails —
wet hands, gloves, holding something, walking.

**Design conclusion: start and stop should use different triggers.**
Action button / complication to start; Double Tap to stop.

**Reliability caveat:** it's a gesture, so it has false negatives a physical
button never has. Gloves, cold hands, loose band all degrade it. Good-enough
tier for non-Ultra owners; not equal to the Action button.

---

### 3.3 Complication / Smart Stack widget — every watch

**Mechanism.** Interactive widget with `Button(intent:)`. Works on all watches,
no chip gate. One look plus one tap.

This is the universal floor. It's what Just Press Record and Whisper Memos both
lead with, and it's the only tier that reaches 100% of the install base.

Widget should show **elapsed duration** while recording and offer stop inline
(JPR does this) — otherwise the user has to open the app to stop, which
destroys the whole value proposition.

---

### 3.4 Siri / App Shortcuts — every watch

**Mechanism.** `AppShortcut` over the same `AppIntent`. Available without the
user building anything in the Shortcuts app.

Hands-free, but requires invocation language and Siri round-trip latency. Ship
it, don't lead with it.

---

### 3.5 What is NOT available

*[verified]* — none of these can be claimed or remapped:

- **Digital Crown hold** — system-reserved for Siri. Can be disabled, cannot be
  reassigned.
- **Side button** (single, double, long press) — Control Center, Apple Pay, SOS.
- **Wrist flick** — watchOS 26 gesture, system-only (dismiss notifications).
- **Raise to Speak** — Siri only.
- **Replacing Siri** with a custom assistant — not possible on watchOS.

There is no way to make a non-Ultra watch expose a remappable physical trigger.

---

## 4. Recording & processing model

### 4.1 Background recording — better than expected

*[inferred, high confidence — verify on device]*

Just Press Record ships **standalone watch recording with unlimited length**,
no iPhone required, and explicitly advertises **"record discreetly in the
background."** Since it's shipping, watchOS clearly permits this.

Working model:

- **Starting** a recording requires a user-initiated foreground trigger.
- **Continuing** works in the background and through wrist-drop.

The restriction is on *starting* silently, not on *continuing*. This means the
HealthKit-workout-session hack (start a fake workout for background runtime) is
**not needed**. Avoid it — App Review is unfriendly to a memo app posing as a
workout app.

**Verify before architecting:** exact `AVAudioSession` category and which
background mode(s) the Info.plist needs.

### 4.1a Can the app just stay resident? — No

*[verified via Apple docs summaries + developer forums; primary docs not directly
readable, so treat specifics as high-but-not-absolute confidence]*

**watchOS does not support continuously resident third-party apps.** This is a
deliberate platform constraint (battery, thermal), not an API gap to work around.

**Lifecycle:**

- Frontmost lasts **~2 minutes** after use, then background, then suspended.
- Duration is governed by **Settings → General → Return to Clock**, with a
  per-app **"Return to App"** override. This is a *user* setting — we can request
  it in onboarding, we cannot control it.
- The watch also suspends processing when the **wrist is face-down**.

**Background execution is limited to four classes:**
`BGAppRefreshTask`, `HKWorkoutSession`, `WKExtendedRuntimeSession`, `URLSession`.

**`WKExtendedRuntimeSession` does not fit this app.** Session types are Self
Care, Mindfulness, Physical Therapy, Smart Alarm. Only Physical Therapy and Smart
Alarm run in the background; the others are foreground-only. Limits are 30 min –
1 hr. There is no voice-recording type. Claiming one is the same category of
misuse as the fake-workout hack and App Review polices the declared use case.
**Don't.**

**The good finding:** watchOS has an explicit **`audio-recording` background
session category**, distinct from background audio *playback*. This is almost
certainly what Just Press Record uses, and it confirms §4.1's background claim is
sanctioned rather than a hack.

**But it solves the wrong problem:**

> A background session keeps us alive **while recording**. It does not make
> **starting** faster. The session can't be held open without an active
> recording, so first-press cold start remains.

**…unless we run the ring buffer** — but see the risk assessment below before
treating this as the answer. Technically: continuous capture into a circular
buffer *is* recording, which sustains the audio-recording session, which keeps
the app resident, which makes every press warm **and** yields negative latency.
Three problems, one mechanism. **The costs are much higher than "battery and
optics," which is how an earlier draft of this doc framed it.** See §4.1b.

**Fragility warning** *[verified — multiple developer reports]*: background audio
on watchOS is unreliable **after interruptions**. An incoming call or competing
audio app can reclaim the session, and background resume frequently fails. Plan
an explicit user re-entry flow; never assume a long unattended recording
survives.

### 4.1b Ring buffer — risk assessment

**Recommendation: do not ship the 30-second always-on version.**

**What it is.** A fixed-size block of RAM written continuously; on reaching the
end it wraps and overwrites the oldest samples. Always holds the last N seconds,
never grows. 30s of 16 kHz mono 16-bit PCM ≈ **1 MB**. Memory is not the problem.

**The mic is always on.** There is no version where it isn't.

| | Ring buffer | Recording |
|---|---|---|
| Mic | **On** | On |
| Samples in RAM | Yes, continuously overwritten | Yes |
| Written to disk | **No** | Yes |

"Always listening, never saving" is a real technical distinction, but **the gap
between the two columns is one line of code.** A bug, a future feature, or a bad
merge converts passive capture into surveillance — a failure mode that is hard to
detect externally and hard to disprove.

**Risk 1 — retroactive capture and consent. This is the serious one.**

In two-party / all-party consent jurisdictions (CA, FL, PA, IL, WA, MA, ~a dozen
US states, much of Europe), recording without every participant's consent is a
**criminal** matter. A ring buffer persists audio from *before the user decided
to record*. The button press is the moment of intent; the preceding N seconds
captured people who had **no signal that recording was about to begin** and no
opportunity to object. Retroactive capture of third-party speech is close to the
precise conduct wiretap statutes target.

The user's own voice is fine. Everyone else in the room is the exposure.

**Risk 2 — App Review.** Continuous mic access draws hard scrutiny, and "it
reduces launch latency" is a weak justification from Apple's side. Treat
rejection as likely, not theoretical.

**Risk 3 — memory disclosure.** The buffer holds ambient audio in RAM. Crash
dumps and logs must explicitly exclude it.

**Risk 4 — trust posture.** Product-specific and possibly decisive: users will
speak proprietary investment theses into this app. An always-on mic is the worst
possible trust position for exactly that audience.

**Defensible middle ground, if lookback is still wanted after measuring:**

- **3 seconds**, not 30 — catches "so, Apple's margins —" without capturing a
  conversation
- **Gated on wrist-raise** — mic off the vast majority of the day
- **Opt-in, off by default**
- Persistent visible indicator; zero the buffer on background/lock
- Never write the buffer to disk unless the button was pressed

**Do this first:** measure cold start. At ~800ms this is all moot. At ~3s, try
pre-warming plus haptic-on-hot before accepting any always-on mic.

### 4.2 Where processing happens

Two shipping reference architectures:

| | Just Press Record | Whisper Memos |
|---|---|---|
| Record | On watch, standalone | On watch / phone |
| Transcribe | **On iPhone**, not watch | **Cloud** — Whisper / ElevenLabs Scribe / Cohere |
| Sync | iCloud Drive | Server-side |
| Deliver | In-app, 30+ languages | **Email** + Notion / Trello / Zapier |
| Price | $6.99 one-time | $60/year |

**Neither transcribes on the watch.** The watch captures; inference happens
elsewhere. Follow this — don't put a model on the wrist.

Proposed flow:

```
Watch: capture audio → local file → sync opportunistically
   ↓ (iCloud Drive or WatchConnectivity)
iPhone: receive → transcribe → structure/enrich
   ↓
Destination: email / webhook / app store
```

The watch app should never block on the phone being present.

---

## 5. Prior art worth stealing

**Just Press Record** ($6.99 one-time) — the capture-reliability benchmark.
Triggers: complication, Action button (via Shortcut), Double Tap (added v50.0),
Siri, widget, URL scheme. Unlimited length, background, iCloud Drive sync,
30+ language transcription on iPhone.

**Whisper Memos** ($60/yr) — the product-shape benchmark. Delivers a formatted
transcript with an AI summary **by email**, which sidesteps building a full
browsing UI.

Its **"Agents"** feature is the single best idea to copy: named automations that
route a memo to different destinations **based on what you say in the first
seconds of the recording**. "Investment idea…" vs "Trade observation…" becomes a
spoken prefix, not a UI decision. This is the only routing model compatible with
a one-press interaction.

**Drafts** — dictation-focused; loops recordings for longer sessions, adds
silence timeouts to work around Siri dictation limits.

---

## 6. Recommended architecture

One intent, four thin adapters. Roughly 150 lines of adapter code over a shared
core.

```
                    ToggleRecordingIntent  (AppIntent)
                              ▲
        ┌─────────────┬───────┴───────┬─────────────────┐
        │             │               │                 │
  ControlWidget   handGesture    Button(intent:)   AppShortcut
  (Action btn)    (Double Tap)   (complication)      (Siri)
    Ultra only      S9+            all watches      all watches
```

Why this matters beyond tidiness: **no single trigger is a point of failure.**
If Apple changed the Action button, we'd lose one adapter, not the product. And
it means the app works on the ~90% of watches that aren't Ultras — which is
required for this to be a business rather than a personal tool.

---

## 7. Open questions — verify on the Ultra 2

1. Exact `AVAudioSession` config + Info.plist background modes for continued
   background recording.
2. Gesture arbitration inside the Smart Stack — when a widget is frontmost,
   does double tap fire the widget's primary action, or scroll to the next
   widget? Docs say it fires the primary action if on screen, but confirm the
   interaction with Smart Stack navigation.
3. Can a `ControlWidget` bound to the Action button **start recording without
   foregrounding the app**, or does it have to launch the app first?
4. Latency, end to end: button press → mic actually capturing. This number
   decides whether the product feels good. Measure it early.
5. Does SE 3 actually support Double Tap? (Affects whether the cheap dev path
   is viable for testing the gesture tier.)
6. Mic quality with wrist rotated away from the mouth — the real usage posture.
7. Can a continuous `AVAudioEngine` input tap (ring buffer) legitimately sustain
   the `audio-recording` background session indefinitely? Battery cost per hour?
8. Does `BGContinuedProcessingTask` (newer API, surfaced in forum discussion)
   apply on watchOS 26 and offer foreground-like background execution? Unverified
   — worth a look.
9. Measured cold vs. warm start delta, and whether the ~2-minute frontmost window
   makes consecutive memos reliably warm.

---

## 8. Strategic note

Recording is not the product. Just Press Record owns "reliable capture" at
$6.99 one-time; Whisper Memos owns "transcript + routing" at $60/year. Both
have the mechanics solved.

The differentiator is the **domain layer** — structured capture where tickers
resolve, theses link over time, and observations accrue into something
reviewable. Build the capture path in about a week using the patterns above,
then spend the real effort on what happens after the audio lands.

---

## Sources

- [Apple — Use the Action button on Apple Watch Ultra](https://support.apple.com/guide/watch/use-the-action-button-apda005904ef/watchos)
- [Apple — Enabling the double-tap gesture](https://developer.apple.com/documentation/watchos-apps/enabling-double-tap)
- [Apple — What's new in watchOS 11 (WWDC24)](https://developer.apple.com/videos/play/wwdc2024/10205/)
- [9to5Mac — watchOS 26 third-party Control Center widgets](https://9to5mac.com/2025/06/05/exclusive-apple-prepping-support-for-third-party-control-center-widgets-in-watchos-26/)
- [Just Press Record](https://apps.apple.com/us/app/just-press-record/id1033342465)
- [Whisper Memos](https://whispermemos.com/)
