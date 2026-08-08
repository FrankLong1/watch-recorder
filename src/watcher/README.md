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

## Why this is app-visible

`codex exec` is non-interactive automation. It can persist CLI history, but it
does not create a task owned by the desktop app's remote-project session.

The watcher starts `codex app-server --stdio` as a short-lived local child,
performs the documented app-server `initialize` → `thread/start` →
`turn/start` flow, and records the returned thread ID. The non-ephemeral thread
is persisted in the remote user's normal Codex history. The desktop app's saved
SSH project discovers that history and presents the thread as a normal remote
task. No TCP, WebSocket, or Unix listener is opened by the watcher, and no
app-server transport is exposed on a network.

The SSH host and `/home/user` must first be saved in Codex desktop as described
in the official [Remote connections](https://learn.chatgpt.com/docs/remote-connections)
guide. If task creation fails before a thread ID is returned, the watcher leaves
the memo `pending` and retries with exponential backoff rather than falling back
to `codex exec`. Once a thread ID exists, an interrupted attempt is not
automatically duplicated; its app-visible task is the repair surface.

## Privacy and access

The remote workstation does not connect to Cloud SQL directly. Cloud Run
exposes a dedicated bearer-token-protected feed containing only memo UUIDs and
transcription timestamps. The watcher token has no upload capability. The task
prompt is fixed in source and is never constructed from memo data.

Tasks run with:

- working directory `/home/user`;
- approval policy `never`;
- read-only sandbox; and
- network access disabled for the turn.

The watcher persists only its metadata ledger (`state.json`), service PIDs and
logs. It does not create per-task JSONL or final-message files.

## Remote install

Copy this directory to the retained `/home/user/wristmemo-watcher` directory on
the specific workstation, then:

```bash
cd ~/wristmemo-watcher
cp watcher.env.example watcher.env
# Set the real Cloud Run URL and dedicated watcher token in watcher.env.
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
a `threadId` already has an app-visible task and must be inspected rather than
duplicated. `--retry` refuses to create a second task when a thread ID is
already recorded.

`--retry`, `--once`, and `--bootstrap` take an exclusive local lock. Stop the
service before an explicit repair that needs the lock:

```bash
./service.sh stop
WRISTMEMO_WATCHER_RETRY_ID=<memo-id> ./run.sh --retry
./service.sh start
```

To remove only the managed startup item and running supervisor while retaining
the state and logs:

```bash
./service.sh remove
```
