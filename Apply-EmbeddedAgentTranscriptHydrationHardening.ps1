# OpenClaw embedded-agent transcript hydration hardening.
# Applies to descendants of 2ace157.
#
# Root cause addressed:
#   - loadSqliteTranscriptEvents() is "async" but calls the synchronous full transcript loader.
#   - SessionManager.open() synchronously loads + JSON.parse()s the entire transcript.
#   - resolveExistingAttemptTranscriptState() performs a second full transcript read only
#     to answer "does any message event exist?"
#
# Fix:
#   - persistent storage-layer transcript loader worker
#   - genuinely async loadSqliteTranscriptEvents()
#   - indexed has-message existence query on transcript_event_identities
#   - SessionManager.openAsync()
#   - embedded attempt session setup uses openAsync()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Repo = Join-Path $HOME "openclaw"
Set-Location $Repo

$head = (git rev-parse HEAD).Trim()
git merge-base --is-ancestor 2ace157 HEAD
if ($LASTEXITCODE -ne 0) {
    throw "Expected HEAD to descend from 2ace157; current HEAD is $head."
}

function Get-Newline([string]$Text) {
    if ($Text.Contains("`r`n")) { return "`r`n" }
    return "`n"
}

function Convert-Newlines([string]$Text, [string]$Newline) {
    return ($Text -replace "`r`n|`n|`r", $Newline)
}

function Replace-One {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Old,
        [Parameter(Mandatory)][string]$New,
        [Parameter(Mandatory)][string]$Label
    )
    $nl = Get-Newline $Text
    $oldLocal = Convert-Newlines $Old $nl
    $newLocal = Convert-Newlines $New $nl
    $count = ([regex]::Matches($Text, [regex]::Escape($oldLocal))).Count
    if ($count -ne 1) {
        throw "${Label}: expected exactly one anchor match, found $count."
    }
    return $Text.Replace($oldLocal, $newLocal)
}

$encoding = [System.Text.UTF8Encoding]::new($false)
$changes = [ordered]@{}

$clientPath = Join-Path $Repo "src/config/sessions/session-transcript-load-async.ts"
if (Test-Path $clientPath) {
    throw "Refusing to overwrite existing $clientPath"
}
$clientText = @'
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { Worker } from "node:worker_threads";
import type {
  SessionTranscriptReadScope,
  TranscriptEvent,
} from "./session-accessor.sqlite-contract.js";

type WorkerRequest =
  | { id: number; type: "load"; scope: SessionTranscriptReadScope }
  | { id: number; type: "has-message"; scope: SessionTranscriptReadScope };

type WorkerResponse =
  | { id: number; ok: true; result: unknown }
  | { id: number; ok: false; error: { message: string; stack?: string } };

type PendingRequest = {
  resolve: (result: unknown) => void;
  reject: (error: Error) => void;
};

let workerInstance: Worker | undefined;
let nextRequestId = 1;
const pendingRequests = new Map<number, PendingRequest>();
const inFlight = new Map<string, Promise<unknown>>();

function resolveWorkerUrl(currentModuleUrl = import.meta.url): URL {
  const currentPath = fileURLToPath(currentModuleUrl);
  const normalized = currentPath.replaceAll(path.sep, "/");
  const distMarker = "/dist/";
  const distIndex = normalized.lastIndexOf(distMarker);
  if (distIndex >= 0) {
    const distRoot = currentPath.slice(0, distIndex + distMarker.length);
    return pathToFileURL(
      path.join(distRoot, "config", "sessions", "session-transcript-load.worker.js"),
    );
  }
  const extension = path.extname(currentPath) || ".js";
  return new URL(`./session-transcript-load.worker${extension}`, currentModuleUrl);
}

function rejectPending(error: Error): void {
  for (const pending of pendingRequests.values()) {
    pending.reject(error);
  }
  pendingRequests.clear();
  inFlight.clear();
}

function resetWorker(worker: Worker, error?: Error): void {
  if (workerInstance !== worker) {
    return;
  }
  workerInstance = undefined;
  if (error) {
    rejectPending(error);
  }
}

function getWorker(): Worker {
  if (workerInstance) {
    return workerInstance;
  }

  const workerUrl = resolveWorkerUrl();
  const worker = new Worker(workerUrl, {
    execArgv: workerUrl.pathname.endsWith(".ts") ? ["--import", "tsx"] : undefined,
  });
  worker.unref?.();

  worker.on("message", (response: WorkerResponse) => {
    const pending = pendingRequests.get(response.id);
    if (!pending) {
      return;
    }
    pendingRequests.delete(response.id);
    if (response.ok) {
      pending.resolve(response.result);
      return;
    }
    const error = new Error(response.error.message);
    if (response.error.stack) {
      error.stack = response.error.stack;
    }
    pending.reject(error);
  });
  worker.on("error", (error) => resetWorker(worker, error));
  worker.on("exit", (code) => {
    resetWorker(
      worker,
      pendingRequests.size > 0
        ? new Error(`session transcript load worker exited with code ${code}`)
        : undefined,
    );
  });

  workerInstance = worker;
  return worker;
}

function requestWorker<T>(
  type: WorkerRequest["type"],
  scope: SessionTranscriptReadScope,
): Promise<T> {
  const worker = getWorker();
  const id = nextRequestId++;
  return new Promise<T>((resolve, reject) => {
    pendingRequests.set(id, {
      resolve: (result) => resolve(result as T),
      reject,
    });
    try {
      // Node Worker.postMessage is not the browser Window API.
      // oxlint-disable-next-line unicorn/require-post-message-target-origin
      worker.postMessage({ id, type, scope } satisfies WorkerRequest);
    } catch (error) {
      pendingRequests.delete(id);
      reject(error instanceof Error ? error : new Error(String(error)));
    }
  });
}

function scopeKey(scope: SessionTranscriptReadScope): string {
  return [
    scope.agentId ?? "",
    scope.sessionId,
    scope.sessionKey ?? "",
    scope.storePath ?? "",
  ].join("\0");
}

function coalesced<T>(key: string, run: () => Promise<T>): Promise<T> {
  const existing = inFlight.get(key);
  if (existing) {
    return existing as Promise<T>;
  }
  const promise = run().finally(() => {
    if (inFlight.get(key) === promise) {
      inFlight.delete(key);
    }
  });
  inFlight.set(key, promise);
  return promise;
}

export function loadSqliteTranscriptEventsOffThread(
  scope: SessionTranscriptReadScope,
): Promise<TranscriptEvent[]> {
  return coalesced(`load\0${scopeKey(scope)}`, () =>
    requestWorker<TranscriptEvent[]>("load", scope),
  );
}

export function hasSqliteTranscriptMessageEventsOffThread(
  scope: SessionTranscriptReadScope,
): Promise<boolean> {
  return coalesced(`has-message\0${scopeKey(scope)}`, () =>
    requestWorker<boolean>("has-message", scope),
  );
}
'@
$changes[$clientPath] = Convert-Newlines $clientText "`n"

$workerPath = Join-Path $Repo "src/config/sessions/session-transcript-load.worker.ts"
if (Test-Path $workerPath) {
    throw "Refusing to overwrite existing $workerPath"
}
$workerText = @'
import { isMainThread, parentPort } from "node:worker_threads";
import type { SessionTranscriptReadScope } from "./session-accessor.sqlite-contract.js";
import {
  hasSqliteTranscriptMessageEventsSync,
  loadSqliteTranscriptEventsSync,
} from "./session-accessor.sqlite-read.js";

type WorkerRequest =
  | { id: number; type: "load"; scope: SessionTranscriptReadScope }
  | { id: number; type: "has-message"; scope: SessionTranscriptReadScope };

type WorkerResponse =
  | { id: number; ok: true; result: unknown }
  | { id: number; ok: false; error: { message: string; stack?: string } };

function serializeError(error: unknown): { message: string; stack?: string } {
  if (error instanceof Error) {
    return {
      message: error.message,
      ...(error.stack ? { stack: error.stack } : {}),
    };
  }
  return { message: String(error) };
}

if (!isMainThread && parentPort) {
  parentPort.on("message", (request: WorkerRequest) => {
    let response: WorkerResponse;
    try {
      const result =
        request.type === "load"
          ? loadSqliteTranscriptEventsSync(request.scope)
          : hasSqliteTranscriptMessageEventsSync(request.scope);
      response = { id: request.id, ok: true, result };
    } catch (error) {
      response = { id: request.id, ok: false, error: serializeError(error) };
    }

    // Node MessagePort.postMessage is not the browser Window API.
    // oxlint-disable-next-line unicorn/require-post-message-target-origin
    parentPort.postMessage(response);
  });
}
'@
$changes[$workerPath] = Convert-Newlines $workerText "`n"

$path = Join-Path $Repo "src/config/sessions/session-accessor.sqlite-read.ts"
$text = [IO.File]::ReadAllText($path)

$text = Replace-One $text @'
import { resolveSqliteSessionTranscriptReadFence } from "./session-transcript-read-fence.js";
'@ @'
import { resolveSqliteSessionTranscriptReadFence } from "./session-transcript-read-fence.js";
import {
  hasSqliteTranscriptMessageEventsOffThread,
  loadSqliteTranscriptEventsOffThread,
} from "./session-transcript-load-async.js";
'@ "sqlite-read async worker imports"

$text = Replace-One $text @'
export async function loadSqliteTranscriptEvents(
  scope: SessionTranscriptReadScope,
): Promise<TranscriptEvent[]> {
  return loadSqliteTranscriptEventsSync(scope);
}
'@ @'
export async function loadSqliteTranscriptEvents(
  scope: SessionTranscriptReadScope,
): Promise<TranscriptEvent[]> {
  return await loadSqliteTranscriptEventsOffThread(scope);
}
'@ "make loadSqliteTranscriptEvents genuinely async"

$insertAfter = @'
export function loadSqliteTranscriptEventsSync(
  scope: SessionTranscriptReadScope,
): TranscriptEvent[] {
  const resolved = resolveSqliteTranscriptReadScope(scope);
  const database = openOpenClawAgentDatabase(toDatabaseOptions(resolved));
  return runSqliteDeferredTransactionSync(
    database.db,
    () => {
      const fence = resolveSqliteSessionTranscriptReadFence({ database, ...resolved });
      return loadSqliteTranscriptEventsFromDatabase(
        database,
        resolved.sessionId,
        fence?.beforeRawSeq,
      );
    },
    {
      databaseLabel: database.path,
      operationLabel: "session transcript fenced read",
    },
  );
}
'@
$replacement = $insertAfter + @'

/** True when the selected transcript contains at least one message event. */
export async function hasSqliteTranscriptMessageEvents(
  scope: SessionTranscriptReadScope,
): Promise<boolean> {
  return await hasSqliteTranscriptMessageEventsOffThread(scope);
}

/** Indexed synchronous primitive used only by the transcript-load worker. */
export function hasSqliteTranscriptMessageEventsSync(
  scope: SessionTranscriptReadScope,
): boolean {
  const resolved = resolveSqliteTranscriptReadScope(scope);
  const database = openOpenClawAgentDatabase(toDatabaseOptions(resolved));
  const db = getSessionKysely(database.db);
  return Boolean(
    executeSqliteQueryTakeFirstSync(
      database.db,
      db
        .selectFrom("transcript_event_identities")
        .select("seq")
        .where("session_id", "=", resolved.sessionId)
        .where("event_type", "=", "message")
        .limit(1),
    ),
  );
}
'@
$text = Replace-One $text $insertAfter $replacement "indexed transcript message existence query"
$changes[$path] = $text

$path = Join-Path $Repo "src/config/sessions/session-accessor.sqlite.ts"
$text = [IO.File]::ReadAllText($path)
$text = Replace-One $text @'
  findSqliteTranscriptEvent,
  loadLatestSqliteAssistantText,
'@ @'
  findSqliteTranscriptEvent,
  hasSqliteTranscriptMessageEvents,
  hasSqliteTranscriptMessageEventsSync,
  loadLatestSqliteAssistantText,
'@ "sqlite accessor exports message existence"
$changes[$path] = $text

$path = Join-Path $Repo "src/config/sessions/session-accessor.transcript.ts"
$text = [IO.File]::ReadAllText($path)

$text = Replace-One $text @'
  findSqliteTranscriptEvent,
  loadLatestSqliteAssistantText as readLatestTranscriptAssistantText,
'@ @'
  findSqliteTranscriptEvent,
  hasSqliteTranscriptMessageEvents as hasTranscriptMessageEvents,
  loadLatestSqliteAssistantText as readLatestTranscriptAssistantText,
'@ "transcript accessor import message existence"

$text = Replace-One $text @'
  appendTranscriptMessageSync,
  loadTranscriptEventRowsAfterSeqSync,
'@ @'
  appendTranscriptMessageSync,
  hasTranscriptMessageEvents,
  loadTranscriptEventRowsAfterSeqSync,
'@ "transcript accessor export message existence"
$changes[$path] = $text

$path = Join-Path $Repo "src/config/sessions/session-accessor.ts"
$text = [IO.File]::ReadAllText($path)

$text = Replace-One $text @'
  appendTranscriptMessageSync,
  findTranscriptEvent,
  loadTranscriptEventRowsAfterSeqSync,
'@ @'
  appendTranscriptMessageSync,
  findTranscriptEvent,
  hasTranscriptMessageEvents,
  loadTranscriptEventRowsAfterSeqSync,
'@ "public accessor export message existence"
$changes[$path] = $text

$path = Join-Path $Repo "src/agents/sessions/session-manager.ts"
$text = [IO.File]::ReadAllText($path)

$text = Replace-One $text @'
import { loadTranscriptEventsSync } from "../../config/sessions/session-accessor.js";
'@ @'
import {
  loadTranscriptEvents,
  loadTranscriptEventsSync,
} from "../../config/sessions/session-accessor.js";
'@ "SessionManager async transcript import"

$text = Replace-One $text @'
  static open(target: SessionTranscriptRuntimeTarget, cwdOverride?: string): SessionManager {
    const entries = loadTranscriptEventsSync(target) as FileEntry[];
    const header = entries.find(
      (entry) => typeof entry === "object" && entry !== null && entry.type === "session",
    );
    return new SessionManager(cwdOverride ?? header?.cwd ?? process.cwd(), target, entries);
  }

  static inMemory(cwd: string = process.cwd()): SessionManager {
'@ @'
  static open(target: SessionTranscriptRuntimeTarget, cwdOverride?: string): SessionManager {
    const entries = loadTranscriptEventsSync(target) as FileEntry[];
    const header = entries.find(
      (entry) => typeof entry === "object" && entry !== null && entry.type === "session",
    );
    return new SessionManager(cwdOverride ?? header?.cwd ?? process.cwd(), target, entries);
  }

  static async openAsync(
    target: SessionTranscriptRuntimeTarget,
    cwdOverride?: string,
  ): Promise<SessionManager> {
    const entries = (await loadTranscriptEvents(target)) as FileEntry[];
    const header = entries.find(
      (entry) => typeof entry === "object" && entry !== null && entry.type === "session",
    );
    return new SessionManager(cwdOverride ?? header?.cwd ?? process.cwd(), target, entries);
  }

  static inMemory(cwd: string = process.cwd()): SessionManager {
'@ "SessionManager.openAsync"
$changes[$path] = $text

$path = Join-Path $Repo "src/agents/embedded-agent-runner/run/attempt-transcript-helpers.ts"
$text = [IO.File]::ReadAllText($path)

$text = Replace-One $text @'
  loadSessionEntry,
  loadTranscriptEvents,
  resolveSessionTranscriptRuntimeReadTarget,
'@ @'
  hasTranscriptMessageEvents,
  loadSessionEntry,
  resolveSessionTranscriptRuntimeReadTarget,
'@ "attempt helper indexed message import"

$text = Replace-One $text @'
      const sqliteEvents = await loadTranscriptEvents({
        agentId,
        sessionId,
        sessionKey,
        storePath,
      });
      hasBootstrapTranscriptState = sqliteEvents.some(isTranscriptMessageEvent);
'@ @'
      hasBootstrapTranscriptState = await hasTranscriptMessageEvents({
        agentId,
        sessionId,
        sessionKey,
        storePath,
      });
'@ "attempt helper indexed message existence"

$text = Replace-One $text @'
function isTranscriptMessageEvent(event: unknown): boolean {
  return (
    typeof event === "object" &&
    event !== null &&
    "type" in event &&
    (event as { type?: unknown }).type === "message"
  );
}

'@ @'
"remove transcript message scan helper"
$changes[$path] = $text

$path = Join-Path $Repo "src/agents/embedded-agent-runner/run/attempt-session-manager-prepare.ts"
$text = [IO.File]::ReadAllText($path)
'@ 
$text = Replace-One $text @'
        ? SessionManager.open(
            attempt.sessionTarget as SessionTranscriptRuntimeTarget,
            input.effectiveCwd,
          )
        : SessionManager.inMemory(input.effectiveCwd)),
'@ @'
        ? await SessionManager.openAsync(
            attempt.sessionTarget as SessionTranscriptRuntimeTarget,
            input.effectiveCwd,
          )
        : SessionManager.inMemory(input.effectiveCwd)),
'@ "embedded attempt async SessionManager open"
$changes[$path] = $text

$path = Join-Path $Repo "tsdown.config.ts"
$text = [IO.File]::ReadAllText($path)

if ($text -match '"config/sessions/session-transcript-load\.worker"') {
    throw "session-transcript-load worker entry already exists."
}

$text = Replace-One $text @'
    "config/sessions/session-accessor.sqlite-archive.worker":
      "src/config/sessions/session-accessor.sqlite-archive.worker.ts",
'@ @'
    "config/sessions/session-accessor.sqlite-archive.worker":
      "src/config/sessions/session-accessor.sqlite-archive.worker.ts",
    "config/sessions/session-transcript-load.worker":
      "src/config/sessions/session-transcript-load.worker.ts",
'@ "tsdown storage transcript worker entry"
$changes[$path] = $text

foreach ($entry in $changes.GetEnumerator()) {
    $target = $entry.Key
    $dir = Split-Path -Parent $target
    if (-not (Test-Path $dir)) {
        [IO.Directory]::CreateDirectory($dir) | Out-Null
    }
    [IO.File]::WriteAllText($target, [string]$entry.Value, $encoding)
}

Write-Host ""
Write-Host "Applied embedded-agent transcript hydration hardening."
Write-Host ""

git diff --check
if ($LASTEXITCODE -ne 0) {
    throw "git diff --check failed."
}

git status --short

Write-Host ""
Write-Host "Stop the Gateway before rebuilding dist:"
Write-Host "  openclaw gateway stop --force"
Write-Host "  Remove-Item .\dist -Recurse -Force"
Write-Host "  pnpm build"
Write-Host "  Test-Path .\dist\config\sessions\session-transcript-load.worker.js"
