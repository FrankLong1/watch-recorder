# The friction budget

WristMemo is trying to make a useful thought cost almost nothing to keep.

That is broader than launch speed. A memo has failed the product if the user
has to remember an incantation, look down to find a target, wait to know when to
speak, explain where it belongs, repair a clipped first sentence, or wonder
whether it ever arrived.

The product loop is:

```text
thought occurs → intentional action → clear start cue → speak naturally
             → end with no ceremony → trust it is safe → find it in context later
```

The ideal feels like a reflex: **think, press, speak, trust it.**

`LATENCY.md` keeps its historical filename because time-to-first-sample is still
the sharpest technical problem. But it is now the repository's complete friction
model. `AGENTS.md` is the short version of the same north star.

## The watch is a capture appliance, not a memo app

The cleanest way to reduce friction is to remove capability from the wrist.
The watch should do only the work that cannot happen somewhere else or later:

| Must happen on the watch, now | Should happen downstream, later |
|---|---|
| Receive an intentional trigger | Transcribe and improve the transcript |
| Pre-warm and start the microphone | Extract names, dates, entities, claims, and routes |
| Give truthful haptic/state feedback | Title, summarise, search, and organise |
| Stop safely and protect against runaway capture | Link a thought to earlier thoughts, calendar context, and sources |
| Commit recoverable audio locally | Produce daily reviews, reminders, and investment research views |
| Queue a hand-off and expose a real delivery problem | Configure behaviour, integrations, workflows, and agent drafts |

This is not “missing functionality.” It is a boundary. A feature that acts on
audio after it is safely captured gains nothing from competing for the speaker's
attention on a 49 mm screen.

The ideal watch UI is therefore closer to a microphone appliance than a notes
application: no library, no transcript, no routing screen, no title field, no
destination picker, no configuration maze. The normal capture path should not
ask a question.

### Delete buttons before adding intelligence

Every control creates a choice, a target, and a failure mode. Use this test:

> If this button vanished, would a real thought become harder to capture
> **safely**?

If no, delete it or move it to the phone/server.

That produces a deliberately small surface:

| Control or screen | Target | Why it stays or goes |
|---|---|---|
| Action button / Control / complication | **Keep** | Intentional start without app hunting. |
| Double Tap and second Action press | **Add when verified** | Remove the need to look down to stop. |
| Silence arm-warn-veto | **Keep as default behaviour** | Ends normal thoughts without a deliberate action. |
| One large Stop fallback | **Keep** | Deterministic escape hatch when gesture or silence fails. |
| Cancel / Discard | **Challenge hard** | Deletes the sole source of truth; empty accidental captures can be handled safely instead. |
| In-app Record button | **Demote to fallback** | The dedicated external trigger is the product. Keep only where it enables a genuine non-Ultra/direct-launch path. |
| Auto-stop toggle on the recording watch | **Move out of the normal path** | A safe default beats a per-capture setting; exceptional configuration belongs downstream. |
| Timer and recording indicator | **Keep, passive** | Reassures a glance without demanding interaction. |
| Level meter | **Optional / defer** | It provides little capture value unless hardware tests show it prevents a real problem. |
| Memo list, playback, transcripts, routes, settings | **Remove from the watch** | They are management and review, not capture. |

The point is not to remove the last emergency fallback for aesthetic purity. It
is to make the fallback so rarely needed that the normal experience has no
buttons at all: press to begin; speak; stop happens naturally; feel confirmation.

**This table has since been actioned, and it went further than "demote".** The
watch UI is now a single full-screen button — grey READY, red RECORDING — and
the timer, level meter, auto-stop toggle, memo list, cancel and save
confirmation are gone rather than demoted. The "one large Stop fallback" and the
"in-app Record button" turned out to be the same control as each other and as
the screen itself, which is what made the reduction possible. See DESIGN.md
§"What was removed, and why each one had to go".

The one row that moved *up*: red now means audio is genuinely being written, so
"a truthful start cue" is enforced by the state machine rather than by
convention.

## What counts as friction

| Friction | The user experiences it as | The design response |
|---|---|---|
| **Invocation** | “How do I start this?” | A dedicated, reliable trigger; no app hunting. |
| **Time to speech** | “Should I start talking yet?” | A truthful start cue and a short, measured path to the first sample. |
| **Hands and eyes** | “I need to stop walking / put something down / hit a tiny target.” | Physical or gesture controls; large deterministic fallback controls. |
| **Decision** | “Where should this go? What should I call it?” | Capture first; infer or route later. |
| **Boundary** | “Did it stop? Did it save? Did it cut me off?” | Safe auto-stop, distinct haptics, and a one-press continuation path. |
| **Trust** | “Did that thought disappear?” | Durable local audio, visible status, reconciliation, and repair. |
| **Re-entry** | “Why did I record this, and when is it useful?” | Automatic context plus the right review moment, not a pile of audio files. |

Optimising only the first row that can be timed produces a fast recorder. Solving
all seven produces an external memory.

## Non-negotiable design rules

1. **The capture-time budget is one intentional action.** A person may speak
   naturally, but they should not be asked to choose a route, title, tag, or
   destination before the mic is live.
2. **A start cue must be honest.** A cue meaning “I saw the press” is useful;
   a cue meaning “speak now” must mean a sample is reaching durable storage.
   Do not trade opening words for fake immediacy.
3. **End slowly rather than cutting off speech.** A few seconds of trailing
   silence are cheap. A lost final clause is not. Automatic stopping needs an
   audible warning and an easy veto.
4. **Audio is the primary evidence.** Transcript, route, summary, and agent
   output are fallible derivatives. Keep the source through a confirmed
   hand-off and make it reachable when interpretation matters.
5. **Context should be captured automatically or after the fact.** The thought
   itself must never wait for the metadata model.
6. **Every stalled thought needs a visible path to recovery.** Silent failure is
   the highest-friction outcome: it makes the reflex unsafe.
7. **A feature earns its complexity only if it removes a real observed
   obstacle.** More capture controls are usually friction in disguise.

## The current shortest path

For an Ultra user, the intended path is already close:

```text
thought → Action button → mic becomes live → START haptic → speak
        → silence / Double Tap / screen tap / wrist-down timeout / app exit
        → STOP haptic → phone and ingest retry themselves
```

The Action Button removes app-finding; the recording view is the first frame;
the recorder is pre-armed; Double Tap, silence auto-stop, a large screen stop,
an 8-second wrist-down timeout, and app exit provide layered ways out. The
remaining work is to make each arrow dependable on a real wrist, then make the
memo useful at the other end.

For non-Ultra watches, a complication or Siri remains a worse start path. Do not
pretend otherwise. The right strategy is to make the primary Ultra interaction
excellent, retain thin universal fallbacks, and measure whether another capture
surface solves an actual problem.

## 1. Remove invocation friction

### The best start is a physical affordance

The Action button is the right default because it can be pressed without
looking, navigating, or holding the watch steady. The manual Control assignment
is unavoidable Apple setup friction, so onboarding should do only what is
necessary:

- explain the payoff in one sentence;
- take the user to the exact assignment step;
- run one test capture that proves the whole reflex; and
- get microphone permission before a real thought is at stake.

Do not build a tutorial carousel, route setup, folder selection, or settings
tour in this moment. The first-run goal is one successful capture.

### Start alternatives should be adapters, not separate products

Use the same `StartRecordingIntent` behind a Control Center control,
complication, Smart Stack surface, and Siri shortcut. They are availability
fallbacks, not invitations to create different workflows.

Useful experiments, in order:

1. **An elapsed-time Smart Stack stop surface.** This closes the Return-to-Clock
   hole on longer recordings and helps watches without an Action button.
2. **A phone lock-screen / shortcut capture fallback.** Only if dogfooding shows
   real thoughts occur while the watch is unavailable. It must preserve the same
   no-picker start contract.

Avoid speculative motion gestures, voice wake words, or a permanent listening
mode. They create false starts, privacy cost, and new things to remember.

## 2. Make “start speaking now” unambiguous

Milliseconds matter because the first words often carry the thesis, a name, or
the intended route. But the real metric is not time from button press to a red
screen. It is time from button press to **the user safely beginning the thought**.

### One truthful signal

The start haptic fires only after `record()` confirms the microphone and the
first sample is reaching disk. It means “speak now,” never merely “I saw your
press.” The matching stop haptic fires for every end path. No acknowledgement,
warning, save, or failure haptic competes with that two-signal language.

### Keep launch work out of the thought path

These are implemented and remain correct:

- Claim the launch request in `RecorderModel.init`, before SwiftUI lays out a
  view, so recording UI is the first frame.
- Configure the audio session immediately and overlap activation with process
  launch.
- Pre-arm the next `AVAudioRecorder` while the app is idle, moving file and
  encoder setup out of the press path.
- Defer index loading, WatchConnectivity setup, orphan recovery, compression,
  and storage cleanup until capture is underway.
- Keep the app more likely to be warm with a complication, Dock placement, and
  background-refresh requests. These are hints, not guarantees.

Further experiments worth measuring before adopting:

- Render only a bare recording shell on the Action-button launch path; defer
  the meter until the first sample.
- Maintain a prepared recorder immediately after each save, not just after the
  next normal app bootstrap.
- Record raw PCM first and compress later, if profiling shows AAC setup still
  sits on the hot path.
- Test whether Return to App materially improves the warm-start distribution;
  ask users to enable it only if it does.

Do **not** use an always-on pre-roll or ring buffer by default. It records audio
before a deliberate capture action and introduces privacy and consent risk. A
short, explicit, opt-in, wrist-raised experiment could be reconsidered only if
hardware measurements show ordinary start latency is genuinely unacceptable.

### Measurement

In-process marks are still useful:

```text
model init → activation requested → start requested → first sample
```

`Latency` logs time since process execution because the button press happens
before the process exists. For the user-visible number, film a real watch at
240 fps from button actuation to the cue that means “speak now.”

Record a small field dataset, not one heroic demo:

- Release build, cold / warm / app-frontmost;
- wrist down, walking, sitting, holding a cup, gloves if relevant;
- first-word clipping rate, not only milliseconds;
- Action press → first sample p50 and p95; and
- whether the user starts speaking before the truthful cue.

Treat simulator figures as ordering signal only. They are not device latency.

## 3. Remove stopping and boundary friction

Stopping should be easier than starting, but biased toward continuing. The user
often stops mid-thought, while moving or holding something; a false positive
deletes the part they cared about.

The layered stop design is right:

| Layer | Role | Constraint |
|---|---|---|
| Large Stop button | Deterministic universal fallback | Always above the fold. |
| Double Tap | Eyes-free stop on S9+ | Targets Stop, never Discard. |
| Second Action press | Best Ultra interaction | Verify delivery to the active recorder. |
| Silence arm → warn → veto | Zero-action normal ending | Must fail toward running long. |
| Duration cap | Privacy/battery backstop | Warn before it saves. |

The silence monitor's arm-warn-veto flow is the right shape: a haptic announces
an impending save; speech, touch, or crown movement vetoes it; then saving has
its own distinct confirmation. Its thresholds must be tested with wrist-away
speech, quiet rooms, cars, streets, and cafés.

The next high-value boundary improvement is **continue last memo**. If a new
capture starts within a short window after an auto-stop or deliberate stop, let
the user append it to the prior thought (or present it as one logical chain).
That makes a premature stop cost one press instead of a broken thought, which
lets automatic stopping stay helpful rather than timid.

Never add a post-stop “Save or discard?” screen. The existing commit-then-brief
saved confirmation is the right default: once the user stops, it is safe.

## 4. Capture context without asking for it

The key phrase is not merely “voice capture”; it is **thought context capture**.
The speaker should not have to manufacture context in a form before speaking.

Every memo can carry zero-effort context:

- recorded time, timezone, duration, trigger surface, and whether it was
  explicitly stopped or auto-stopped;
- a link to adjacent memos: “continued from” and “followed by”; and
- later-derived entities, people, dates, tickers, claims, questions, and
  confidence—always traceable back to the audio and transcript.

Useful ideas to validate:

1. **Natural spoken prefixes, never mandatory syntax.** “Investment idea…” or
   “follow up…” can route a note, but failure to say one must never block capture
   or make a memo second class. Store the raw prefix and the derived route.
2. **Correction memos.** “Correction to my last memo: the ticker was Natera.”
   Link it to the prior memo; do not overwrite primary audio or pretend a model
   was right.
3. **Thought chains.** Detect a short follow-up capture, “also…”, or a shared
   entity and let review present the sequence as one evolving thought.
4. **Context handoff from another surface.** A future share-sheet/browser action
   can attach an article or screenshot to a memo response, but must be optional.
   It is for cases where a source exists—not a new prerequisite for speaking.
5. **Calendar/activity context, opt-in.** Attach a meeting title or active
   workout only where that context is genuinely useful and private enough. Never
   surprise-capture location or third-party context just because an API permits
   it.

Do not force a taxonomy at capture time. A good system can ask later, when it
has a transcript and the person has a full screen, “Was this a decision, task,
question, observation, or reference?”

## 5. Make trust frictionless

“Trust it” means a person should neither babysit a transfer nor discover weeks
later that a thought never arrived. The project already has durable local audio,
queued WatchConnectivity, retries, and crash recovery. The remaining gaps are
mainly visibility and proof.

Build these before elaborate intelligence:

1. **A verified receipt per hop.** A watch-side `WCSession` completion is not
   proof that the phone imported the file; an HTTP 2xx with a captive-portal body
   is not proof that the server committed it. Model each hand-off distinctly.
2. **Status-only reconciliation.** Compare watch/phone memo IDs to database
   receipts and surface an age-based “needs attention” count. This preserves the
   one-way *content* boundary while detecting missing thoughts.
3. **A repair action.** Failed authentication, a too-large file, import failure,
   and a stalled queue need a retry path a human can actually reach.
4. **Fault-injection coverage.** Treat captive portals, missing metadata,
   phone-full imports, bad credentials, a database failure after transcription,
   and compression fallback as normal test scenarios.
5. **Retention only behind proof.** Never reclaim the last usable audio copy on
   a status inferred from an earlier hop.

The detailed catalogue and current rankings live in `FAILURE_MODES.md`.

## 6. Make later use effortless too

Audio captured perfectly but never resurfaced is still friction deferred.
The initial downstream product should be a review loop, not a generic memo
library and not an autonomous executor.

Good review moments:

- a daily “unreviewed thoughts” digest;
- a weekly summary of new ideas, open questions, and changes of mind;
- before an earnings event or meeting, the relevant prior observations;
- when a stated time horizon arrives, an invitation to revisit the prediction;
- a contradiction prompt: “this differs from what you said about X last month.”

For investment research, derive a structured but revisable record:

```text
entity/ticker · claim · evidence · catalyst · falsifier · horizon · confidence
```

Blank is better than hallucinated. Each field should link to the source memo,
and any agent should draft a review item—not execute an external action. This
same model generalises beyond investing to tasks, questions, observations, and
personal decisions.

## The next experiments to run

This is the concrete backlog, ranked by reduction in real user friction rather
than novelty:

1. **Hardware field test the complete reflex.** Verify control assignment,
   cold/warm starts, first-word clipping, Return-to-Clock behaviour, Double Tap
   stop, wrist-down/app-exit stopping, and auto-stop in real environments.
2. **Test the two haptic meanings on a real wrist.** Confirm START means “speak
   now” and STOP means recording ended, without any competing vibration.
3. **Implement status receipts, reconciliation, and a visible repair count.**
   This makes the reflex safe enough to become habitual.
4. **Build continue-last-memo.** It reduces stopping risk and turns fragmented
   thought capture into a coherent chain.
5. **Ship a daily review surface.** Do this before building more capture modes;
   it closes the loop that makes recording a thought worthwhile.
6. **Add correction memos and flexible extraction.** Improve context without
   burdening the moment of capture.

## Things to resist

These are interesting, but require strong evidence before they are allowed to
complicate the reflex:

- permanent listening, long pre-roll buffers, or ambient capture;
- mandatory voice commands, spoken category menus, or a stop wake word;
- live transcription while speaking;
- more than one deliberate capture-time choice;
- a dense watch library, history browser, or settings-heavy home screen;
- “AI agents” that take consequential actions from an imperfect transcript;
- integrations added because they are possible rather than because they remove
  a specific observed point of friction.

The test is simple: if removing the feature would not make a real thought harder
to capture, trust, or use later, it does not belong on the critical path.
