# WristMemo ingest

The cloud half of WristMemo. The phone POSTs a finished memo's audio; this
streams it to OpenAI, stores the transcript in Postgres, and answers with a
status code and no body. The authenticated owner can then read their transcript
history through a separate, text-only endpoint.

Design, diagrams and the decisions behind it are in
[`docs/architecture/1_INGEST_ARCHITECTURE.md`](../../docs/architecture/1_INGEST_ARCHITECTURE.md).
What happens to a
transcript *after* it lands is stage 2, in
[`docs/architecture/2_AGENT_ARCHITECTURE.md`](../../docs/architecture/2_AGENT_ARCHITECTURE.md).
The short version:

- **Audio never rests in GCP.** It is streamed through to OpenAI and never
  written to a bucket, disk, or log. There is no GCS bucket in this design.
- **The OpenAI key never leaves Cloud Run.** The phone presents a short-lived
  Google ID token for the WristMemo OAuth server client. Cloud Run verifies the
  immutable Google subject before accepting audio.
- **Separate capture and review paths.** The upload response remains status
  only; the signed-in owner later pulls their text-only transcript history into
  the phone's protected local cache. Audio never comes back from Cloud Run.
- **Watcher feed.** The remote Codex wiring watcher reads only memo UUIDs and
  transcription timestamps using its attached Google service-account identity;
  it never receives audio or transcript text.
- **It attaches to infrastructure that already exists** — a Cloud SQL instance
  owned by a separate, private project. This configuration reads that instance
  through a data source and never manages it.

## Layout

```
src/
  auth.ts         Authorization-header parsing
  google-identity.ts Google signature, audience and principal verification
  index.ts        the endpoint: auth, dedupe, transcribe, store
  transcribe.ts   hand-built streaming multipart to OpenAI
  db.ts           Cloud SQL over the /cloudsql socket, IAM auth
  routing.ts      spoken routing prefix (IDEAS.md §2)
  config.ts       environment parsing, fails fast at boot
  watcher-feed.ts metadata-only watcher endpoint and cursor validation
migrations/       ordered SQL, checksum-guarded by scripts/migrate.sh
terraform/        database, identity, secrets, image repo, Cloud Run service
```

## The endpoint

```
POST /v1/memos/{id}
  Authorization: Bearer <Google user ID token>
  Content-Type: audio/mp4
  X-Recorded-At: <unix seconds>
  X-Duration: <seconds>
  body: raw .m4a bytes

  → 204  committed, or already committed (idempotent)
  → 400  bad uuid or missing/invalid metadata headers
  → 401  missing, expired, or invalid Google token
  → 403  valid Google identity not on the subject allowlist
  → 411  no Content-Length
  → 413  over MAX_AUDIO_BYTES (25 MB, OpenAI's limit)
  → 502  OpenAI failed — retry
  → 503  database unavailable, or this memo is mid-transcription — retry
```

```
GET /v1/watcher/memos?after=<ISO timestamp>&after_id=<uuid>&limit=<1..500>
  Authorization: Bearer <Google service-account ID token>

  → { "memos": [{ "id": "…", "transcribedAt": "…" }] }
```

The watcher feed contains only memo identity and completion time. It does not
return audio, transcript, route, or other derived content.

```
GET /v1/memos?after=<ISO timestamp>&after_id=<uuid>&limit=<1..200>
  Authorization: Bearer <Google user ID token>

  → { "memos": [{ "id": "…", "recordedAt": 1754667100.25,
                    "durationSeconds": 12.4, "transcript": "…",
                    "transcribedAt": "…" }] }
```

The history endpoint is read-only and filters every query by the authenticated
Google subject-derived user ID. It is deliberately distinct from the watcher
feed: workstation agents receive metadata only, while the phone owner receives
their own transcript text and never audio.

**Raw body, not multipart.** A background `URLSession` on iOS can only upload
*from a file*; with a raw body `uploadTask(with:fromFile:)` points straight at
the stored `.m4a` and copies nothing.

**Idempotent on the watch-generated id.** That id is already the filename on
both devices and travels in the WatchConnectivity metadata. A retry cannot
duplicate a row, and an advisory lock around the existence check means two
overlapping requests for the same memo cannot both pay OpenAI.

## Local development

```bash
bun install
bun test
bun run typecheck
```

Running it end to end against a real Postgres and a stub OpenAI:

```bash
docker run -d --name wristmemo-pg \
  -e POSTGRES_PASSWORD=dev -e POSTGRES_DB=wristmemo -p 55432:5432 \
  -v "$PWD:$PWD:ro" postgres:16

docker exec -i wristmemo-pg psql "postgres://postgres:dev@localhost:5432/wristmemo" \
  -c "CREATE ROLE wristmemo_local LOGIN PASSWORD 'dev';"

# migrate.sh shells out to psql; point it at the container
printf '#!/bin/sh\nexec docker exec -i wristmemo-pg psql "$@"\n' > /tmp/psql-docker
chmod +x /tmp/psql-docker

PSQL_BIN=/tmp/psql-docker \
DATABASE_URL="postgres://postgres:dev@localhost:5432/wristmemo" \
INGEST_DATABASE_USER=wristmemo_local \
  ./scripts/migrate.sh

DATABASE_URL="postgres://wristmemo_local:dev@localhost:55432/wristmemo" \
GOOGLE_OAUTH_CLIENT_ID=000000000000-example.apps.googleusercontent.com \
GOOGLE_ALLOWED_USER_SUBJECTS=allowed-google-subject \
GOOGLE_WATCHER_SERVICE_ACCOUNTS=WATCHER_SERVICE_ACCOUNT_EMAIL \
OPENAI_API_KEY=... PORT=8787 \
  bun run src/index.ts
```

Setting `DATABASE_URL` switches the connection off the Cloud SQL socket path, so
the same binary runs locally and in Cloud Run.

## Deploying

Ordered, because each step depends on the last. The commands below read three
values from the environment — they are deliberately not hardcoded, since this
repo is public:

```bash
export PROJECT_ID=…      # the GCP project that owns the shared instance
export REGION=us-central1
export SQL_INSTANCE=…    # the existing Cloud SQL instance to attach to
```

**1. Provision everything except the service.** `image` is empty on the first
apply, so the database, identity, secrets and image repository are created
before there is anything to deploy.

`operator_iam_user` has no default and is the one value you must set — it is the
human account that will impersonate the migrator in step 3. `terraform plan`
fails asking for it otherwise.

The deployed workstation watcher uses only the metadata-only HTTPS feed above.
The retired direct-Cloud-SQL experiment is revoked by migration 0004 and the
workstation receives no Cloud SQL IAM permissions. Runtime setup lives in
[`../watcher/README.md`](../watcher/README.md).

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # then set operator_iam_user
terraform init
terraform plan -var-file=terraform.tfvars -out=wristmemo.tfplan
terraform apply wristmemo.tfplan
```

**2. Bootstrap the OpenAI secret.** Its value is set outside Terraform so it
never enters state, a plan, or a log. Google user and workload authentication
uses signed, short-lived ID tokens and therefore needs no shared secret.

```bash
printf %s "$OPENAI_KEY" | gcloud secrets versions add wristmemo-openai-api-key \
  --project="$PROJECT_ID" --data-file=-
```

**3. Migrate.** Uses the same checksum-ledger runner as the neighbouring
service, through a Cloud SQL Auth Proxy authenticated as an operator who can
impersonate a migrator identity.

The migration runs as a dedicated keyless `wristmemo-migrator` identity, which
owns the schema. The running service never has those rights, and the
neighbour's migrator is untouched. Start a proxy that impersonates it:

```bash
cloud-sql-proxy --auto-iam-authn --port 55431 \
  --impersonate-service-account wristmemo-migrator@"$PROJECT_ID".iam.gserviceaccount.com \
  "$PROJECT_ID:$REGION:$SQL_INSTANCE"
```

Then, in another shell:

```bash
cd ~/Projects/watch-recorder/src/server
DATABASE_URL="host=127.0.0.1 port=55431 dbname=wristmemo user=wristmemo-migrator@$PROJECT_ID.iam sslmode=disable" \
INGEST_DATABASE_USER="wristmemo-ingest@$PROJECT_ID.iam" \
  ./scripts/migrate.sh
```

The runner records filename plus SHA-256 in `wristmemo.migration_ledger`. A
migration that changed after it was applied fails before any SQL runs.

**4. Build, push, deploy.**

```bash
gcloud builds submit --project="$PROJECT_ID" --config=cloudbuild.yaml \
  --substitutions=_IMAGE="$(terraform -chdir=terraform output -raw image_repository)/wristmemo-ingest:$(git rev-parse --short=12 HEAD)" .
```

Resolve the resulting digest, put it in `terraform.tfvars` as `image` (it must
be `...@sha256:...`; Terraform rejects a mutable tag), then plan and apply again.

**5. Configure Google Sign-In on the phone.** Create one Google OAuth Web client
as the backend audience and one iOS client for the WristMemo bundle ID. Enable
Google OAuth App Check for the iOS client with the Apple Team ID. Copy the
ignored local config example and set the endpoint, both client IDs, and the
reversed iOS client ID:

```bash
cp ../../src/swift_app/Config/Signing.local.xcconfig.example \
   ../../src/swift_app/Config/Signing.local.xcconfig
```

The user signs in once on the phone. Google Sign-In stores and silently refreshes
its own session; WristMemo does not persist a custom bearer credential. Missing
or expired auth leaves memos pending and visible rather than dropping audio.

## Deployment status

Actual projects, regions, service URLs, database instances, OAuth client IDs and
IAM identities belong only in ignored local configuration. The public endpoint
is expected: application auth verifies Google's signature, issuer, exact OAuth
audience, token expiry, and an explicit user-subject or service-account
allowlist before handling a protected request.

Verified locally against Postgres 16 in Docker with a stub OpenAI:

- migration applies, is idempotent on re-run, and fails closed when a migration
  file changes after being applied
- a real 18 KB AAC memo streams through byte-exact and lands as a row with the
  routing prefix split into `route` and `body`
- three identical POSTs produce **one** OpenAI call and **one** row
- the generated `tsvector` column answers `websearch_to_tsquery`

Verified against **live GCP**:

- `terraform apply` added 18 resources, **0 changed, 0 destroyed** — the shared
  instance was not touched
- the migration ran on the real instance as `wristmemo-migrator`
- `/readyz` returns 200 from Cloud Run, which exercises the whole database path:
  the `/cloudsql` Unix socket, the metadata-server token fetch, and IAM database
  auth as a `CLOUD_IAM_SERVICE_ACCOUNT`
- `401` unauthenticated and `400` on a malformed id, from the deployed service

**Working end to end in production.** A real 3.2 s AAC memo POSTed to the live
service returned `204` in 1.9 s and landed as:

| column | value |
|---|---|
| `transcript` | `Investment idea: Buy more NVDA before earnings.` |
| `route` | `investment idea` |
| `body` | `Buy more NVDA before earnings.` |
| `model` | `gpt-4o-transcribe` |

A second identical POST also returned `204` and produced **no** second row and
no second OpenAI call. `websearch_to_tsquery('english','NVDA')` finds it.

Isolation was checked directly against the shared instance: the ingest identity
has `USAGE` on its own schema and is refused on the neighbouring one —
*permission denied for schema …*. All neighbouring Cloud Run services stayed
healthy through the rollout.

### On the model id

`OPENAI_MODEL` is `gpt-4o-transcribe`. An earlier value of `gpt-transcribe` is
in fact listed among this account's models — but it was never confirmed against
the `/audio/transcriptions` endpoint, because the credit error short-circuits
before any model validation happens.

The wider point stands regardless: **nothing catches a bad model id before
production.** `config.ts` validates only that the variable is *present*, and
`transcribe.ts` passes the string through as a multipart field, so the service
boots clean and fails on the first real memo as a `502`. Alternatives are
`gpt-4o-mini-transcribe` (cheaper) and `whisper-1` (older).
