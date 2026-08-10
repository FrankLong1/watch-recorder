# Source-aware thought capture

**Status:** brainstorm — no product or privacy decisions are committed here.

## The insight

A spoken thought is often a reaction to something the phone can see but the
watch cannot: an article, chart, message, slide, document, physical object, or
scene. Asking the speaker to reconstruct that source verbally creates friction
and usually loses the exact detail that made the thought valuable.

The opportunity is a **context capsule**:

```text
see something on the phone or in the world
    → one Share or Camera action
    → “context ready”
    → next Action-button thought attaches automatically
    → server reasons over source + spoken reaction together
```

This is not a second note-taking workflow. It is a way to give an otherwise
minimal watch capture a source of truth.

## Product rule

Source context may enrich a thought; it must never become a prerequisite for
capturing one.

The watch capture path remains independent of the phone, camera, network, and
server. If a source hand-off fails, the voice memo is still a complete, durable
memo. If no voice memo follows, the source context simply expires or becomes a
phone-side draft; it never creates a mystery task for the user.

## Two entry points

### 1. Share-sheet context

From Safari, a news app, a PDF, a message, a screenshot, or any app that offers
Share:

1. The user selects **Add context to next WristMemo**.
2. The extension captures the smallest useful representation it received: URL,
   title, selected text, plain text, image, PDF reference, or screenshot.
3. The phone gives a tiny local confirmation and returns to the source app.
4. The next suitable watch memo automatically binds to that capsule.

There is no compose screen, route picker, or “record now” requirement. Share is
the single intentional action which says *my next thought is about this*.

### 2. Camera context

Sometimes the source is not on screen: a whiteboard, a printed chart, a product
on a shelf, a slide in a room, a menu, or a handwritten figure. A phone capture
surface could take one photograph and create the same pending capsule.

The simplest version is not a new camera app: take a photo with the normal
Camera app, then share it to WristMemo. A dedicated camera shortcut is only
worth building if that extra share step repeatedly prevents capture.

The model can later receive the image (or text/OCR derived from it) alongside
the spoken memo. It should be asked to ground its output in the supplied source,
identify uncertainty, and retain a reference from every claim back to the
source and audio.

## Binding a context capsule to a memo

WatchConnectivity is delayed and cannot be the truth for a “next memo” promise.
The phone may receive a watch file minutes or hours after it was recorded.

The reliable join is therefore based on durable timestamps and identity:

```text
phone creates capsule at T0
watch records memo M at T1, with watch UUID and recorded-at timestamp
phone receives M later at T2
server/phone binds M to the newest unexpired capsule created before T1
```

The binding needs conservative rules:

- one explicit active capsule per user by default;
- an expiry window appropriate to the intent (for example, a short default
  window rather than “next memo sometime this week”);
- attach only to the first eligible memo after creation;
- use the recorded-at time, not transfer arrival time;
- preserve the exact binding decision and allow a later correction; and
- never attach a source silently when there is material ambiguity.

A future live WatchConnectivity hint can make the watch acknowledge “context
ready,” but it cannot be required for correctness.

## What the capsule stores

The source itself and the derived model context must be separate.

```text
ContextCapsule
  id, user_id, created_at, expires_at, binding_state
  kind: url | selected_text | screenshot | photo | document | mixed
  local source references and integrity metadata
  optional title, URL, source-app name, user-supplied caption

DerivedContext
  OCR / extracted text / visual description
  model annotations, entities, dates, claims, confidence
  provenance back to the source region and capsule
```

Raw assets, extracted text, and model input have different retention and privacy
requirements. Do not accidentally inherit the current “audio never rests in
GCP” promise without deciding what it means for images, documents, screenshots,
and third-party text.

## Privacy and trust questions to answer before building

- Where do images, screenshots, PDFs, and extracted text live on phone, server,
  and model-provider systems? For how long?
- Can a source be processed ephemerally like audio, or does useful later review
  require keeping it? If it is retained, where and under which encryption/access
  controls?
- How does the user see that a photo or screenshot will be sent to a model,
  without adding a confirmation step every time?
- How are private messages, account screens, faces, bystanders, copyrighted
  articles, and location-bearing images handled?
- Can on-device Vision/OCR remove the need to upload some raw image data?
- What happens when the source is a URL behind authentication or a paywall?

The correct answer may differ by source type. The implementation must make these
boundaries explicit rather than treating every `NSItemProvider` as generic model
input.

## Failure modes

| Failure | Required behaviour |
|---|---|
| Share extension cannot read the offered item | Tell the phone user; do not affect voice capture. |
| Camera capture is cancelled | No capsule is created; nothing to clean up. |
| Watch memo arrives after the capsule expires | Preserve the memo; surface an attachable orphan only if a human actually needs it. |
| Two candidate capsules could match | Do not guess. Keep the memo unbound or ask later on a larger screen. |
| Asset upload/model processing fails | Preserve local source and memo; retry or make the context failure visible without blocking transcription. |
| Model invents a claim not supported by the source | Preserve provenance and mark the output as derived; never overwrite the audio/transcript. |
| Phone is offline | Store the capsule locally and bind using timestamps when delivery resumes. |

## The smallest valuable experiment

Do not start with computer vision, an in-app browser, or a custom camera.

1. Build an iOS Share extension that accepts a URL, text, and image.
2. Store one local pending capsule with a short expiry.
3. Bind it to the next watch memo using `recordedAt` when that memo reaches the
   phone.
4. Send the memo transcript plus a small, explicitly defined source
   representation to a server-side test prompt.
5. Inspect whether the combined output is materially more useful than a voice
   memo alone—and whether the binding ever feels surprising.

If this works, test photo sharing from the normal Camera app. Only then consider
a dedicated one-tap camera capture surface, OCR, multi-source capsules, or
server-side visual reasoning.

## Questions for device and API research

1. Which `NSItemProvider` representations do the highest-value source apps
   actually offer to an iOS Share extension?
2. What app-group/shared-container arrangement safely lets the extension hand a
   capsule to the iOS companion app?
3. What can a Share extension do reliably under its memory and execution limits?
4. Is a Shortcuts/App Intent camera action meaningfully faster than Camera →
   Share for this use case?
5. What is the lowest-friction way to represent a screenshot, photo, URL, and
   selected text to the chosen model without needless raw-asset retention?
6. How should the system prove a generated statement came from a particular
   audio excerpt and source region?
