/// WristMemo → Codex desktop wiring watcher.
///
/// This intentionally does not give Codex the memo transcript. It proves the
/// hand-off with one harmless, app-visible task per newly transcribed memo,
/// whose only instruction is to reply "hello world". Audio is never available
/// here.

import { spawn } from "node:child_process";
import { chmod, mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { join } from "node:path";
import readline from "node:readline";

type RunStatus = "ignored" | "pending" | "started" | "succeeded" | "failed" | "interrupted";

export interface RunRecord {
  status: RunStatus;
  discoveredAt: string;
  startedAt?: string;
  threadRequestStartedAt?: string;
  completedAt?: string;
  attempts?: number;
  threadId?: string;
  turnId?: string;
  nextAttemptAt?: string;
  error?: string;
}

interface PollState {
  lastAttemptAt?: string;
  lastSucceededAt?: string;
  lastFailedAt?: string;
  consecutiveFailures: number;
  nextAttemptAt?: string;
  error?: string;
}

export interface WatcherState {
  version: 1;
  bootstrappedAt?: string;
  cursor?: MemoCursor;
  poll?: PollState;
  memos: Record<string, RunRecord>;
}

export interface MemoCursor {
  id: string;
  transcribedAt: string;
}

export interface Config {
  feedUrl: string;
  googleAudience: string;
  pollMs: number;
  batchSize: number;
  root: string;
  codexBin: string;
  taskCwd: string;
  taskTimeoutMs: number;
  feedTimeoutMs: number;
}

interface RpcMessage {
  id?: number;
  method?: string;
  params?: Record<string, unknown>;
  result?: Record<string, unknown>;
  error?: { code?: number; message?: string };
}

interface AppVisibleTaskResult {
  threadId: string;
  turnId: string;
}

export const HELLO_WORLD_PROMPT = "Reply with exactly: hello world";
const EXPECTED_REPLY = "hello world";
const DEFAULT_ROOT = process.env.WRISTMEMO_WATCHER_HOME ?? join(process.env.HOME ?? ".", "wristmemo-watcher");

function positiveInteger(name: string, fallback: number): number {
  const raw = process.env[name]?.trim();
  if (!raw) return fallback;
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value <= 0) throw new Error(`${name} must be a positive integer`);
  return value;
}

function required(name: string): string {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required`);
  return value;
}

export function validatedFeedUrl(raw: string): string {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new Error("WRISTMEMO_WATCHER_FEED_URL must be an absolute HTTPS URL");
  }
  if (url.protocol !== "https:" || !url.hostname || url.username || url.password || url.search || url.hash) {
    throw new Error("WRISTMEMO_WATCHER_FEED_URL must be an absolute HTTPS URL without credentials, query, or fragment");
  }
  return url.toString().replace(/\/$/, "");
}

/// The app-server only needs process basics and its own local configuration.
/// In particular, it must never inherit Google metadata or unrelated
/// credentials that happened to exist in the watcher's service environment.
export function codexChildEnvironment(source: NodeJS.ProcessEnv = process.env): NodeJS.ProcessEnv {
  const allowed = new Set([
    "PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "TERM", "COLORTERM",
    "LANG", "NO_COLOR", "CODEX_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME",
    "SSL_CERT_FILE", "SSL_CERT_DIR", "__CF_USER_TEXT_ENCODING",
  ]);
  return Object.fromEntries(
    Object.entries(source).filter(([key, value]) => value !== undefined && (allowed.has(key) || key.startsWith("LC_"))),
  );
}

export function loadConfig(): Config {
  const home = process.env.HOME ?? ".";
  return {
    feedUrl: validatedFeedUrl(required("WRISTMEMO_WATCHER_FEED_URL")),
    googleAudience: required("WRISTMEMO_GOOGLE_AUDIENCE"),
    pollMs: positiveInteger("WRISTMEMO_WATCHER_POLL_MS", 60_000),
    batchSize: positiveInteger("WRISTMEMO_WATCHER_BATCH_SIZE", 20),
    root: DEFAULT_ROOT,
    codexBin: process.env.WRISTMEMO_WATCHER_CODEX_BIN?.trim() || "codex",
    taskCwd: process.env.WRISTMEMO_WATCHER_TASK_CWD?.trim() || home,
    taskTimeoutMs: positiveInteger("WRISTMEMO_WATCHER_TASK_TIMEOUT_MS", 10 * 60_000),
    feedTimeoutMs: positiveInteger("WRISTMEMO_WATCHER_FEED_TIMEOUT_MS", 30_000),
  };
}

function emptyState(): WatcherState {
  return { version: 1, memos: {} };
}

export async function readState(path: string): Promise<WatcherState> {
  try {
    const parsed: unknown = JSON.parse(await readFile(path, "utf8"));
    if (!parsed || typeof parsed !== "object") throw new Error("not an object");
    const state = parsed as Partial<WatcherState>;
    if (state.version !== 1 || !state.memos || typeof state.memos !== "object") {
      throw new Error("wrong shape");
    }
    return state as WatcherState;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return emptyState();
    throw new Error(`could not read watcher state: ${error instanceof Error ? error.message : "invalid JSON"}`);
  }
}

export async function writeState(path: string, state: WatcherState): Promise<void> {
  const temporary = `${path}.${process.pid}.tmp`;
  await writeFile(temporary, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });
  await rename(temporary, path);
}

export function appServerArgs(): string[] {
  return ["app-server", "--stdio"];
}

export function threadStartRequest(config: Pick<Config, "taskCwd">): RpcMessage {
  return {
    method: "thread/start",
    id: 1,
    params: {
      cwd: config.taskCwd,
      approvalPolicy: "never",
      sandbox: "read-only",
    },
  };
}

export function turnStartRequest(
  config: Pick<Config, "taskCwd">,
  threadId: string,
): RpcMessage {
  return {
    method: "turn/start",
    id: 2,
    params: {
      threadId,
      input: [{ type: "text", text: HELLO_WORLD_PROMPT }],
      cwd: config.taskCwd,
      approvalPolicy: "never",
      sandboxPolicy: { type: "readOnly", networkAccess: false },
    },
  };
}

function rpcError(message: RpcMessage, fallback: string): Error | undefined {
  if (!message.error) return undefined;
  const code = message.error.code === undefined ? "unknown" : String(message.error.code);
  return new Error(`${fallback}: ${message.error.message ?? "app-server error"} (${code})`);
}

function taskError(message: string, threadId?: string): Error & { threadId?: string } {
  return Object.assign(new Error(message), threadId ? { threadId } : {});
}

function finalAgentReply(params: Record<string, unknown> | undefined): string | undefined {
  const item = params?.item as { type?: unknown; text?: unknown; phase?: unknown } | undefined;
  if (item?.type !== "agentMessage" || typeof item.text !== "string") return undefined;
  if (item.phase !== null && item.phase !== undefined && item.phase !== "final_answer") return undefined;
  return item.text;
}

function replyFromCompletedTurn(params: Record<string, unknown> | undefined): string | undefined {
  const turn = params?.turn as { items?: unknown } | undefined;
  if (!Array.isArray(turn?.items)) return undefined;
  const messages = turn.items.filter(
    (item): item is { type: "agentMessage"; text: string; phase?: unknown } =>
      !!item &&
      typeof item === "object" &&
      (item as { type?: unknown }).type === "agentMessage" &&
      typeof (item as { text?: unknown }).text === "string",
  );
  return messages.at(-1)?.text;
}

export async function runAppVisibleTask(
  config: Pick<Config, "codexBin" | "taskCwd" | "taskTimeoutMs">,
  onThreadCreated: (threadId: string) => Promise<void>,
  onThreadRequestStarting: () => Promise<void> = async () => {},
): Promise<AppVisibleTaskResult> {
  return await new Promise<AppVisibleTaskResult>((resolve, reject) => {
    const child = spawn(config.codexBin, appServerArgs(), {
      cwd: config.taskCwd,
      env: codexChildEnvironment(),
      stdio: ["pipe", "pipe", "pipe"],
    });
    const lines = readline.createInterface({ input: child.stdout });
    let settled = false;
    let threadId: string | undefined;
    let turnId: string | undefined;
    let assistantReply: string | undefined;
    let stderr = "";
    let messageChain = Promise.resolve();

    const cleanup = () => {
      clearTimeout(timeout);
      lines.close();
      child.stdin.end();
      if (child.exitCode === null) child.kill("SIGTERM");
    };
    const fail = (error: unknown) => {
      if (settled) return;
      settled = true;
      cleanup();
      const base = error instanceof Error ? error.message : "Codex app-server task failed";
      reject(taskError(base, threadId));
    };
    const succeed = () => {
      if (settled || !threadId || !turnId) return;
      settled = true;
      cleanup();
      resolve({ threadId, turnId });
    };
    const send = (message: RpcMessage) => {
      if (!child.stdin.writable) throw new Error("Codex app-server closed its input");
      child.stdin.write(`${JSON.stringify(message)}\n`);
    };

    const timeout = setTimeout(
      () => fail(new Error(`Codex task did not complete within ${config.taskTimeoutMs} ms`)),
      config.taskTimeoutMs,
    );

    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk: string) => {
      stderr = `${stderr}${chunk}`.slice(-4_096);
    });
    child.once("error", fail);
    child.once("close", (code) => {
      if (settled) return;
      const detail = stderr.trim() ? `: ${stderr.trim()}` : "";
      fail(new Error(`Codex app-server exited with ${code ?? "no exit code"}${detail}`));
    });

    const handleMessage = async (message: RpcMessage): Promise<void> => {
      if (message.id === 0) {
        const error = rpcError(message, "Codex app-server initialization failed");
        if (error) throw error;
        send({ method: "initialized", params: {} });
        // Persist the ambiguous boundary before sending thread/start. A crash
        // after the request is written but before its response arrives cannot
        // prove whether app-server created the thread, so it must not retry
        // automatically.
        await onThreadRequestStarting();
        send(threadStartRequest(config));
        return;
      }
      if (message.id === 1) {
        const error = rpcError(message, "Codex thread creation failed");
        if (error) throw error;
        const thread = message.result?.thread as { id?: unknown } | undefined;
        if (typeof thread?.id !== "string") throw new Error("Codex thread creation returned no thread id");
        threadId = thread.id;
        await onThreadCreated(threadId);
        send(turnStartRequest(config, threadId));
        return;
      }
      if (message.id === 2) {
        const error = rpcError(message, "Codex turn creation failed");
        if (error) throw error;
        const turn = message.result?.turn as { id?: unknown } | undefined;
        if (typeof turn?.id !== "string") throw new Error("Codex turn creation returned no turn id");
        turnId = turn.id;
        return;
      }
      if (message.method === "item/completed") {
        const reply = finalAgentReply(message.params);
        if (reply !== undefined) assistantReply = reply;
        return;
      }
      if (message.method !== "turn/completed") return;

      const completedThreadId = message.params?.threadId;
      if (typeof completedThreadId === "string" && threadId && completedThreadId !== threadId) return;
      const turn = message.params?.turn as { id?: unknown; status?: unknown } | undefined;
      if (typeof turn?.id === "string") turnId = turn.id;
      if (turn?.status !== "completed") {
        throw new Error(`Codex task ended with status ${String(turn?.status ?? "unknown")}`);
      }
      assistantReply ??= replyFromCompletedTurn(message.params);
      if (assistantReply?.trim() !== EXPECTED_REPLY) {
        throw new Error("Codex task completed without the expected hello-world reply");
      }
      succeed();
    };

    lines.on("line", (line) => {
      messageChain = messageChain
        .then(async () => {
          let message: RpcMessage;
          try {
            message = JSON.parse(line) as RpcMessage;
          } catch {
            throw new Error("Codex app-server returned invalid JSON");
          }
          await handleMessage(message);
        })
        .catch(fail);
    });

    send({
      method: "initialize",
      id: 0,
      params: {
        clientInfo: {
          name: "wristmemo_watcher",
          title: "WristMemo Watcher",
          version: "0.1.0",
        },
        capabilities: {
          optOutNotificationMethods: ["item/agentMessage/delta"],
        },
      },
    });
  });
}

function timestamp(): string {
  return new Date().toISOString();
}

function isTerminal(status: RunStatus): boolean {
  return status === "ignored" || status === "succeeded" || status === "failed" || status === "interrupted";
}

export function retryDelayMs(attempts: number): number {
  return Math.min(60_000 * 2 ** Math.max(0, attempts - 1), 15 * 60_000);
}

function attemptIsDue(record: RunRecord): boolean {
  return !record.nextAttemptAt || Date.parse(record.nextAttemptAt) <= Date.now();
}

const FIRST_CURSOR: MemoCursor = {
  id: "00000000-0000-0000-0000-000000000000",
  transcribedAt: "1970-01-01T00:00:00.000Z",
};

const GOOGLE_IDENTITY_ENDPOINT =
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity";

/// Cloud Workstations exposes its attached service account through the Google
/// metadata server. The returned OIDC token is short-lived and audience-bound;
/// it is neither written to disk nor inherited by Codex.
export async function googleIdentityToken(
  audience: string,
  timeoutMs: number,
  fetchImpl: typeof fetch = fetch,
): Promise<string> {
  const url = new URL(GOOGLE_IDENTITY_ENDPOINT);
  url.searchParams.set("audience", audience);
  url.searchParams.set("format", "full");
  const response = await fetchImpl(url, {
    headers: { "Metadata-Flavor": "Google" },
    signal: AbortSignal.timeout(timeoutMs),
  });
  if (!response.ok) throw new Error(`Google metadata identity endpoint returned ${response.status}`);
  const token = (await response.text()).trim();
  if (token.split(".").length !== 3) throw new Error("Google metadata identity endpoint returned an invalid token");
  return token;
}

export async function listMemos(
  config: Pick<Config, "batchSize" | "feedTimeoutMs" | "feedUrl" | "googleAudience">,
  cursor: MemoCursor,
  fetchImpl: typeof fetch = fetch,
  identityToken: () => Promise<string> = () =>
    googleIdentityToken(config.googleAudience, config.feedTimeoutMs, fetchImpl),
): Promise<MemoCursor[]> {
  const url = new URL(`${validatedFeedUrl(config.feedUrl)}/v1/watcher/memos`);
  url.searchParams.set("after", cursor.transcribedAt);
  url.searchParams.set("after_id", cursor.id);
  url.searchParams.set("limit", String(config.batchSize));
  const response = await fetchImpl(url, {
    headers: { Authorization: `Bearer ${await identityToken()}` },
    signal: AbortSignal.timeout(config.feedTimeoutMs),
  });
  if (!response.ok) throw new Error(`watcher feed returned ${response.status}`);
  const payload: unknown = await response.json();
  const memos = (payload as { memos?: unknown })?.memos;
  if (!Array.isArray(memos)) throw new Error("watcher feed returned an invalid payload");
  return memos.map((memo): MemoCursor => {
    const record = memo as Partial<MemoCursor>;
    if (typeof record.id !== "string" || typeof record.transcribedAt !== "string" || !Number.isFinite(Date.parse(record.transcribedAt))) {
      throw new Error("watcher feed returned an invalid memo cursor");
    }
    return { id: record.id, transcribedAt: record.transcribedAt };
  });
}

async function processMemo(
  config: Config,
  statePath: string,
  state: WatcherState,
  id: string,
): Promise<void> {
  const prior = state.memos[id] ?? { status: "pending", discoveredAt: timestamp() };
  const attempts = (prior.attempts ?? 0) + 1;
  state.memos[id] = {
    ...prior,
    status: "started",
    attempts,
    startedAt: timestamp(),
    completedAt: undefined,
    nextAttemptAt: undefined,
    error: undefined,
  };
  await writeState(statePath, state);

  try {
    const result = await runAppVisibleTask(
      config,
      async (threadId) => {
        state.memos[id].threadId = threadId;
        await writeState(statePath, state);
      },
      async () => {
        state.memos[id].threadRequestStartedAt = timestamp();
        await writeState(statePath, state);
      },
    );
    state.memos[id] = {
      ...state.memos[id],
      status: "succeeded",
      completedAt: timestamp(),
      threadId: result.threadId,
      turnId: result.turnId,
    };
  } catch (error) {
    const createdThreadId = (error as { threadId?: unknown }).threadId;
    const threadId = typeof createdThreadId === "string" ? createdThreadId : state.memos[id].threadId;
    if (threadId || state.memos[id].threadRequestStartedAt) {
      state.memos[id] = {
        ...state.memos[id],
        status: "interrupted",
        completedAt: timestamp(),
        threadId,
        error: threadId
          ? `${error instanceof Error ? error.message : "Codex task did not finish"}; task exists, inspect it instead of creating a duplicate`
          : `${error instanceof Error ? error.message : "Codex thread creation became uncertain"}; inspect recent tasks before explicitly confirming a retry`,
      };
    } else {
      state.memos[id] = {
        ...state.memos[id],
        status: "pending",
        completedAt: timestamp(),
        nextAttemptAt: new Date(Date.now() + retryDelayMs(attempts)).toISOString(),
        error: error instanceof Error ? error.message : "could not create a Codex task",
      };
    }
  }
  await writeState(statePath, state);
  console.log(
    JSON.stringify({
      message: "app-visible Codex task attempt finished",
      id,
      status: state.memos[id].status,
      threadId: state.memos[id].threadId ?? null,
      nextAttemptAt: state.memos[id].nextAttemptAt ?? null,
    }),
  );
}

async function bootstrap(config: Config, statePath: string): Promise<void> {
  const state = await readState(statePath);
  if (state.bootstrappedAt) throw new Error(`already bootstrapped at ${state.bootstrappedAt}`);
  let ignored = 0;
  let cursor = state.cursor ?? FIRST_CURSOR;
  for (;;) {
    const memos = await pollMemos(config, statePath, state, cursor);
    if (memos.length === 0) break;
    const discoveredAt = timestamp();
    for (const memo of memos) state.memos[memo.id] = { status: "ignored", discoveredAt };
    ignored += memos.length;
    cursor = memos.at(-1)!;
    state.cursor = cursor;
    await writeState(statePath, state);
    if (memos.length < config.batchSize) break;
  }
  state.bootstrappedAt = timestamp();
  await writeState(statePath, state);
  console.log(JSON.stringify({ message: "bootstrap complete", ignored }));
}

export async function markInterrupted(statePath: string, state: WatcherState): Promise<void> {
  let changed = false;
  for (const record of Object.values(state.memos)) {
    if (record.status !== "started") continue;
    record.completedAt = timestamp();
    if (record.threadId || record.threadRequestStartedAt) {
      record.status = "interrupted";
      record.error = record.threadId
        ? "watcher stopped after creating the task; inspect that task instead of creating a duplicate"
        : "watcher stopped after thread creation became uncertain; inspect recent tasks before explicitly confirming a retry";
    } else {
      record.status = "pending";
      record.nextAttemptAt = timestamp();
      record.error = "watcher stopped before thread creation was requested; retry is safe";
    }
    changed = true;
  }
  if (changed) await writeState(statePath, state);
}

export function pollIsStale(
  state: WatcherState,
  config: Pick<Config, "feedTimeoutMs" | "pollMs">,
  now = Date.now(),
): boolean {
  const lastSucceededAt = state.poll?.lastSucceededAt;
  if (!lastSucceededAt) return true;
  const lastSucceededMs = Date.parse(lastSucceededAt);
  if (!Number.isFinite(lastSucceededMs)) return true;
  const staleAfterMs = Math.max(config.pollMs * 3, config.feedTimeoutMs * 2 + config.pollMs);
  return lastSucceededMs + staleAfterMs < now;
}

async function status(config: Config, statePath: string): Promise<void> {
  const state = await readState(statePath);
  const counts: Record<RunStatus, number> = {
    ignored: 0,
    pending: 0,
    started: 0,
    succeeded: 0,
    failed: 0,
    interrupted: 0,
  };
  const attention: Array<Pick<RunRecord, "status" | "attempts" | "threadId" | "threadRequestStartedAt" | "nextAttemptAt" | "error"> & { id: string }> = [];
  for (const [id, record] of Object.entries(state.memos)) {
    counts[record.status] += 1;
    if (record.status === "pending" || record.status === "failed" || record.status === "interrupted") {
      attention.push({
        id,
        status: record.status,
        attempts: record.attempts,
        threadId: record.threadId,
        threadRequestStartedAt: record.threadRequestStartedAt,
        nextAttemptAt: record.nextAttemptAt,
        error: record.error,
      });
    }
  }
  const stale = pollIsStale(state, config);
  console.log(JSON.stringify({
    healthy: !stale,
    bootstrappedAt: state.bootstrappedAt ?? null,
    poll: state.poll ?? null,
    ...counts,
    attention,
  }, null, 2));
  if (stale) process.exitCode = 2;
}

async function retry(config: Config, statePath: string, id: string): Promise<void> {
  const state = await readState(statePath);
  const prior = state.memos[id];
  if (!prior || (prior.status !== "pending" && prior.status !== "failed" && prior.status !== "interrupted")) {
    throw new Error(`${id} is not a pending, failed, or interrupted Codex task`);
  }
  if (prior.threadId) {
    throw new Error(`${id} already created Codex task ${prior.threadId}; inspect that task instead of creating a duplicate`);
  }
  if (prior.threadRequestStartedAt && process.env.WRISTMEMO_WATCHER_CONFIRM_NO_TASK !== "1") {
    throw new Error(
      `${id} may already have created a Codex task; inspect recent tasks, then set WRISTMEMO_WATCHER_CONFIRM_NO_TASK=1 only if none exists`,
    );
  }
  prior.status = "pending";
  prior.threadRequestStartedAt = undefined;
  prior.nextAttemptAt = undefined;
  await writeState(statePath, state);
  await processMemo(config, statePath, state, id);
}

async function watch(config: Config, statePath: string, once: boolean): Promise<void> {
  const state = await readState(statePath);
  if (!state.bootstrappedAt) throw new Error("run with --bootstrap first so historical memos are not replayed");
  await markInterrupted(statePath, state);

  do {
    let memos: MemoCursor[];
    try {
      memos = await pollMemos(config, statePath, state, state.cursor ?? FIRST_CURSOR);
    } catch (error) {
      console.error(JSON.stringify({
        message: "watcher feed poll failed",
        consecutiveFailures: state.poll?.consecutiveFailures ?? 1,
        nextAttemptAt: state.poll?.nextAttemptAt ?? null,
        error: error instanceof Error ? error.message : "watcher feed failed",
      }));
      if (once) throw error;
      const nextAttemptAt = Date.parse(state.poll?.nextAttemptAt ?? timestamp());
      await Bun.sleep(Math.max(0, nextAttemptAt - Date.now()));
      continue;
    }
    for (const memo of memos) {
      let record = state.memos[memo.id];
      if (!record) {
        record = { status: "pending", discoveredAt: timestamp() };
        state.memos[memo.id] = record;
        await writeState(statePath, state);
      }
      if (!isTerminal(record.status) && attemptIsDue(record)) {
        await processMemo(config, statePath, state, memo.id);
        record = state.memos[memo.id];
      }
      if (!isTerminal(record.status)) break;
      state.cursor = memo;
      await writeState(statePath, state);
    }
    if (!once) await Bun.sleep(config.pollMs);
  } while (!once);
}

async function pollMemos(
  config: Config,
  statePath: string,
  state: WatcherState,
  cursor: MemoCursor,
): Promise<MemoCursor[]> {
  state.poll = {
    ...state.poll,
    lastAttemptAt: timestamp(),
    consecutiveFailures: state.poll?.consecutiveFailures ?? 0,
  };
  await writeState(statePath, state);
  try {
    const memos = await listMemos(config, cursor);
    state.poll = {
      ...state.poll,
      lastSucceededAt: timestamp(),
      consecutiveFailures: 0,
      nextAttemptAt: undefined,
      error: undefined,
    };
    await writeState(statePath, state);
    return memos;
  } catch (error) {
    const consecutiveFailures = (state.poll?.consecutiveFailures ?? 0) + 1;
    state.poll = {
      ...state.poll,
      lastFailedAt: timestamp(),
      consecutiveFailures,
      nextAttemptAt: new Date(Date.now() + retryDelayMs(consecutiveFailures)).toISOString(),
      error: (error instanceof Error ? error.message : "watcher feed failed").slice(0, 1_000),
    };
    await writeState(statePath, state);
    throw error;
  }
}

async function main(): Promise<void> {
  const config = loadConfig();
  await mkdir(config.root, { recursive: true, mode: 0o700 });
  await chmod(config.root, 0o700);
  const statePath = join(config.root, "state.json");
  const command = process.argv[2] ?? "watch";
  if (command === "--status") return status(config, statePath);

  if (command === "--bootstrap") return bootstrap(config, statePath);
  if (command === "--once") return watch(config, statePath, true);
  if (command === "--retry") return retry(config, statePath, required("WRISTMEMO_WATCHER_RETRY_ID"));
  if (command === "watch") return watch(config, statePath, false);
  throw new Error(`unknown command ${command}; expected watch, --once, --bootstrap, --retry, or --status`);
}

if (import.meta.main) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : error);
    process.exitCode = 1;
  });
}
