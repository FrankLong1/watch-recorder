# WristMemo Codex desktop watcher

This is the deliberately harmless WristMemo → workstation → Codex desktop
integration. Once a memo has been transcribed and committed to Cloud SQL, the
watcher creates one normal, interactive Codex task in `/home/user` and asks it
only:

```text
Reply with exactly: hello world
```

It never receives audio, transcript text, summaries, routes, or other memo
content.

```text
watch → phone → Cloud Run transcription → Cloud SQL row
                                          │
                                          ▼
                    metadata-only HTTPS feed → workstation watcher
                                                │
                                                ▼
                         local Codex app-server over stdio
                                                │
                                                ▼
                         interactive task in the Codex desktop app
```

## Experimental app-visibility boundary

`codex exec` is non-interactive automation. It can persist CLI history, but it
does not create a task owned by the desktop app's remote-project session.

The watcher starts `codex app-server --stdio` as a short-lived local child and
performs the documented app-server `initialize` → `thread/start` → `turn/start`
flow. A real end-to-end test proved that the resulting non-ephemeral thread is
currently discovered by the desktop app's saved SSH project and can be steered
there. No TCP, WebSocket, or Unix listener is opened by the watcher.

That discovery is a compatibility proof, not a documented desktop task-creation
API. The official [App Server](https://learn.chatgpt.com/docs/app-server) guide
positions the protocol as the foundation for rich clients and directs job
automation to the SDK. The official
[Remote connections](https://learn.chatgpt.com/docs/remote-connections) guide
documents the desktop app starting and managing its own remote app server; it
does not promise discovery of threads created by an independent process. Keep
this stage harmless, monitor it after Codex upgrades, and fall back to a visible
metadata queue if that compatibility behavior stops working.

The SSH host and `/home/user` must first be saved in Codex desktop as described
in the official [Remote connections](https://learn.chatgpt.com/docs/remote-connections)
guide. Failures before `thread/start` is sent remain `pending` and retry with
exponential backoff. Once the request may have reached app-server, the record is
`interrupted` even if no thread ID returned: the operator must inspect recent
tasks before explicitly confirming that a retry is safe. This closes the
automatic duplicate window without pretending the two systems share an atomic
transaction.

## Privacy and access

The remote workstation does not connect to Cloud SQL directly. Cloud Run
exposes a Google-identity-protected feed containing only memo UUIDs and
transcription timestamps. The watcher obtains a short-lived, audience-bound ID
token for its attached service account from the Google metadata server. There
is no downloaded key or persistent watcher secret. The task prompt is fixed in
source and is never constructed from memo data.

The feed URL must be HTTPS and cannot contain credentials, a query, or a
fragment. The watcher starts Codex with an explicit environment allowlist, so
Google configuration and unrelated service credentials do not cross into the
child process.

Tasks run with:

- working directory `/home/user`;
- approval policy `never`;
- read-only sandbox; and
- network access disabled for the turn.

The watcher persists only its metadata ledger (`state.json`), poll health,
service PIDs and logs. It does not create per-task JSONL or final-message files.

## Remote install

Copy this directory to a retained `~/wristmemo-watcher` directory on
the specific workstation, then:

```bash
cd ~/wristmemo-watcher
cp watcher.env.example watcher.env
# Set the real Cloud Run URL and OAuth server client ID in watcher.env.
chmod 600 watcher.env
source watcher.env
./run.sh --bootstrap
./service.sh install
```

Bootstrap is intentional: enabling the integration must not replay historical
memos. `service.sh install` creates the user-owned startup item
`~/.workstation/startup.d/120-wristmemo-watcher.sh` used by the workstation's
retained-home startup dispatcher. It also starts a supervisor immediately. The
supervisor restarts the watcher after a crash; the startup dispatcher restarts
the supervisor after a workstation restart. No root service is installed.

The workstation remains an interactive environment: when it is stopped, memo
metadata waits safely in Cloud SQL. Availability of the workstation itself is
owned by the existing workstation lifecycle controls, not this watcher.

## Status and repair

```bash
./service.sh status
tail -f service/watcher.log
source watcher.env
./run.sh --status
WRISTMEMO_WATCHER_RETRY_ID=<memo-id> ./run.sh --retry
```

`--status` reports counts plus metadata-only attention records. A `pending`
record has not created a task and is safe to retry. An `interrupted` record with
a `threadId` already has an app-visible task. An interrupted record with only a
`threadRequestStartedAt` is uncertain because app-server may have committed the
thread before its response was lost. `--retry` refuses both cases by default.
It also reports the last successful feed poll and exits nonzero when that
heartbeat is stale.

`--retry`, `--once`, and `--bootstrap` take an exclusive local lock. Stop the
service before an explicit repair that needs the lock:

```bash
./service.sh stop
WRISTMEMO_WATCHER_RETRY_ID=<memo-id> ./run.sh --retry
./service.sh start
```

For an uncertain record, first inspect recent `/home/user` tasks in the desktop
app. Only when no matching task exists, run the stopped service's repair once
with both `WRISTMEMO_WATCHER_RETRY_ID=<memo-id>` and
`WRISTMEMO_WATCHER_CONFIRM_NO_TASK=1`.

To remove only the managed startup item and running supervisor while retaining
the state and logs:

```bash
./service.sh remove
```
