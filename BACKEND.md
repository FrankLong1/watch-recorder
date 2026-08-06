# Backend

**Date:** 2026-08-06
**Status:** proposal — nothing here is built. There is currently no networking
code of any kind in the repo.

Companion to [DESIGN.md](DESIGN.md), which covers everything up to the moment a
memo lands on the phone. This file covers everything after.

---

## The decision

`IDEAS.md` §4 says the recording is not the product — capture is commodity, the
differentiator is what happens downstream. That downstream needs somewhere to
live. This doc picks where.

The stated intent:

> voice is recorded onto the iPhone, the app makes a call to the OpenAI
> transcription API, then the transcription hits GCP. We don't want the audio
> recording to hit GCP — ideally no audio files at all in our GCP.

That is a good instinct and most of it survives scrutiny. One correction and one
consequence follow.

### The correction: Cloud SQL is right, but not for audio

Cloud SQL is managed Postgres. It is a good home for transcripts and a bad home
for audio bytes — backups balloon, queries slow down, and you pay database
storage rates (~$0.17/GB/mo) for something object storage does at ~$0.02. Audio
belongs in Cloud Storage, or in this design, nowhere in GCP at all.

So the instinct was right about the database. It was wrong about what goes in
it. Transcripts go in Postgres. Audio stays on Apple devices.

### The consequence: "no audio in GCP" and "key on the server" pull apart

The key was chosen to live server-side, in Cloud Run. That is the right call —
an API key compiled into an iOS binary can be extracted in minutes — but it
means the phone cannot call OpenAI directly, because it has no key to call with.
Something of yours must sit in the middle.

The tight version: **audio transits Cloud Run in memory and is never written.**
Not to a bucket, not to disk, not to a log. Nothing is retained, so there is
nothing to delete and no retention policy to get wrong. There are no audio
*files* in GCP, which is the property that actually matters. But the bytes do
pass through your project, and the doc should say so plainly rather than pretend
otherwise.

The alternative that would avoid even that — phone fetches a short-lived scoped
token and uploads straight to OpenAI — is not available. OpenAI issues ephemeral
tokens for the Realtime API, not for the transcription endpoint. Keychain-on-
device and proxy-through-your-server are genuinely the only two shapes.

---

## The chain

A memo makes three hops, each best-effort, each needing a durable queue:

```
watch ──transferFile──▶ phone ──HTTPS──▶ Cloud Run ──▶ OpenAI
                                              │            │
                                              │◀──text─────┘
                                              ▼
                                        Cloud SQL (text only)
```

Hop 1 already exists and is the template for hop 2. `WatchSyncClient` marks each
memo `.pending`, flips it to `.transferring`, and re-queues anything unfinished
when the session activates or the phone becomes reachable. Hop 2 is the same
state machine one link further along. This is not new architecture — it is the
existing architecture extended by one.

### What already exists

| Piece | Where |
|---|---|
| Memo committed to watch storage | `WatchApp/MemoStore.swift:32` — `Application Support/WristMemo/Memos/<uuid>.m4a` |
| Watch→phone transfer + retry | `WatchApp/WatchSyncClient.swift:24` |
| **Phone receives — the hook point** | `iOSApp/PhoneLibrary.swift:133` — `session(_:didReceive:)` |
| Phone storage + metadata sidecar | `iOSApp/PhoneLibrary.swift:32` — `Documents/Memos/<id>.m4a` + `<id>.json` |
| Memo model (15 lines, no transcript) | `WatchApp/Memo.swift` |

`session(_:didReceive:)` is the single entry point for every memo arriving on
iOS. Everything below hangs off it.

Audio format is AAC mono at 32 kbit/s (`WatchApp/AudioCompressor.swift:17`), so
a minute is roughly 240 KB. OpenAI's transcription endpoint caps uploads at
25 MB — about 100 minutes at this bitrate. Not a practical limit, but worth a
guard rather than a surprise.

---

## Decisions

### 1. Does audio touch our cloud? — **transits, never stored**

| Option | Audio in GCP | Key exposure | Verdict |
|---|---|---|---|
| Phone → OpenAI direct, key in Keychain | none, ever | key on device | viable **only** if you are the sole user |
| **Phone → Cloud Run → OpenAI** | in memory, never written | key in Secret Manager | **chosen** |
| Phone → GCS → event → Cloud Run → OpenAI | files at rest | key in Secret Manager | rejected — violates the stated requirement |

The third is the textbook shape and worth knowing why it was rejected rather
than merely skipped. It buys asynchronous processing, free retries, and the
ability to re-transcribe the whole corpus when a better model ships. It costs
audio files sitting in your project. Revisit only if re-transcription becomes
something you actually want.

**Consequence:** Cloud Run streams the request body to OpenAI. No temp files, no
`request.body` logging, no buffering the whole payload where a crash dump could
capture it.

### 2. Where does the key live? — **Secret Manager, read by Cloud Run**

Decided. Never in the binary, never in the repo, never in an env var committed
to a YAML file.

### 3. What stores the transcript? — **Cloud SQL Postgres**

The real contest is Postgres versus Firestore, and it is closer than it looks.

| | Cloud SQL Postgres | Firestore |
|---|---|---|
| Cost at personal scale | ~$9–15/mo, always on | ~$0, free tier, scales to zero |
| Setup surface | instance, user, connector | a URL |
| **Full-text search over transcripts** | **built in (`tsvector` + GIN)** | **none — needs a bolt-on search service** |
| Semantic search later | `pgvector`, same box | separate vector service |
| Ticker timelines, thesis threading | joins and time ranges, natural | awkward, denormalize or read-modify-write |

Firestore is cheaper and simpler and would be the obvious pick for a write-only
log. This is not a write-only log. The first thing you will want is to search
your own memos, and Firestore fundamentally cannot do that — it has no
full-text search, so you would immediately be adding a second system to get
back a feature Postgres ships with. The investment layer in `IDEAS.md`
(ticker timelines, contradiction detection, "what did I say about NVDA over six
months") is relational and analytical work.

**Recommendation: Postgres, from the start.** The $9/mo is the price of not
running a migration and a search-service integration six weeks in.

If that monthly floor is genuinely unwelcome for a tool with one user, Firestore
is a defensible phase-1 choice — the migration at a few thousand memos is a
short script. But go in knowing search is the thing you will trip over.

### 4. Auth — **build for one user, leave the door open**

Not yet decided, and it does not need to block the build. The cheap insurance:

- A `user_id` column from day one, populated with a constant for now.
- A single long-lived bearer token, generated once, stored in the iOS Keychain,
  checked by Cloud Run against Secret Manager.
- No user table, no signup, no session management.

Swapping that for Sign in with Apple later means adding token verification in
one middleware and backfilling one column. Building multi-tenancy now, for one
user, would be the more expensive mistake.

---

## The recommended plan

### Schema

```sql
create table memos (
  id             uuid primary key,        -- generated on the watch, reused end to end
  user_id        text not null,
  recorded_at    timestamptz not null,
  duration_s     real not null,
  transcript     text,                    -- verbatim, as the model returned it
  body           text,                    -- transcript with the routing prefix stripped
  route          text,                    -- 'investment idea' | 'follow up' | null
  model          text,                    -- which model produced this
  language       text,
  transcribed_at timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create index memos_user_recorded on memos (user_id, recorded_at desc);

alter table memos add column search tsvector
  generated always as (to_tsvector('english', coalesce(body, transcript, ''))) stored;
create index memos_search on memos using gin (search);
```

**The primary key is the UUID the watch generated.** It is already the filename
on the watch (`MemoStore.newCaptureURL`), already the filename on the phone, and
already travels in the `transferFile` metadata. Making it the database key gives
idempotency across all three hops for free — a retried upload cannot create a
duplicate, because the row already exists.

### Endpoints

```
POST /v1/memos/{id}/transcribe
  Authorization: Bearer <token>
  Content-Type: audio/mp4
  X-Recorded-At: <unix seconds>
  X-Duration: <seconds>
  body: raw .m4a bytes
  → 200 { id, transcript, body, route, model }

GET  /v1/memos?since=<cursor>&limit=<n>    list, for phone backfill
GET  /v1/memos/search?q=<query>            full-text search
```

**Raw body, not multipart.** This matters more than it looks. A background
`URLSession` — which is mandatory here, see below — can only upload *from a
file*. With a raw body, `uploadTask(with:fromFile:)` points straight at the
existing `.m4a` and copies nothing. Multipart would mean writing an envelope to
a temp file first, on every memo, for no benefit.

**Idempotency:** if the row already has a `transcript`, return it and do not call
OpenAI. Retries then cost nothing and cannot double-bill.

### iOS changes

| File | Change |
|---|---|
| `iOSApp/TranscriptionClient.swift` | **new** — background `URLSession`, upload queue, retry |
| `iOSApp/PhoneLibrary.swift:133` | enqueue on receive |
| `iOSApp/PhoneLibrary.swift:19` | `Sidecar` grows upload state + transcript |
| `iOSApp/LibraryView.swift` | show transcript and upload state |
| `WristMemo.xcodeproj/project.pbxproj` | add new files to the `WristMemo` Sources phase **by hand** |

That last row is not optional bookkeeping. There is no
`PBXFileSystemSynchronizedRootGroup` in this project, so a new `.swift` file
that is not added to a build phase simply does not compile in, silently.

**The upload must use a background `URLSession`.** WatchConnectivity delivers
files by launching the app in the background; a foreground-only upload would
fire, get suspended, and lose the memo. A background session hands off to the
system daemon and completes regardless.

**The phone needs a real queue.** Today it has no index — `PhoneLibrary` scans
the directory and reads per-file sidecars. Upload state has to persist
somewhere: either grow the sidecar (smaller change, matches the existing shape)
or mirror the watch's `memos.json` index (more consistent across the two
platforms). The watch's `MemoStore` is the working reference for either.

### Parse the routing prefix server-side

`IDEAS.md` §2 wants "Investment idea — …" to route itself, with the prefix
stripped from the note and kept as metadata. That is a string operation on the
transcript, so it belongs where the transcript arrives. Doing it in Cloud Run
means improving the parser is a deploy, not an App Store review.

### Build order

Each step is verifiable on its own. Do not skip the first.

1. **Schema + Cloud Run skeleton returning a stubbed transcript.** Prove the
   phone → cloud → Postgres round trip before OpenAI is anywhere near it.
2. **Wire OpenAI in Cloud Run.** Test with `curl` and a real `.m4a` pulled off
   the simulator. No iOS involvement yet.
3. **iOS upload client** — background session, queue, retry.
4. **Transcript in `LibraryView`.**
5. **Routing prefix parser.**

### Cost

| Item | Monthly |
|---|---|
| Cloud Run (scales to zero, inside free tier) | ~$0 |
| Cloud SQL Postgres, smallest shared-core instance | ~$9–15 |
| Secret Manager | ~$0.06 |
| OpenAI transcription, ~300 min/mo | ~$1–2 |
| **Total** | **~$11–17** |

Cloud SQL is the entire cost. It bills whether or not you record anything.

---

## True regardless of which plan

1. **The memo UUID is the idempotency key end to end.** It is already the
   filename in three places and already crosses `transferFile` in metadata.
2. **`Memo` needs a `transcript` field** — and it currently lives in
   `WatchApp/`, compiled only into the watch target. Sharing it means moving it
   to `Shared/` *and* hand-adding it to the iOS target in the pbxproj.
3. **Audio is never deleted from the phone by the transcription flow.** The
   phone holds the durable copy; the cloud holds text. Retention on the device
   is a separate decision.
4. **App Store disclosure.** Sending audio to a third-party processor is
   disclosable. There is an empty, tracked file named `Privacy` at the repo root
   — presumably an abandoned `PrivacyInfo.xcprivacy`. It will need to be real.

## Verify before building

Everything below was reasoned from the current codebase, not tested against live
services.

- **OpenAI model and pricing.** `gpt-4o-transcribe`, `gpt-4o-mini-transcribe`,
  and `whisper-1` were the options as of the last check; the lineup and prices
  move. Confirm against the API docs, and confirm the 25 MB limit still holds.
- **Cloud SQL's smallest tier and its current price.** The ~$9–15 figure is the
  number the whole cost case rests on.
- **Cloud Run → Cloud SQL connectivity** — the built-in connection is simpler
  than a VPC connector, but confirm it before designing around it.
- **Background runtime after WatchConnectivity delivery** — enough to *start* a
  background upload task should be plentiful, since the daemon takes over, but
  it is worth confirming on hardware rather than the simulator.
- Put Cloud Run and Cloud SQL in the same region.
