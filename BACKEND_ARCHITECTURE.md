# Architecture

**Date:** 2026-08-06
**Status:** decided. This is the design. [BACKEND_APPROACHES.md](BACKEND_APPROACHES.md)
has the alternatives that were considered and why they lost.

Four rules, fixed:

1. The **cloud model** transcribes — not the on-device Speech framework.
2. The **OpenAI key lives in Cloud Run**, never in the app binary.
3. **Audio never rests in GCP.** Not in a bucket, not on disk, not in a log.
4. The **phone pumps the audio** to Cloud Run. The watch never talks to the cloud.

---

## The whole thing

```mermaid
flowchart LR
    subgraph APPLE["🍎 Apple devices — audio lives here, permanently"]
        direction TB
        W["⌚️ Watch<br/>records AAC 32 kbit/s"]
        P["📱 Phone<br/>Documents/Memos/id.m4a"]
        W -->|"WCSession<br/>transferFile"| P
    end

    subgraph GCP["☁️ Your GCP project — text only, no audio at rest"]
        direction TB
        SM["🔑 Secret Manager<br/>OPENAI_API_KEY"]
        CR["Cloud Run<br/><b>audio in memory only</b><br/>streamed, never written"]
        DB[("Cloud SQL Postgres<br/><b>transcripts</b>")]
        SM -.->|"injected at boot"| CR
        CR -->|"text"| DB
    end

    AI["🤖 OpenAI<br/>audio transcriptions"]

    P ==>|"① POST raw .m4a"| CR
    CR ==>|"② stream bytes"| AI
    AI ==>|"③ transcript"| CR
    CR ==>|"④ transcript"| P

    style CR fill:#1a7f37,stroke:#0d4a20,color:#fff
    style DB fill:#1a7f37,stroke:#0d4a20,color:#fff
    style SM fill:#7f6a1a,stroke:#4a3d0d,color:#fff
```

The phone keeps the only permanent copy of the audio. GCP sees the bytes for the
duration of one request and keeps nothing.

---

## What crosses each boundary

```mermaid
flowchart TD
    A["⌚️ Watch"] -->|"audio + id, recordedAt, duration"| B["📱 Phone"]
    B -->|"<b>audio</b> — transient, one request"| C["☁️ Cloud Run"]
    C -->|"<b>audio</b> — transient, streamed"| D["🤖 OpenAI"]
    D -->|"text"| C
    C -->|"<b>text</b> — persisted"| E[("Cloud SQL")]
    C -->|"text"| B

    B -.->|"<b>audio</b> — persisted forever"| F[("📱 Phone disk")]

    style F fill:#1a5c7f,stroke:#0d3a52,color:#fff
    style E fill:#1a7f37,stroke:#0d4a20,color:#fff
```

Only two things are ever written to durable storage: **audio on the phone**, and
**text in Postgres**. Everything else is in flight.

---

## Keeping audio out of GCP for real

"Never written" is an engineering claim, not a wish. Four rules make it true:

```mermaid
flowchart LR
    IN["request body<br/>arrives"] --> S{"streamed<br/>straight through?"}
    S -->|"yes ✅"| OUT["forwarded to OpenAI"]
    S -->|"no ❌"| BAD1["buffered to a temp file<br/><i>audio at rest</i>"]

    OUT --> L{"request logging<br/>configured?"}
    L -->|"body excluded ✅"| DONE["response returned,<br/>bytes gone"]
    L -->|"body logged ❌"| BAD2["audio in Cloud Logging<br/><i>audio at rest</i>"]

    style BAD1 fill:#8b1a1a,stroke:#5a0f0f,color:#fff
    style BAD2 fill:#8b1a1a,stroke:#5a0f0f,color:#fff
    style DONE fill:#1a7f37,stroke:#0d4a20,color:#fff
```

1. **Stream the body through** to OpenAI. Do not read it into a variable, do not
   write a temp file. The two easy ways to accidentally persist audio are a
   framework that spools large uploads to `/tmp` and a library that buffers the
   whole body to compute a length.
2. **Exclude the request body from logging.** Cloud Run's default access logs
   don't capture bodies, but an application-level request logger added later
   might. This is the most likely way this rule quietly breaks.
3. **Raw body, not multipart.** `Content-Type: audio/mp4`, metadata in headers.
   Multipart parsers are exactly the libraries that spool to disk.
4. **No bucket in the project.** If there is no GCS bucket, audio cannot end up
   in one by accident.

---

## The life of a memo

```mermaid
sequenceDiagram
    autonumber
    participant W as ⌚️ Watch
    participant P as 📱 Phone
    participant CR as ☁️ Cloud Run
    participant SM as 🔑 Secret Manager
    participant AI as 🤖 OpenAI
    participant DB as Postgres

    Note over W: press Action button, speak, stop
    W->>W: PCM capture → AAC, commit to disk
    W->>P: transferFile(.m4a, {id, createdAt, duration})

    Note over P: session(_:didReceive:)<br/>PhoneLibrary.swift:133
    P->>P: move into Documents/Memos/id.m4a
    P->>P: mark pending, enqueue upload

    Note over P: background URLSession —<br/>survives app suspension
    P->>CR: POST /v1/memos/{id}/transcribe<br/>Bearer token, raw audio body

    CR->>DB: SELECT transcript WHERE id = ?
    alt already transcribed
        DB-->>CR: transcript exists
        CR-->>P: 200, cached — OpenAI never called
    else new memo
        SM-->>CR: OPENAI_API_KEY
        CR->>AI: stream audio bytes
        AI-->>CR: transcript
        CR->>CR: strip routing prefix → route + body
        CR->>DB: UPSERT ON CONFLICT (id)
        CR-->>P: 200 {transcript, body, route}
    end

    P->>P: mark synced, render in LibraryView
    Note over P: audio stays on the phone.<br/>Nothing deletes it.
```

The watch's UUID is the primary key at every hop — it is already the filename on
both devices and already travels in the `transferFile` metadata. A retried
upload cannot duplicate a row, and step 10 means a retry cannot double-bill
OpenAI either.

---

## The phone's upload queue

Hop 1 already works this way (`WatchApp/WatchSyncClient.swift`). Hop 2 is the
same state machine one link further along.

```mermaid
stateDiagram-v2
    [*] --> pending: arrives from watch
    pending --> uploading: network available
    uploading --> synced: 200 OK
    uploading --> pending: timeout / 5xx / offline
    uploading --> failed: 401, 413, 400
    failed --> pending: manual retry
    synced --> [*]

    note right of pending
        retried on app foreground
        and on reachability change
    end note

    note right of failed
        4xx is not retried —
        it will fail identically
    end note
```

**A background `URLSession` is mandatory.** WatchConnectivity delivers files by
launching the app in the background; a foreground-only upload would start, get
suspended, and lose the memo. A background session hands the transfer to the
system daemon, which completes it whether or not the app is alive.

**This is also why the body is raw rather than multipart** — a background session
can only upload *from a file*, and with a raw body `uploadTask(with:fromFile:)`
points straight at the existing `.m4a` and copies nothing.

---

## Trust boundaries

```mermaid
flowchart TD
    subgraph U["untrusted — assume fully readable"]
        APP["📱 the iOS app binary"]
    end
    subgraph T["trusted — you control it"]
        CR["☁️ Cloud Run"]
        SM["🔑 Secret Manager"]
    end

    APP -->|"bearer token<br/>identifies the user"| CR
    SM -->|"OPENAI_API_KEY<br/><b>never leaves</b>"| CR
    CR -->|"authenticated"| AI["🤖 OpenAI"]

    APP -.->|"❌ never"| AI

    style U fill:#8b1a1a,stroke:#5a0f0f,color:#fff
    style T fill:#1a7f37,stroke:#0d4a20,color:#fff
```

The app holds a **bearer token**, not the OpenAI key. Worst case, a leaked token
lets someone transcribe audio on your bill — annoying, revocable, rate-limitable.
A leaked OpenAI key is your whole account.

The dotted line is the property being bought: **the app can never call OpenAI
directly**, because it has nothing to call with.

---

## What to build

| Layer | Work |
|---|---|
| **GCP** | One Cloud Run service, one Cloud SQL Postgres instance, one secret. Same region. |
| **Cloud Run** | `POST /v1/memos/{id}/transcribe` — auth, dedupe, stream to OpenAI, strip prefix, upsert. Roughly 200 lines. |
| **iOS — new** | `iOSApp/TranscriptionClient.swift` — background session, queue, retry |
| **iOS — edit** | `PhoneLibrary.swift:133` enqueue · `PhoneLibrary.swift:19` sidecar grows state + transcript · `LibraryView.swift` shows it |
| **Project file** | New sources added to the `WristMemo` target's Sources phase **by hand** — there is no filesystem-synchronized group, so an unlisted file silently doesn't compile in |

Schema, endpoint detail, cost and build order are in [BACKEND.md](BACKEND.md).
