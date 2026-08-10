# IDEAS

**Date:** 2026-08-05
Companion to [trigger mechanisms](../research/trigger-mechanisms.md), which has
the verified technical constraints. This file is for product direction.

Two sections:
1. **Considered** — thought through, defensible, ready to argue about.
2. **SLOP BRAINSTORM** — unfiltered. Most of it is bad. That's the point.

---

## Considered

### 1. Split the triggers: Action button starts, Double Tap stops

The insight that reorganizes the whole interaction model.

Start and stop have **opposite technical constraints**:

| | Start | Stop |
|---|---|---|
| App state | Nothing on screen | **Our surface is already frontmost** |
| Double Tap viable? | No — needs 2 gestures + pinned widget | **Yes — one gesture** |
| Best trigger | Action button (Ultra) / complication (all) | **Double Tap** |

Double Tap needs a visible surface to target. Starting a recording means nothing
is visible yet, so it fails. But *while recording*, the app or Live Activity is
frontmost by definition — the precondition is satisfied for free.

**The flow:**

```
press Action button  →  recording starts, Live Activity shows
        …speak…
raise wrist, double tap  →  recording stops
```

Why this is better than symmetric triggers:

- **Stopping is the harder ergonomic problem.** You start a recording
  deliberately, with intent, usually with a free hand. You stop it mid-thought,
  possibly walking, possibly holding a coffee, definitely not wanting to look
  down and hunt for a target on a 49mm screen.
- **Double Tap works where tapping fails** — gloves, wet hands, one hand
  occupied, cold fingers.
- **No pinning required.** The Smart Stack pinning prerequisite that makes
  Double Tap unreliable for *starting* is irrelevant for stopping.
- **Zero-glance stop.** Raise, pinch twice, done. You never have to focus your
  eyes on the watch.

**Design details to get right:**

- The Stop button must hold `.handGestureShortcut(.primaryAction)` **only while
  recording** — flip it with `isEnabled:`. Only one element system-wide can be
  primary at a time.
- Stop button must be **above the fold**. If it's scrolled out of view, double
  tap scrolls toward it instead of firing, and the user loses the gesture.
- The system auto-highlights the targeted button's outline. Free affordance —
  design the Stop button assuming it will get an outline treatment.
- Second press of the Action button should *also* stop, for Ultra users who
  prefer symmetry. Both paths, same intent.

**Open risk:** does the Live Activity / recording surface actually stay frontmost
after a wrist drop and re-raise, or does watchOS return to the watch face? If it
returns to the face, this needs the "Return to Last App" behavior configured, or
the Live Activity to be reliably first in the Smart Stack. **Test this on day one
with the Ultra 2** — the whole idea rests on it.

### 2. Spoken routing prefix

Stolen directly from Whisper Memos' "Agents." Say the destination in the first
two seconds and the transcript routes itself:

- "Investment idea — …" → idea inbox
- "Trade observation — …" → position journal, linked to a ticker if one is named
- "Follow up — …" → task with a date

Why it's the only routing model compatible with a one-press trigger: any UI-based
picker reintroduces a decision, a screen, and a tap — which defeats the entire
premise. Voice is the only input channel that's already open.

Prefix should be **stripped from the stored note** but retained as metadata.

### 3. Latency: the start-path budget

"Just press the button" is only solid if the mic is hot before you finish
inhaling. If there's a second of app launch first, you lose the opening words of
the thought — and the opening words are usually the thesis. This is the single
number that decides whether the product feels good.

**Where the time goes** *(estimates — measure, don't trust these)*:

| Stage | Cold | Warm |
|---|---|---|
| Button press → system dispatch | ~0 | ~0 |
| watchOS app launch | **1–3s** | ~200–300ms |
| `AVAudioSession` category set + activate | 100–500ms | ~0 if pre-activated |
| `AVAudioRecorder.prepareToRecord()` (encoder + file) | 50–200ms | ~0 if pre-prepared |
| Mic hardware warm-up → first sample | small | small |

**App launch dominates everything else combined.** Optimizing the audio stack
while eating a cold launch is rearranging deck chairs.

**Three strategies, in order of leverage:**

**A. Don't launch the app.** Best case is the `AppIntent` performing without
foregrounding at all. Open question whether mic access is permitted from a
control/widget extension process — almost certainly not, but it's the first
thing to test because it's worth more than every other optimization combined.

**B. Pre-warm so every press is a warm press.** Keep the audio session
*activated* and an `AVAudioRecorder` *prepared* ahead of the press, so `record()`
is just a file write. Combine with keeping the app resident (Return to App
behavior, extended runtime session) so launch cost is paid once, not per memo.

**C. Make latency negative — the ring buffer.** Keep an `AVAudioEngine` input tap
running into a circular buffer holding the last N seconds. On press, persist the
buffer *retroactively*. You capture words spoken **before** the button press.

C is the only strategy that makes latency stop mattering instead of merely
shrinking it. **But do not ship the 30-second always-on version** — see
[trigger mechanisms §4.1b](../research/trigger-mechanisms.md). The blocker isn't
battery or "privacy optics" (how this was framed in an earlier draft); it's that
retroactive capture persists audio from **before the user decided to record**,
which means third parties who had no signal recording was starting. In two-party
consent jurisdictions that is a criminal exposure, not a UX concern.

If lookback survives measurement, the defensible shape is **3 seconds, gated on
wrist-raise, opt-in, off by default** — enough to catch the first few words,
short enough not to capture a conversation, and with the mic off most of the day.

**Perceptual trick regardless of which you pick:** fire the haptic at the moment
the mic actually goes hot, not on the button press. The user's instinct is to
start speaking on the haptic, which converts residual latency from *lost words*
into a *start cue*. Cheapest win available.

**Measure first.** Instrument a timestamp in the intent's `perform()` and another
on the first captured audio buffer, log the delta, and test cold / warm /
frontmost separately. Everything above is speculation until that number exists.

### 4. The recording is not the product

Just Press Record owns reliable capture at $6.99 one-time. Whisper Memos owns
transcript + routing at $60/year. The capture mechanics are commodity.

The differentiator is what happens *after* the audio lands — tickers resolved,
theses linked across time, observations accreting into something reviewable.
Build capture in a week; spend the real effort downstream.

---

## SLOP BRAINSTORM

Unfiltered. No quality bar. Do not treat any of this as a recommendation.

### Capture mechanics

- Long-press Action button = different intent than short press (if watchOS
  distinguishes — probably doesn't, but check)
- Double press Action button = "urgent / flag this one"
- Start recording, and if you say nothing for 3 seconds, auto-cancel and discard
  so accidental presses don't create garbage
- Silence-triggered auto-stop — stop after 2s of quiet instead of requiring a
  stop gesture at all
- Rolling buffer: always be recording the last 30 seconds, so pressing the button
  captures the thought you *already started saying* before you reached for the
  watch
- Haptic-only confirmation. No screen, ever. One tap = started, two = stopped
- Whisper mode — detect low-volume speech and boost gain for capturing in meetings
- Record on watch, but if iPhone is nearby and unlocked, use the phone mic
  instead for better audio
- Voice activity detection to trim leading/trailing dead air before sync
- "Continue last memo" — press within 60s of stopping and it appends instead of
  creating a new note
- Crown rotation while recording = mark an importance level 1–5
- Cover the screen with your palm to stop (watchOS mute gesture exists — probably
  not exposed)
- Shake to discard the recording you just made
- Complication that shows a live waveform while recording
- Recording continues across app termination and resumes state on relaunch
- Multi-part memos: one press starts, each subsequent press marks a chapter
- If the recording exceeds 5 minutes, auto-chapter it every 60s
- Battery-aware: below 10%, switch to lower bitrate and warn
- Airplane-mode capture with guaranteed later sync (should be default anyway)

### Latency / fast start

**Eliminate the launch**

- `AppIntent` with `openAppWhenRun = false` — start capture without foregrounding
- Perform the intent inside the control/widget extension process (test whether
  mic access is allowed there at all — this is the whole ballgame)
- Ship the intent in the app target vs. a separate extension; measure both, IPC
  might cost more than it saves
- `ForegroundContinuableIntent` — start capture headless, only foreground if the
  system forces it
- Skip SwiftUI entirely on the launch path; no view construction before `record()`

**Keep it warm**

- Pre-activate `AVAudioSession` with the record category so the audio HAL is
  already up when the press lands
- Pre-create `AVAudioRecorder` and call `prepareToRecord()` in advance; press
  just calls `record()`
- Pre-allocate and pre-open the output file handle so there's zero filesystem
  work on the hot path
- `WKExtendedRuntimeSession` to keep the app resident between memos
- Settings → Return to App so the app stays frontmost after use
- Prompt the user to enable Return to App during onboarding
- Keep a "hot spare" prepared recorder ready for the *next* memo immediately
  after finishing one
- Re-prewarm on app background rather than tearing everything down

**Speculative / predictive prewarm**

- Wrist-raise detection → prewarm the audio session speculatively; by the time
  the finger reaches the button it's hot
- Motion signature of reaching for the watch with the other hand as a prewarm cue
- Prewarm on Smart Stack open
- Prewarm on complication tap-down rather than tap-up
- Time-of-day / location habit model — prewarm during your usual capture windows
- Prewarm whenever the screen wakes, tear down after 30s idle

**Negative latency**

- Ring buffer: continuous `AVAudioEngine` input tap into a circular buffer;
  press persists the last N seconds retroactively
- User-configurable lookback: 5s / 15s / 30s
- Only run the ring buffer while the wrist is raised, to cap battery cost
- Only run it for 60s after any wrist raise
- Only run it while the app is frontmost (weakest version, but safest)
- Persistent, visible recording indicator whenever the buffer is live — treat
  the privacy optics as a design requirement, not an afterthought

**Trim the hot path**

- Record raw PCM/WAV first (no encoder init), transcode to compressed later
- Defer the Live Activity until *after* capture is confirmed live
- No SwiftData / CoreData writes before recording starts; metadata after
- No network, no iCloud, no transcription on the hot path — ever
- Lazy-load every subsystem not required to capture a sample
- Skip permission checks on the hot path by caching the granted state
- Don't render a waveform until the first buffer has landed

**Perceptual**

- Haptic fires when the mic actually goes hot, not on the press — turns latency
  into a start cue instead of lost words
- Distinct haptic patterns for "armed" vs "recording"
- Never show a spinner; a spinner tells the user to wait, which is the opposite
  of what you want
- If a cold start is unavoidable, capture to the ring buffer during launch and
  splice

**Measurement**

- Timestamp in `perform()` vs. first audio buffer; log the delta on every memo
- Separate cold / warm / frontmost numbers — they're different products
- Ship the metric in a debug view so regressions are obvious
- Set a hard budget (e.g. 250ms) and treat exceeding it as a bug
- Test on-wrist with the screen off, which is the real starting condition

### Transcription & processing

- On-device Speech framework first pass for instant preview, cloud second pass
  for accuracy
- Show the rough transcript on the watch immediately after stopping, so you can
  confirm it heard you
- Run three models and diff them; flag low-agreement spans as uncertain
- Speaker diarization if you're capturing a conversation, not a monologue
- Ticker extraction: "Apple" / "AAPL" / "the iPhone company" all resolve to AAPL
- Number normalization — "twelve and a half percent" → 12.5%
- Detect and preserve the difference between a claim and a question
- Confidence scoring per sentence; low-confidence gets flagged for review
- Auto-detect language and don't require a setting
- Strip filler words in a "clean" view but keep the verbatim original
- Extract implied dates: "by end of quarter" → an actual date
- Summarize at three lengths: one line, one paragraph, full

### Investment-domain layer

- Every memo auto-tagged with the tickers mentioned
- Thesis threading: memos about the same ticker chain into a timeline
- Price snapshot at capture time, stored with the note — so later you can see
  what the price was when you had the thought
- Automatic "you were right / you were wrong" scoring: compare the thesis to
  subsequent price action
- Conviction tracking — did your language get more or less confident over time?
- Contradiction detection: flag when a new memo contradicts an older thesis on
  the same name
- Weekly digest: "here's what you said about NVDA over the last 6 months"
- Position linking — connect memos to actual holdings via a brokerage import
- Sentiment drift chart per ticker over time
- "Idea graveyard" — ideas you captured and never acted on, with what would have
  happened if you had
- Pre-mortem prompt: after capturing a thesis, ask "what would make this wrong?"
- Earnings-date awareness — surface relevant memos before a company reports
- Tag memos by type: thesis, observation, risk, catalyst, exit criteria
- Detect when you're describing a catalyst and ask for a date
- Sector clustering across memos to reveal unintentional concentration

### Output & routing

- Email delivery (Whisper Memos model) — no app UI needed to start
- Webhook per route so power users wire their own destinations
- Obsidian / markdown file export to a watched folder
- Notion database row per memo
- Append to a single running daily note
- Slack DM to self
- Apple Notes / Reminders as first-class destinations
- Calendar event if a date is detected
- RSS feed of your own memos, private
- Export as a podcast feed so you can re-listen while walking
- Auto-post to a private git repo as commits (timestamped, diffable thesis history)

### Watch UI

- The entire watch app is one button. Nothing else. No list, no settings
- Show only elapsed time while recording, in huge digits, readable at a glance
- Waveform as the only visual feedback
- Last 3 memos on the watch, playable, nothing more
- Watch face complication showing count of unsynced memos
- Live Activity with elapsed time and a single Stop target
- Dark red UI so it doesn't blind you at night
- Show a "heard you" checkmark with the first few transcribed words
- Crown-scrollable list of recent memos with inline playback
- Nothing on the watch at all — capture only, review on phone

### Business model

- $6.99 one-time to undercut nobody and match JPR
- Free capture, paid transcription
- $60/yr matching Whisper Memos
- One-time app purchase + BYO API key for transcription
- Free tier: 10 memos/month
- Lifetime unlock at a high price for the "I hate subscriptions" crowd
- Free for capture + local Speech framework, paid for cloud models and the
  investment domain layer
- Sell the investment layer separately as the actual product

### Wild / probably bad

- Realtime streaming transcription so the text appears as you speak
- AirPods as the mic, watch as the trigger
- Ask a clarifying question back through the speaker after you stop
- Agent that researches the ticker you mentioned and emails you a brief
- Detect that you're driving and switch to a fully eyeless mode
- Heart-rate correlation: were you excited when you had this idea?
- Sleep-adjacent capture for 3am thoughts, extremely dim UI
- Record ambient audio continuously and let you retroactively bookmark
  (privacy nightmare, legally fraught, don't)
- Family sharing of an idea inbox with a partner
- Public "thesis track record" page as a credibility artifact
- Fine-tune on your own memo history so it learns your vocabulary and tickers
- Voice-print lock so only you can trigger recording
- Two-tap Morse-ish encoding on the Action button for different intents
- Ship as a Shortcuts-only utility with no UI whatsoever
- Apple Watch as a dictaphone for an LLM agent loop that acts on your behalf
