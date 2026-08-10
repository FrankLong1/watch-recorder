# Code review handoff — 2026-08-06

Reviewed repository state: pushed `11409f1` on `main`, plus the live
uncommitted worktree diff present during this review. The watch, phone, and
ingest paths were traced end to end so that cross-component failures are
included below.

## Findings

### [P1] Preserve the existing phone copy until WatchConnectivity import succeeds — `src/swift_app/iOSApp/Library/PhoneLibrary.swift:176`

The receive handler removes the durable destination before attempting either
`moveItem` or the fallback `copyItem`, and it discards errors from the fallback.
If either operation fails (for example, a transient I/O failure or full device
storage), the WatchConnectivity inbox file is deleted when this callback
returns and the pre-existing local copy has already been removed. The watch
will still receive a successful transfer completion and mark the memo synced,
so this loses the only audio copy. Import to a same-directory temporary file,
verify the write and sidecar, then atomically replace the destination; if
import fails, retain the existing destination and make the callback failure
observable/recoverable.

### [P1] Make raw-Capture fallback uploads use a format the transcription endpoint can read — `src/swift_app/iOSApp/Ingest/TranscriptionClient.swift:106`

`MemoStore.finalize` intentionally preserves a failed AAC compression as a
`.caf` memo, and `WatchSyncClient` transfers that file. The phone nevertheless
labels every upload `audio/mp4`; the server then wraps the same bytes as
`filename="memo.m4a"` with `Content-Type: audio/mp4` in
`src/server/src/transcribe.ts:49`. A raw PCM CAF fallback is therefore presented as
an M4A file and cannot reliably be decoded by the transcription service. Either
transcode CAF on the phone before upload, or carry the extension/MIME type
through the watch metadata and multipart builder and explicitly support that
format. Add an end-to-end test for the compression-fallback path.

### [P2] Pass the documented deployment values into Terraform — `src/server/README.md:118`

The new `PROJECT_ID`, `REGION`, and `SQL_INSTANCE` shell variables are used by
the later `gcloud` and proxy commands but never by the Terraform commands. The
copied `terraform.tfvars.example` consequently retains its placeholder values,
and the instruction says to edit only `operator_iam_user`; `terraform plan`
will attempt the placeholder project/instance instead of the environment the
reader just configured. Export `TF_VAR_project_id`, `TF_VAR_region`, and
`TF_VAR_sql_instance_name`, pass corresponding `-var` values, or explicitly
instruct the reader to replace all four values in `terraform.tfvars`.

### [P2] Do not let a diagnostic grep terminate watch mode — `sim.sh:143`

`build_errors` returns `grep`'s status. In the new watch-mode `else` branch it
is invoked as a normal command under `set -e -o pipefail`, so any build/install
failure whose log does not include the literal `error:` exits the watch loop
before it prints `build failed` or observes another save. This is easy to hit
for simulator/device connection failures. Make the diagnostic best-effort
(`grep ... || true`, as the test-failure diagnostics already do) so watch mode
continues after every failed iteration.

### [P2] Return a terminal client status for non-retryable transcription failures — `src/server/src/index.ts:140`

`TranscriptionError.retryable == false` represents an upstream 4xx such as an
invalid model or unsupported audio, but the endpoint maps it to HTTP 500. The
phone treats every 5xx as pending and retries indefinitely, so a memo the
server knows is permanently invalid never reaches the visible `.failed` state.
Return a non-retryable 4xx/422-style response (without exposing upstream error
detail) for this branch, and cover the phone/server status contract in a test.

### [P2] Recreate the background URLSession when iOS wakes the app for it — `src/swift_app/iOSApp/App/WristMemoApp.swift:40`

The registered SwiftUI `.backgroundTask(.urlSession(...))` handler is empty,
while `TranscriptionClient` creates the session only from `PhoneLibrary.start`
in the window's `.task`. A background relaunch can therefore run no session
delegate and no `didCompleteWithError` callback; the memo remains persisted as
`.uploading` until the user later opens the UI and recovery requeues it. Build
or activate the singleton `TranscriptionClient` from the background-session
handler, then invoke the stored completion handler only from
`urlSessionDidFinishEvents`.

### [P2] Reference the concept image once instead of embedding a duplicate copy — `docs/research/watch-ultra-bands/index.html:23`

The page contains a 3.6 MB base64 data URL while the exact same 2.7 MB PNG is
also committed at `assets/custom-band-concepts.png` (both hash to
`228f39…00071`). The committed asset is unused, and the encoded inline copy
adds base64 overhead to every page load and makes markup diffs unwieldy. Point
the `img` at `assets/custom-band-concepts.png` and keep a single binary source.

## Assessment and verification

The ingest TypeScript typecheck and test suite pass: 14 tests, 0 failures.
`bash -n sim.sh` and `./sim.sh --help` also pass. The watch unit/UI/harness
suite could not run here because CoreSimulator is unavailable before the
script can select or boot a watch. No automated test currently covers the
WatchConnectivity receive failure, CAF fallback upload, iOS background
relaunch, or the no-`error:` watch-mode build failure above.
