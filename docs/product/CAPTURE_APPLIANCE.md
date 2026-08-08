# The capture appliance

**Status:** product decision

## The thesis

WristMemo is not a voice-memo app on a watch. It is a **capture appliance**:
one deliberate physical action turns a passing thought into durable audio with
enough context for the system to make it useful later.

The test for the product is not “can the watch display or manage a memo?” It is:

> When a thought occurs, can the person preserve it without interrupting the
> thought itself?

The desired reflex is:

```text
think → press → speak → trust it
```

Everything that adds a decision, a target, a wait, or a question between those
four words is suspect.

## The normal interaction

For an Apple Watch Ultra user, the finished interaction should be almost
invisible:

```text
thought occurs
  → Action button
  → a truthful “speak now” cue
  → speak normally
  → silence, Double Tap, screen tap, wrist-down timeout, or app exit ends it
  → the STOP haptic confirms recording ended
```

There is no title, destination, route, tag, transcript, folder, confirmation
screen, or post-recording decision.

The Action button is the primary start affordance. A Control Center control,
complication, and Siri are fallbacks using the same intent, not different
workflows. The app-opening path can be an intentional capture fallback only if
real use shows it is needed; it should never become a home screen people must
navigate before they can speak.

## The boundary

The watch owns only work that is impossible to defer. The phone and server own
everything else.

| Watch: now, at the moment of thought | Phone/server: after audio is safe |
|---|---|
| Receive an intentional trigger | Transcribe and clean the transcript |
| Pre-warm and open the microphone | Extract entities, people, dates, tickers, claims, and questions |
| Tell the user precisely when to speak | Infer route, title, summary, and priority |
| End capture safely | Link related thoughts and corrections |
| Commit recoverable local audio | Search, review, reminders, and research views |
| Queue a durable hand-off | Configuration, integrations, and workflow drafts |
| Surface a genuine delivery problem | All other note management |

This is a hard boundary. Server intelligence must never delay starting,
recording, saving, or handing off a thought. It makes the recording more useful
afterward; it is not part of permission to speak.

## Remove capability from the wrist

The small screen is an advantage when it prevents choice. The watch should not
grow a library, playback experience, transcript view, routing UI, settings
screen, or task manager merely because those are conventional app features.

### The button budget

Every watch button creates attention cost, target-acquisition cost, and a new
way to make the wrong thing happen. Apply this test to each one:

> If this control disappeared, would a real thought become harder to capture
> safely?

| Surface | Direction | Rationale |
|---|---|---|
| Action button / control / complication | Keep | The intentional start mechanism. |
| Double Tap to Stop | Keep when available | Removes the need to look and tap while ending. |
| Silence arm → warn → veto | Keep as default behaviour | Makes ordinary endings require no intentional action. |
| One large Stop fallback | Keep | Automatic and gesture paths are fallible; capture must remain controllable. |
| Record button inside the app | Demote | It is a fallback, not the centre of the experience. |
| Cancel / Discard | Challenge hard | It can destroy the only source recording. Empty accidental captures should be handled safely instead. |
| Per-capture settings, including auto-stop | Move out | A safe default beats a choice at the moment of thought. |
| Lists, routes, playback, transcripts, editing | Exclude | These are later review and management tasks. |

The aim is not literally zero controls. It is **zero controls in the normal
case**, plus one deterministic escape hatch when automation is wrong.

## Pre-warming is the local product

Most of the watch-side engineering budget should go to shrinking the time
between press and durable first sample:

- claim the intent before a view is built;
- configure the audio session as early as permitted;
- pre-arm the next capture file and recorder while idle;
- defer every non-audio task—index loading, sync setup, compression, recovery,
  cleanup, and view detail—until capture is underway; and
- keep the app more likely to be warm using the complication, Dock placement,
  and background-refresh hints.

The only haptic start promise is **speak now**: the microphone is live and the
first sample is reaching the capture file. There is no press-acknowledgement
haptic, because it asks the user to distinguish a signal that is not yet safe to
speak on. A false “speak now” signal is worse than a slightly slower-feeling
interaction because it clips the opening words that often carry the thought’s
meaning.

Measure real-device first-word clipping, not only milliseconds to a red screen.
The full rationale and measurement plan are in
[`docs/operations/LATENCY.md`](../operations/LATENCY.md).

## Ending without ceremony

The user should normally stop doing nothing. Silence detection ends the memo
only after its arm → veto period: speech or a deliberate movement vetoes it.
The final stop uses the same **STOP** haptic as every other ending; there are no
warning or save haptics to learn.

Double Tap and the large Stop screen target are the faster explicit endings. The
screen target remains the universal, deterministic fallback. It must be the only
meaningful recording-screen target; it is not an invitation to add a row of
secondary actions.

A future **continue-last-memo** path is a force multiplier. If a recording ends
and the speaker starts again within a short window, one press should continue
the same logical thought. This makes an over-eager boundary recoverable without
asking the person to organise fragments.

## Audio is the source of truth

The watch commits a recoverable audio file before sync. The phone keeps a local
copy while it transports that file. The server receives audio only to transcribe
it and persists text, not audio. Transcript, route, summary, and any agent work
are all derived artifacts which can be wrong.

Therefore:

- never delete the final usable audio copy based on an inferred status;
- never allow a bad transcript to erase or silently rewrite a thought;
- link corrections to the original recording rather than pretending the source
  changed; and
- make failed delivery visible and repairable without putting transcript
  management back on the watch.

[`docs/operations/FAILURE_MODES.md`](../operations/FAILURE_MODES.md) is the
operating catalogue for preserving this trust.

## The server is where the magic belongs

Once the thought is safe, the server can do difficult work without stealing the
moment of capture:

- transcribe with a model suited to proper nouns and domain vocabulary;
- retain the raw transcript alongside a cleaner reading view;
- extract revisable entities, dates, claims, questions, routes, and confidence;
- join continuations, corrections, and related ideas into thought chains;
- surface a memo at a useful time: a daily review, before a meeting or earnings
  event, or when a stated time horizon arrives;
- identify contradictions and changes of mind; and
- draft tasks, research, or follow-ups for human review.

The server may be sophisticated. The capture appliance must remain boringly
reliable and independent of it.

## Success criteria

The next version is simpler only if it improves these outcomes:

1. A person can begin speaking without looking at the watch or waiting for an
   uncertain cue.
2. They can end the recording without a precise screen interaction in the
   common case.
3. A captured thought never needs manual categorisation to be preserved.
4. A delivery or processing failure becomes visible before the thought is
   forgotten.
5. The original audio can settle an incorrect transcript or extraction.
6. The thought comes back when it is useful, without turning the watch into an
   inbox.

If a proposed feature does not improve one of these, it is not part of the
capture appliance.
