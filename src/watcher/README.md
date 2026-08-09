# WristMemo transcript-to-Codex watcher

Version `1.0.2` is the production polling architecture. Every new, non-empty
memo for one explicitly configured owner creates one visible Codex task in one
explicitly configured project folder. The transcript is the task input.

The automatic first turn is deliberately read-only. It may inspect the project
and produce an answer, plan, or draft, but it runs with a read-only sandbox,
network disabled, approval policy `never`, MCP configuration emptied, and an
instruction not to invoke plugins, apps, MCP, or skills. A human continuation
in the visible task is the approval boundary for edits and consequential work.

```text
watch -> phone -> Cloud Run transcription -> owner-scoped Postgres row
                                              |
                                              v
                    transcript HTTPS feed -> polling watcher (20 s)
                                              |
                                              v
                         one long-lived local Codex app-server over stdio
                                              |
                                              v
                         visible, interactive task in the configured project
```

There is no Pub/Sub, custom WebSocket, workstation Cloud SQL access, or audio
path. Polling is authoritative.

## Trust and retention boundaries

The service-account feed is bound at server startup to exactly one immutable
Google owner subject. Every list and UUID re-fetch query includes that owner's
derived database identity. A valid watcher identity therefore cannot retrieve
another user's transcript.

Transcript text exists in these places after transcription:

- Postgres, as the durable transcript;
- the owner's protected phone transcript cache;
- transient watcher process memory while a task is submitted; and
- the visible Codex thread history and model-provider processing implied by
  running that task.

The watcher never stores transcript text in its ledger or logs and discards
app-server stderr. It receives no audio. The ledger stores only UUIDs,
timestamps, attempts, health, and thread/turn IDs.

The Codex child receives an explicit environment allowlist, so Google tokens
and unrelated service environment credentials do not cross the process
boundary. Cross-process desktop discovery currently requires the operator's
normal Codex home; that prevents complete filesystem/config isolation. The
read-only sandbox, network-off turn, empty MCP config, strict project-path
validation, and prompt boundary are the compensating controls.

## Delivery and crash model

`transcribed_at` is assigned before transaction commit, so a cursor that only
moves forward can skip a slow transaction that commits after a newer row. Each
poll paginates the complete owner-scoped feed from the beginning and deduplicates
by watch-generated UUID. This unbounded scan closes the commit-order hole even
when a transaction remains open for an arbitrarily long time. Each page is
discovered, persisted, and processed before it is released, so transcript
history is never accumulated in watcher memory. Unchanged historical pages do
not rewrite or rescan the full ledger; one fallback ledger scan runs after the
complete feed pass for repairable records missing from the current feed. An old
pending retry fetches its transcript by UUID, so transcript text does not need
to be retained locally.

State is atomically replaced with mode `0600`; each replacement fsyncs the file
and containing directory before an RPC boundary may be crossed. The task boundary is recorded in
this order:

1. persist `threadRequestStartedAt`;
2. send `thread/start`;
3. persist the returned `threadId`;
4. persist `turnRequestStartedAt`;
5. send `turn/start`; and
6. persist the returned `turnId` and mark the memo submitted.

A crash before step 1 is safe to retry. A durable thread ID before step 4 is
safe to resume without creating another visible task. A missing thread response
after step 1, or a missing turn response after step 4, is uncertain and is
never retried automatically. The status output tells an operator to inspect
Codex first.

Retryable pre-boundary failures use exponential backoff and become terminal
after five attempts. A terminal memo remains in the attention list but never
blocks later memos.

The watcher owns one long-lived app-server child. It completes submission when
`turn/start` returns `inProgress`; it does not wait for `turn/completed` and
does not kill a realistic task on a turn timeout. Polling and later task
creation continue while earlier read-only turns run.

## Experimental desktop-discovery compatibility

The documented [App Server](https://learn.chatgpt.com/docs/app-server) protocol
supports `initialize`, `thread/list`, `thread/start`, `thread/resume`, and
`turn/start`. The [remote connections](https://learn.chatgpt.com/docs/remote-connections)
guide documents the desktop app starting its own remote app-server over SSH; it
does not document discovery of threads made by an independent process. That
last step remains a manually verified compatibility dependency.

Runtime config must set
`WRISTMEMO_WATCHER_DESKTOP_DISCOVERY_CODEX_VERSION` to the exact Codex version
for which discovery was manually tested. Startup initializes app-server,
matches its returned user agent to that pinned version, and exercises
`thread/list`. A version mismatch or protocol failure makes compatibility and
overall status unhealthy and prevents submission until re-verified. This check
proves protocol/storage compatibility; the version pin records the separate
manual desktop-visibility proof.

## Image and retained runtime contract

Immutable image-owned files:

```text
/opt/wristmemo-watcher/<version>/
/opt/wristmemo-watcher/current -> <version>
/usr/local/bin/wristmemo-watcher-service
/etc/workstation-startup.d/245-wristmemo-watcher.sh
```

Retained user-owned files:

```text
~/.config/wristmemo-watcher/watcher.env   mode 0600; URLs, audience, project path, version pin
~/.local/state/wristmemo-watcher/         mode 0700; ledger, lock, PIDs, private log
```

No secret, identity token, user project path, transcript, or mutable state is
baked into the image. The watcher gets a short-lived audience-bound ID token
from the attached workstation service account for every feed request; no key is
downloaded.

This repository does not own the `frank-ai-workstation` image. It owns the
versioned source payload, artifact builder with a SHA-256 receipt, installer, and
startup contract under `src/watcher`.
The external image definition that must consume it is:

```text
frank-vm-sandbox/container-images/demo-workstation-image/profiles/frank/
```

That repository's Frank-only profile vendors `wristmemo-watcher-1.0.2.tar.gz`
plus its SHA-256 receipt. Its Dockerfile verifies both the receipt and pinned
digest before extraction, runs `image/install-image-layer.sh`, and then runs
the profile smoke test. The profile manifest and image-contract tests keep the
immutable/runtime boundary observable.

To reproduce the vendored artifact from this source, run:

```bash
src/watcher/image/build-artifact.sh /tmp/wristmemo-watcher-artifacts
```

Building, publishing, pinning, or rolling out the external image remains a
separate approved release operation.

## First runtime configuration

When upgrading the earlier retained-home wiring proof, first run its own
`~/wristmemo-watcher/service.sh remove` and verify that
`~/.workstation/startup.d/120-wristmemo-watcher.sh` is gone. The old and new
ledgers use different roots and must never run together, or both could create a
task for the same newly transcribed memo.

After the image containing this payload is active:

```bash
mkdir -p ~/.config/wristmemo-watcher
chmod 700 ~/.config/wristmemo-watcher
cp /opt/wristmemo-watcher/current/watcher.env.example \
  ~/.config/wristmemo-watcher/watcher.env
chmod 600 ~/.config/wristmemo-watcher/watcher.env
# Edit the private file with the real feed URL, audience, exact project folder,
# and manually verified Codex version.
source ~/.config/wristmemo-watcher/watcher.env
/opt/wristmemo-watcher/current/run.sh --bootstrap
wristmemo-watcher-service install
```

Bootstrap intentionally records existing memos as ignored. It does not replay
history when enabling the watcher.

## Status and repair

```bash
wristmemo-watcher-service status
tail -f ~/.local/state/wristmemo-watcher/watcher.log
source ~/.config/wristmemo-watcher/watcher.env
/opt/wristmemo-watcher/current/run.sh --healthcheck
```

Status reports watcher build, poll heartbeat, compatibility, counts, backlog,
terminal failures, and uncertain records without transcript text. It exits
nonzero when the feed heartbeat is stale or app-server compatibility is not
healthy.

For a safe pre-boundary failure, stop the service and run one explicit retry:

```bash
wristmemo-watcher-service stop
WRISTMEMO_WATCHER_RETRY_ID=<memo-uuid> \
  /opt/wristmemo-watcher/current/run.sh --retry
wristmemo-watcher-service start
```

For an uncertain `thread/start`, first inspect recent tasks. Only when no task
exists may the operator add `WRISTMEMO_WATCHER_CONFIRM_NO_TASK=1`. An uncertain
turn on an already-created thread is never allowed to create a second task;
continue the existing visible task instead.
