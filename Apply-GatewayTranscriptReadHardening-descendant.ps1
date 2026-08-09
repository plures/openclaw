# OpenClaw Gateway transcript-read hardening batch.
# Target: corporate-install HEAD beginning with 2ace157.
#
# Fixes the "Async" transcript APIs that still execute synchronous SQLite on the
# Gateway event loop. Adds one persistent transcript-read worker and coalesces
# identical in-flight reads.
#
# Covered:
#   - chat.history tail reads
#   - chat.history offset pages
#   - chat.history anchored messageId reads
#   - full transcript reads
#   - message-by-id reads
#   - message counts
#   - sessions.get
#   - sessions.preview
#   - async transcript usage reads

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

$clientPath = Join-Path $Repo "src/gateway/session-transcript-read-async.ts"
if (Test-Path $clientPath) {
    throw "Refusing to overwrite existing $clientPath"
}
$clientText = @'
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { Worker } from "node:worker_threads";
import type {
  readRecentSessionTranscriptMessageEvents,
  readSessionTranscriptMessageAnchorPage,
  readSessionTranscriptMessageEventById,
  readSessionTranscriptMessageEventCount,
  readSessionTranscriptMessageEventPage,
  readSessionTranscriptMessageEvents,
  SessionTranscriptReadScope,
} from "../config/sessions/session-accessor.js";

type RecentOptions = Parameters<typeof readRecentSessionTranscriptMessageEvents>[1];
type RecentResult = ReturnType<typeof readRecentSessionTranscriptMessageEvents>;
type AnchorOptions = Parameters<typeof readSessionTranscriptMessageAnchorPage>[1];
type AnchorResult = ReturnType<typeof readSessionTranscriptMessageAnchorPage>;
type ByIdResult = ReturnType<typeof readSessionTranscriptMessageEventById>;
type CountResult = ReturnType<typeof readSessionTranscriptMessageEventCount>;
type PageOptions = Parameters<typeof readSessionTranscriptMessageEventPage>[1];
type PageResult = ReturnType<typeof readSessionTranscriptMessageEventPage>;
type EventsResult = ReturnType<typeof readSessionTranscriptMessageEvents>;

type WorkerRequestPayload =
  | { type: "events"; scope: SessionTranscriptReadScope }
  | { type: "recent"; scope: SessionTranscriptReadScope; options: RecentOptions }
  | { type: "by-id"; scope: SessionTranscriptReadScope; messageId: string }
  | { type: "count"; scope: SessionTranscriptReadScope }
  | { type: "page"; scope: SessionTranscriptReadScope; options: PageOptions }
  | { type: "anchor"; scope: SessionTranscriptReadScope; options: AnchorOptions };

type WorkerRequest = WorkerRequestPayload & { id: number };

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
const inFlightReads = new Map<string, Promise<unknown>>();

function resolveWorkerUrl(currentModuleUrl = import.meta.url): URL {
  const currentPath = fileURLToPath(currentModuleUrl);
  const normalized = currentPath.replaceAll(path.sep, "/");
  const distMarker = "/dist/";
  const distIndex = normalized.lastIndexOf(distMarker);
  if (distIndex >= 0) {
    const distRoot = currentPath.slice(0, distIndex + distMarker.length);
    return pathToFileURL(path.join(distRoot, "gateway", "session-transcript-read.worker.js"));
  }
  const extension = path.extname(currentPath) || ".js";
  return new URL(`./session-transcript-read.worker${extension}`, currentModuleUrl);
}

function rejectPending(error: Error): void {
  for (const pending of pendingRequests.values()) {
    pending.reject(error);
  }
  pendingRequests.clear();
  inFlightReads.clear();
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
        ? new Error(`session transcript read worker exited with code ${code}`)
        : undefined,
    );
  });

  workerInstance = worker;
  return worker;
}

function requestWorker<T>(payload: WorkerRequestPayload): Promise<T> {
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
      worker.postMessage({ ...payload, id } as WorkerRequest);
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
    scope.sessionFile ?? "",
  ].join("\0");
}

function coalesced<T>(key: string, run: () => Promise<T>): Promise<T> {
  const existing = inFlightReads.get(key);
  if (existing) {
    return existing as Promise<T>;
  }
  const promise = run().finally(() => {
    if (inFlightReads.get(key) === promise) {
      inFlightReads.delete(key);
    }
  });
  inFlightReads.set(key, promise);
  return promise;
}

export function readSessionTranscriptMessageEventsAsync(
  scope: SessionTranscriptReadScope,
): Promise<EventsResult> {
  return coalesced(`events\0${scopeKey(scope)}`, () =>
    requestWorker<EventsResult>({ type: "events", scope }),
  );
}

export function readRecentSessionTranscriptMessageEventsAsync(
  scope: SessionTranscriptReadScope,
  options: RecentOptions,
): Promise<RecentResult> {
  const key = `recent\0${scopeKey(scope)}\0${JSON.stringify(options)}`;
  return coalesced(key, () =>
    requestWorker<RecentResult>({ type: "recent", scope, options }),
  );
}

export function readSessionTranscriptMessageEventByIdAsync(
  scope: SessionTranscriptReadScope,
  messageId: string,
): Promise<ByIdResult> {
  return coalesced(`by-id\0${scopeKey(scope)}\0${messageId}`, () =>
    requestWorker<ByIdResult>({ type: "by-id", scope, messageId }),
  );
}

export function readSessionTranscriptMessageEventCountAsync(
  scope: SessionTranscriptReadScope,
): Promise<CountResult> {
  return coalesced(`count\0${scopeKey(scope)}`, () =>
    requestWorker<CountResult>({ type: "count", scope }),
  );
}

export function readSessionTranscriptMessageEventPageAsync(
  scope: SessionTranscriptReadScope,
  options: PageOptions,
): Promise<PageResult> {
  const key = `page\0${scopeKey(scope)}\0${JSON.stringify(options)}`;
  return coalesced(key, () =>
    requestWorker<PageResult>({ type: "page", scope, options }),
  );
}

export function readSessionTranscriptMessageAnchorPageAsync(
  scope: SessionTranscriptReadScope,
  options: AnchorOptions,
): Promise<AnchorResult> {
  const key = `anchor\0${scopeKey(scope)}\0${JSON.stringify(options)}`;
  return coalesced(key, () =>
    requestWorker<AnchorResult>({ type: "anchor", scope, options }),
  );
}
'@
$changes[$clientPath] = Convert-Newlines $clientText "`n"

$workerPath = Join-Path $Repo "src/gateway/session-transcript-read.worker.ts"
if (Test-Path $workerPath) {
    throw "Refusing to overwrite existing $workerPath"
}
$workerText = @'
import { isMainThread, parentPort } from "node:worker_threads";
import {
  readRecentSessionTranscriptMessageEvents,
  readSessionTranscriptMessageAnchorPage,
  readSessionTranscriptMessageEventById,
  readSessionTranscriptMessageEventCount,
  readSessionTranscriptMessageEventPage,
  readSessionTranscriptMessageEvents,
  type SessionTranscriptReadScope,
} from "../config/sessions/session-accessor.js";

type WorkerRequest =
  | { id: number; type: "events"; scope: SessionTranscriptReadScope }
  | {
      id: number;
      type: "recent";
      scope: SessionTranscriptReadScope;
      options: Parameters<typeof readRecentSessionTranscriptMessageEvents>[1];
    }
  | { id: number; type: "by-id"; scope: SessionTranscriptReadScope; messageId: string }
  | { id: number; type: "count"; scope: SessionTranscriptReadScope }
  | {
      id: number;
      type: "page";
      scope: SessionTranscriptReadScope;
      options: Parameters<typeof readSessionTranscriptMessageEventPage>[1];
    }
  | {
      id: number;
      type: "anchor";
      scope: SessionTranscriptReadScope;
      options: Parameters<typeof readSessionTranscriptMessageAnchorPage>[1];
    };

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
      let result: unknown;
      switch (request.type) {
        case "events":
          result = readSessionTranscriptMessageEvents(request.scope);
          break;
        case "recent":
          result = readRecentSessionTranscriptMessageEvents(request.scope, request.options);
          break;
        case "by-id":
          result = readSessionTranscriptMessageEventById(request.scope, request.messageId);
          break;
        case "count":
          result = readSessionTranscriptMessageEventCount(request.scope);
          break;
        case "page":
          result = readSessionTranscriptMessageEventPage(request.scope, request.options);
          break;
        case "anchor":
          result = readSessionTranscriptMessageAnchorPage(request.scope, request.options);
          break;
      }
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

$path = Join-Path $Repo "src/gateway/session-transcript-readers.ts"
$text = [IO.File]::ReadAllText($path)

$text = Replace-One $text @'
import { resolveAgentIdFromSessionKey } from "../routing/session-key.js";
import { aggregateSqliteUsageSnapshots } from "./session-transcript-derived-readers.js";
'@ @'
import { resolveAgentIdFromSessionKey } from "../routing/session-key.js";
import {
  readRecentSessionTranscriptMessageEventsAsync,
  readSessionTranscriptMessageEventByIdAsync,
  readSessionTranscriptMessageEventCountAsync,
  readSessionTranscriptMessageEventPageAsync,
  readSessionTranscriptMessageEventsAsync,
} from "./session-transcript-read-async.js";
import { aggregateSqliteUsageSnapshots } from "./session-transcript-derived-readers.js";
'@ "transcript-reader async worker imports"

$text = Replace-One $text @'
async function readSqliteMessageRecords(
  target: ResolvedTranscriptReadTarget,
): Promise<SqliteMessageRecord[]> {
  return extractMessageRecordsFromEventEntries(
    readSessionTranscriptMessageEvents(toTranscriptReadScope(target)),
  );
}
'@ @'
async function readSqliteMessageRecords(
  target: ResolvedTranscriptReadTarget,
): Promise<SqliteMessageRecord[]> {
  return extractMessageRecordsFromEventEntries(
    await readSessionTranscriptMessageEventsAsync(toTranscriptReadScope(target)),
  );
}
'@ "full transcript async worker"

$text = Replace-One $text @'
  const page = readRecentSessionTranscriptMessageEvents(toTranscriptReadScope(target), normalized);
'@ @'
  const page = await readRecentSessionTranscriptMessageEventsAsync(
    toTranscriptReadScope(target),
    normalized,
  );
'@ "recent transcript async worker"

$text = Replace-One $text @'
  const foundEvent = readSessionTranscriptMessageEventById(
    toTranscriptReadScope(target),
    messageId,
  );
'@ @'
  const foundEvent = await readSessionTranscriptMessageEventByIdAsync(
    toTranscriptReadScope(target),
    messageId,
  );
'@ "message by id async worker"

$text = Replace-One $text @'
    return readSessionTranscriptMessageEventCount(transcriptScope);
'@ @'
    return await readSessionTranscriptMessageEventCountAsync(transcriptScope);
'@ "message count first async worker"

$text = Replace-One $text @'
    return readSessionTranscriptMessageEventCount(transcriptScope);
  }
}

/** Reads recent messages with total-count metadata asynchronously through the reader seam. */
'@ @'
    return await readSessionTranscriptMessageEventCountAsync(transcriptScope);
  }
}

/** Reads recent messages with total-count metadata asynchronously through the reader seam. */
'@ "message count retry async worker"

$text = Replace-One $text @'
  const page = readSessionTranscriptMessageEventPage(toTranscriptReadScope(target), opts);
'@ @'
  const page = await readSessionTranscriptMessageEventPageAsync(
    toTranscriptReadScope(target),
    opts,
  );
'@ "offset page async worker"

$text = Replace-One $text @'
  const target = resolveTranscriptReadTarget(scope);
  return readSqliteAggregateUsageSnapshot(target);
}
'@ @'
  const target = resolveTranscriptReadTarget(scope);
  const records = await readSqliteMessageRecords(target);
  return aggregateSqliteUsageSnapshots(records.map(sqliteRecordMessageWithSeq));
}
'@ "async usage worker"

$append = @'

/** Reads compact session preview items without blocking the Gateway event loop. */
export async function readSessionPreviewItemsFromTranscriptAsync(
  scope: SessionTranscriptReadScope,
  maxItems: number,
  maxChars: number,
): Promise<SessionPreviewItem[]> {
  const target = resolveTranscriptReadTarget(scope);
  const records = await readSqliteMessageRecords(target);
  return buildSessionPreviewItems(records.map(sqliteRecordMessageWithSeq), maxItems, maxChars);
}
'@
if ($text -match 'export async function readSessionPreviewItemsFromTranscriptAsync\(') {
    throw "Async preview reader already exists."
}
$nl = Get-Newline $text
$text = $text.TrimEnd([char[]]"`r`n") + (Convert-Newlines $append $nl) + $nl
$changes[$path] = $text

$path = Join-Path $Repo "src/gateway/session-transcript-anchor-reader.ts"
$text = [IO.File]::ReadAllText($path)

$text = Replace-One $text @'
import {
  readSessionTranscriptMessageAnchorPage,
  type SessionTranscriptReadScope,
} from "../config/sessions/session-accessor.js";
'@ @'
import type { SessionTranscriptReadScope } from "../config/sessions/session-accessor.js";
import { readSessionTranscriptMessageAnchorPageAsync } from "./session-transcript-read-async.js";
'@ "anchor reader worker import"

$text = Replace-One $text @'
  const page = readSessionTranscriptMessageAnchorPage(toTranscriptReadScope(target), opts);
'@ @'
  const page = await readSessionTranscriptMessageAnchorPageAsync(
    toTranscriptReadScope(target),
    opts,
  );
'@ "anchor reader async worker"
$changes[$path] = $text

$path = Join-Path $Repo "src/gateway/server-methods/sessions-read.ts"
$text = [IO.File]::ReadAllText($path)

$text = Replace-One $text @'
  readRecentSessionMessagesWithStatsAsync,
  readSessionPreviewItemsFromTranscript,
} from "../session-transcript-readers.js";
'@ @'
  readRecentSessionMessagesWithStatsAsync,
  readSessionPreviewItemsFromTranscriptAsync,
} from "../session-transcript-readers.js";
'@ "sessions.preview async import"

$text = Replace-One $text @'
  "sessions.preview": ({ params, respond, context }) => {
'@ @'
  "sessions.preview": async ({ params, respond, context }) => {
'@ "sessions.preview async handler"

$text = Replace-One $text @'
        const items = readSessionPreviewItemsFromTranscript(
'@ @'
        const items = await readSessionPreviewItemsFromTranscriptAsync(
'@ "sessions.preview await worker"
$changes[$path] = $text

$path = Join-Path $Repo "tsdown.config.ts"
$text = [IO.File]::ReadAllText($path)

if ($text -match '"gateway/session-transcript-read\.worker"') {
    throw "session-transcript-read worker entry already exists."
}

if ($text -match '"gateway/session-list-read\.worker"') {
    $text = Replace-One $text @'
    "gateway/session-list-read.worker": "src/gateway/session-list-read.worker.ts",
'@ @'
    "gateway/session-list-read.worker": "src/gateway/session-list-read.worker.ts",
    "gateway/session-transcript-read.worker": "src/gateway/session-transcript-read.worker.ts",
'@ "tsdown transcript worker after session-list worker"
} else {
    $text = Replace-One $text @'
    "config/sessions/combined-store-gateway.worker":
      "src/config/sessions/combined-store-gateway.worker.ts",
'@ @'
    "config/sessions/combined-store-gateway.worker":
      "src/config/sessions/combined-store-gateway.worker.ts",
    "gateway/session-transcript-read.worker": "src/gateway/session-transcript-read.worker.ts",
'@ "tsdown transcript worker after combined-store worker"
}
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
Write-Host "Applied Gateway transcript-read hardening."
Write-Host ""

git diff --check
if ($LASTEXITCODE -ne 0) {
    throw "git diff --check failed."
}

git status --short

Write-Host ""
Write-Host "IMPORTANT: stop the Gateway before rebuilding dist."
Write-Host ""
Write-Host "  openclaw gateway stop --force"
Write-Host "  Remove-Item .\dist -Recurse -Force"
Write-Host "  pnpm build"
Write-Host "  Test-Path .\dist\gateway\session-transcript-read.worker.js"
