# OpenClaw Gateway session-read hardening batch patch.
# Target: plures/openclaw corporate-install @ 2ace157
# Purpose:
#   - keep optional dashboard prewarm off the Gateway thread by disabling it by default
#   - move transcript title/preview probes off-thread
#   - move ACP session metadata reads off-thread
#   - move sharing-store + membership reads off-thread
#   - coalesce same-key sessions.list work across mutation-fence changes
#
# Re-enable optional post-ready prewarm with:
#   $env:OPENCLAW_ENABLE_DASHBOARD_PREWARM = "1"

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Repo = Join-Path $HOME "openclaw"
Set-Location $Repo

$head = (git rev-parse --short HEAD).Trim()
if ($head -ne "2ace157") {
    throw "Expected HEAD 2ace157; current HEAD is $head. Regenerate this patch for the current commit."
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

# ---------------------------------------------------------------------------
# Export the two result types the worker client needs.
# ---------------------------------------------------------------------------

$path = Join-Path $Repo "src/gateway/session-sharing.ts"
$text = [IO.File]::ReadAllText($path)
$text = Replace-One $text @'
type SessionSharingTarget = {
'@ @'
export type SessionSharingTarget = {
'@ "export SessionSharingTarget"
$changes[$path] = $text

$path = Join-Path $Repo "src/gateway/session-transcript-title-reader.ts"
$text = [IO.File]::ReadAllText($path)
$text = Replace-One $text @'
type SessionTitleFields = {
'@ @'
export type SessionTitleFields = {
'@ "export SessionTitleFields"
$changes[$path] = $text

# ---------------------------------------------------------------------------
# Persistent worker client for remaining synchronous session-list reads.
# ---------------------------------------------------------------------------

$asyncPath = Join-Path $Repo "src/gateway/session-list-read-async.ts"
if (Test-Path $asyncPath) {
    throw "Refusing to overwrite existing $asyncPath"
}
$asyncText = @'
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { Worker } from "node:worker_threads";
import type { SessionTranscriptReadScope } from "../config/sessions/session-accessor.js";
import type { SessionAcpMeta, SessionEntry } from "../config/sessions/types.js";
import type { OpenClawConfig } from "../config/types.openclaw.js";
import type { SessionSharingTarget } from "./session-sharing.js";
import type { SessionTitleFields } from "./session-transcript-title-reader.js";

type AcpMetaEntry = {
  sessionKey: string;
  entry: SessionEntry;
};

type SessionListSharingResult = {
  sharingTargets: Array<SessionSharingTarget | null>;
  membershipKeys: string[];
};

type WorkerRequestPayload =
  | {
      type: "title-fields";
      scopes: SessionTranscriptReadScope[];
      includeInterSession?: boolean;
    }
  | {
      type: "acp-meta";
      entries: AcpMetaEntry[];
    }
  | {
      type: "sharing";
      cfg: OpenClawConfig;
      sessionKeys: string[];
      identityId?: string;
      agentId?: string;
    };

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

function resolveSessionListReadWorkerUrl(currentModuleUrl = import.meta.url): URL {
  const currentPath = fileURLToPath(currentModuleUrl);
  const normalized = currentPath.replaceAll(path.sep, "/");
  const distMarker = "/dist/";
  const distIndex = normalized.lastIndexOf(distMarker);
  if (distIndex >= 0) {
    const distRoot = currentPath.slice(0, distIndex + distMarker.length);
    return pathToFileURL(path.join(distRoot, "gateway", "session-list-read.worker.js"));
  }
  const extension = path.extname(currentPath) || ".js";
  return new URL(`./session-list-read.worker${extension}`, currentModuleUrl);
}

function rejectAllPending(error: Error): void {
  for (const pending of pendingRequests.values()) {
    pending.reject(error);
  }
  pendingRequests.clear();
}

function resetWorker(worker: Worker, error?: Error): void {
  if (workerInstance !== worker) {
    return;
  }
  workerInstance = undefined;
  if (error) {
    rejectAllPending(error);
  }
}

function getWorker(): Worker {
  if (workerInstance) {
    return workerInstance;
  }

  const workerUrl = resolveSessionListReadWorkerUrl();
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
        ? new Error(`session-list read worker exited with code ${code}`)
        : undefined,
    );
  });

  workerInstance = worker;
  return worker;
}

function requestWorker<T>(request: WorkerRequestPayload): Promise<T> {
  const worker = getWorker();
  const id = nextRequestId++;
  return new Promise<T>((resolve, reject) => {
    pendingRequests.set(id, {
      resolve: (result) => resolve(result as T),
      reject,
    });
    try {
      // Node Worker.postMessage is not the browser Window API and has no targetOrigin.
      // oxlint-disable-next-line unicorn/require-post-message-target-origin
      worker.postMessage({ ...request, id } as WorkerRequest);
    } catch (error) {
      pendingRequests.delete(id);
      reject(error instanceof Error ? error : new Error(String(error)));
    }
  });
}

export function readSessionTitleFieldsFromTranscriptBatchAsync(
  scopes: readonly SessionTranscriptReadScope[],
  opts?: { includeInterSession?: boolean },
): Promise<SessionTitleFields[]> {
  if (scopes.length === 0) {
    return Promise.resolve([]);
  }
  return requestWorker<SessionTitleFields[]>({
    type: "title-fields",
    scopes: [...scopes],
    ...(opts?.includeInterSession === true ? { includeInterSession: true } : {}),
  });
}

export function readAcpSessionMetaBatchAsync(
  entries: readonly AcpMetaEntry[],
): Promise<Array<SessionAcpMeta | undefined>> {
  if (entries.length === 0) {
    return Promise.resolve([]);
  }
  return requestWorker<Array<SessionAcpMeta | undefined>>({
    type: "acp-meta",
    entries: [...entries],
  });
}

export function resolveSessionListSharingAsync(params: {
  cfg: OpenClawConfig;
  sessionKeys: readonly string[];
  identityId?: string;
  agentId?: string;
}): Promise<SessionListSharingResult> {
  if (params.sessionKeys.length === 0) {
    return Promise.resolve({ sharingTargets: [], membershipKeys: [] });
  }
  return requestWorker<SessionListSharingResult>({
    type: "sharing",
    cfg: params.cfg,
    sessionKeys: [...params.sessionKeys],
    ...(params.identityId ? { identityId: params.identityId } : {}),
    ...(params.agentId ? { agentId: params.agentId } : {}),
  });
}
'@
$changes[$asyncPath] = Convert-Newlines $asyncText "`n"

# ---------------------------------------------------------------------------
# Worker: all remaining synchronous SQLite/store reads used by sessions.list.
# ---------------------------------------------------------------------------

$workerPath = Join-Path $Repo "src/gateway/session-list-read.worker.ts"
if (Test-Path $workerPath) {
    throw "Refusing to overwrite existing $workerPath"
}
$workerText = @'
import { isMainThread, parentPort } from "node:worker_threads";
import { readAcpSessionMetaBatch } from "../acp/runtime/session-meta.js";
import {
  listSessionMembershipKeys,
  type SessionEntry,
} from "../config/sessions.js";
import type { SessionTranscriptReadScope } from "../config/sessions/session-accessor.js";
import type { OpenClawConfig } from "../config/types.openclaw.js";
import {
  resolveSessionSharingTarget,
  type SessionSharingTarget,
} from "./session-sharing.js";
import { readSessionTitleFieldsFromTranscriptBatch } from "./session-transcript-title-reader.js";
import type {
  GatewaySessionStoreCache,
  GatewaySessionStoreDiscoveryCache,
} from "./session-utils-store-lookup.js";

type AcpMetaEntry = {
  sessionKey: string;
  entry: SessionEntry;
};

type WorkerRequest =
  | {
      id: number;
      type: "title-fields";
      scopes: SessionTranscriptReadScope[];
      includeInterSession?: boolean;
    }
  | {
      id: number;
      type: "acp-meta";
      entries: AcpMetaEntry[];
    }
  | {
      id: number;
      type: "sharing";
      cfg: OpenClawConfig;
      sessionKeys: string[];
      identityId?: string;
      agentId?: string;
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

function resolveSharing(request: Extract<WorkerRequest, { type: "sharing" }>) {
  const sharingStoreCache: GatewaySessionStoreCache = new Map();
  const targetDiscoveryCache: GatewaySessionStoreDiscoveryCache = new Map();
  const sharingTargets = request.sessionKeys.map((sessionKey) =>
    resolveSessionSharingTarget({
      cfg: request.cfg,
      projection: "list",
      sessionKey,
      storeCache: sharingStoreCache,
      targetDiscoveryCache,
      ...(sessionKey === "global" && request.agentId ? { agentId: request.agentId } : {}),
    }),
  );

  const membershipKeys: string[] = [];
  if (request.identityId) {
    const groups = new Map<
      string,
      {
        agentId: string;
        sessionKeys: string[];
        storePath: string;
      }
    >();

    for (const target of sharingTargets) {
      if (!target) {
        continue;
      }
      const groupKey = `${target.agentId}\0${target.storePath}`;
      const group = groups.get(groupKey) ?? {
        agentId: target.agentId,
        sessionKeys: [],
        storePath: target.storePath,
      };
      group.sessionKeys.push(target.storeKey);
      groups.set(groupKey, group);
    }

    for (const group of groups.values()) {
      const firstSessionKey = group.sessionKeys[0];
      if (!firstSessionKey) {
        continue;
      }
      for (const sessionKey of listSessionMembershipKeys(
        {
          agentId: group.agentId,
          sessionKey: firstSessionKey,
          storePath: group.storePath,
        },
        group.sessionKeys,
        request.identityId,
      )) {
        membershipKeys.push(`${group.agentId}\0${group.storePath}\0${sessionKey}`);
      }
    }
  }

  return {
    sharingTargets: sharingTargets as Array<SessionSharingTarget | null>,
    membershipKeys,
  };
}

if (!isMainThread && parentPort) {
  parentPort.on("message", (request: WorkerRequest) => {
    let response: WorkerResponse;
    try {
      let result: unknown = undefined;
      switch (request.type) {
        case "title-fields":
          result = readSessionTitleFieldsFromTranscriptBatch(request.scopes, {
            ...(request.includeInterSession === true ? { includeInterSession: true } : {}),
          });
          break;
        case "acp-meta": {
          const metaByEntry = readAcpSessionMetaBatch({ entries: request.entries });
          result = request.entries.map(({ entry }) => metaByEntry.get(entry));
          break;
        }
        case "sharing":
          result = resolveSharing(request);
          break;
      }
      response = { id: request.id, ok: true, result };
    } catch (error) {
      response = { id: request.id, ok: false, error: serializeError(error) };
    }

    // Node MessagePort.postMessage is not the browser Window API and has no targetOrigin.
    // oxlint-disable-next-line unicorn/require-post-message-target-origin
    parentPort.postMessage(response);
  });
}
'@
$changes[$workerPath] = Convert-Newlines $workerText "`n"

# ---------------------------------------------------------------------------
# session-utils-list.ts:
#   - sync API remains sync
#   - async list path sends ACP + title reads to the worker
# ---------------------------------------------------------------------------

$path = Join-Path $Repo "src/gateway/session-utils-list.ts"
$text = [IO.File]::ReadAllText($path)

$text = Replace-One $text @'
import { readSessionTitleFieldsFromTranscriptBatch as readScopedSessionTitleFieldsFromTranscriptBatch } from "./session-transcript-title-reader.js";
'@ @'
import {
  readAcpSessionMetaBatchAsync,
  readSessionTitleFieldsFromTranscriptBatchAsync,
} from "./session-list-read-async.js";
'@ "session-utils-list worker imports"

$oldAcp = @'
function populateSessionListAcpMetadata(params: {
  cfg: OpenClawConfig;
  entries: readonly SessionEntryPair[];
  opts: SessionsListParams;
  rowContext?: SessionListRowContext;
}): void {
  if (!params.rowContext || params.entries.length === 0) {
    return;
  }
  const entries = params.entries.map(([key, entry]) => {
    const parsed = parseAgentSessionKey(key);
    const agentId = normalizeAgentId(
      key === "global" && typeof params.opts.agentId === "string"
        ? params.opts.agentId
        : (parsed?.agentId ?? resolveDefaultAgentId(params.cfg)),
    );
    return {
      sessionKey: resolveStoredSessionKeyForAgentStore({
        cfg: params.cfg,
        agentId,
        sessionKey: key,
      }),
      entry,
    };
  });
  params.rowContext.acpSessionMetaByEntry = readAcpSessionMetaBatch({ entries });
}
'@
$newAcp = @'
function buildSessionListAcpEntries(params: {
  cfg: OpenClawConfig;
  entries: readonly SessionEntryPair[];
  opts: SessionsListParams;
}) {
  return params.entries.map(([key, entry]) => {
    const parsed = parseAgentSessionKey(key);
    const agentId = normalizeAgentId(
      key === "global" && typeof params.opts.agentId === "string"
        ? params.opts.agentId
        : (parsed?.agentId ?? resolveDefaultAgentId(params.cfg)),
    );
    return {
      sessionKey: resolveStoredSessionKeyForAgentStore({
        cfg: params.cfg,
        agentId,
        sessionKey: key,
      }),
      entry,
    };
  });
}

function populateSessionListAcpMetadata(params: {
  cfg: OpenClawConfig;
  entries: readonly SessionEntryPair[];
  opts: SessionsListParams;
  rowContext?: SessionListRowContext;
}): void {
  if (!params.rowContext || params.entries.length === 0) {
    return;
  }
  const entries = buildSessionListAcpEntries(params);
  params.rowContext.acpSessionMetaByEntry = readAcpSessionMetaBatch({ entries });
}

async function populateSessionListAcpMetadataAsync(params: {
  cfg: OpenClawConfig;
  entries: readonly SessionEntryPair[];
  opts: SessionsListParams;
  rowContext?: SessionListRowContext;
}): Promise<void> {
  if (!params.rowContext || params.entries.length === 0) {
    return;
  }
  const entries = buildSessionListAcpEntries(params);
  const metadata = await readAcpSessionMetaBatchAsync(entries);
  params.rowContext.acpSessionMetaByEntry = new Map(
    entries.map(({ entry }, index) => [entry, metadata[index]]),
  );
}
'@
$text = Replace-One $text $oldAcp $newAcp "session-utils-list ACP async split"

$text = Replace-One $text @'
function prepareSessionList(params: ListSessionsFromStoreParams) {
'@ @'
function prepareSessionList(
  params: ListSessionsFromStoreParams,
  options: { populateAcpMetadata?: boolean } = {},
) {
'@ "prepareSessionList options"

$text = Replace-One $text @'
  populateSessionListAcpMetadata({
    cfg,
    entries: selection.entries,
    opts,
    rowContext: sharedRowContext,
  });
'@ @'
  if (options.populateAcpMetadata !== false) {
    populateSessionListAcpMetadata({
      cfg,
      entries: selection.entries,
      opts,
      rowContext: sharedRowContext,
    });
  }
'@ "prepareSessionList conditional ACP"

$text = Replace-One $text @'
  return withPinnedActivePluginRegistryWorkspaceDir(async () => {
    const { cfg, store, opts } = params;
    const list = prepareSessionList(params);
    const sessions: GatewaySessionRow[] = [];
'@ @'
  return withPinnedActivePluginRegistryWorkspaceDir(async () => {
    const { cfg, store, opts } = params;
    const list = prepareSessionList(params, { populateAcpMetadata: false });
    await populateSessionListAcpMetadataAsync({
      cfg,
      entries: list.entries,
      opts,
      rowContext: list.rowContext,
    });
    const sessions: GatewaySessionRow[] = [];
'@ "async list ACP worker"

$text = Replace-One $text @'
    const transcriptFields = readScopedSessionTitleFieldsFromTranscriptBatch(transcriptScopes);
'@ @'
    const transcriptFields = await readSessionTitleFieldsFromTranscriptBatchAsync(transcriptScopes);
'@ "async list title worker"

$changes[$path] = $text

# ---------------------------------------------------------------------------
# sessions-read.ts:
#   - sharing store lookup + membership lookup move to worker
# ---------------------------------------------------------------------------

$path = Join-Path $Repo "src/gateway/server-methods/sessions-read.ts"
$text = [IO.File]::ReadAllText($path)

$text = Replace-One $text @'
  isConfiguredSessionStoreAgentId,
  isPerAgentSessionStoreConfig,
  listSessionMembershipKeys,
  resolveExistingAgentSessionStoreTargetsSync,
'@ @'
  isConfiguredSessionStoreAgentId,
  isPerAgentSessionStoreConfig,
  resolveExistingAgentSessionStoreTargetsSync,
'@ "sessions-read remove membership import"

$text = Replace-One $text @'
  isGatewayAdmin,
  resolveSessionSharingRole,
  resolveSessionSharingTarget,
  resolveSessionVisibility,
'@ @'
  isGatewayAdmin,
  resolveSessionSharingRole,
  resolveSessionVisibility,
'@ "sessions-read remove sharing target import"

$text = Replace-One $text @'
import type {
  GatewaySessionStoreCache,
  GatewaySessionStoreDiscoveryCache,
} from "../session-utils-store-lookup.js";
'@ @'
import { resolveSessionListSharingAsync } from "../session-list-read-async.js";
'@ "sessions-read sharing worker import"

$oldSharing = @'
          const identityId = gatewayClientSessionCreator(client)?.id;
          const { sharingTargets, membershipKeys } = await measureDiagnosticsTimelineSpan(
            "gateway.sessions.list.sharing",
            () => {
              // One cache for the whole listing: sharing resolution otherwise
              // materialized every entry of a candidate store once per row.
              const sharingStoreCache: GatewaySessionStoreCache = new Map();
              const targetDiscoveryCache: GatewaySessionStoreDiscoveryCache = new Map();
              const resolvedSharingTargets = result.sessions.map((session) =>
                resolveSessionSharingTarget({
                  cfg,
                  projection: "list",
                  sessionKey: session.key,
                  storeCache: sharingStoreCache,
                  targetDiscoveryCache,
                  ...(session.key === "global" && p.agentId ? { agentId: p.agentId } : {}),
                }),
              );
              const resolvedMembershipKeys = new Set<string>();
              if (identityId && !isGatewayAdmin(client)) {
                const groups = new Map<
                  string,
                  {
                    agentId: string;
                    sessionKeys: string[];
                    storePath: string;
                  }
                >();
                for (const target of resolvedSharingTargets) {
                  if (!target) {
                    continue;
                  }
                  const groupKey = `${target.agentId}\0${target.storePath}`;
                  const group = groups.get(groupKey) ?? {
                    agentId: target.agentId,
                    sessionKeys: [],
                    storePath: target.storePath,
                  };
                  group.sessionKeys.push(target.storeKey);
                  groups.set(groupKey, group);
                }
                for (const group of groups.values()) {
                  const firstSessionKey = group.sessionKeys[0];
                  if (!firstSessionKey) {
                    continue;
                  }
                  for (const sessionKey of listSessionMembershipKeys(
                    {
                      agentId: group.agentId,
                      sessionKey: firstSessionKey,
                      storePath: group.storePath,
                    },
                    group.sessionKeys,
                    identityId,
                  )) {
                    resolvedMembershipKeys.add(
                      `${group.agentId}\0${group.storePath}\0${sessionKey}`,
                    );
                  }
                }
              }
              return {
                sharingTargets: resolvedSharingTargets,
                membershipKeys: resolvedMembershipKeys,
              };
            },
            {
              config: cfg,
              phase: "sessions.list",
              attributes: {
                sessions: result.sessions.length,
              },
            },
          );
'@
$newSharing = @'
          const identityId = gatewayClientSessionCreator(client)?.id;
          const {
            sharingTargets,
            membershipKeys: resolvedMembershipKeys,
          } = await measureDiagnosticsTimelineSpan(
            "gateway.sessions.list.sharing",
            () =>
              resolveSessionListSharingAsync({
                cfg,
                sessionKeys: result.sessions.map((session) => session.key),
                ...(identityId && !isGatewayAdmin(client) ? { identityId } : {}),
                ...(p.agentId ? { agentId: p.agentId } : {}),
              }),
            {
              config: cfg,
              phase: "sessions.list",
              attributes: {
                sessions: result.sessions.length,
              },
            },
          );
          const membershipKeys = new Set(resolvedMembershipKeys);
'@
$text = Replace-One $text $oldSharing $newSharing "sessions-read sharing worker"
$changes[$path] = $text

# ---------------------------------------------------------------------------
# Prevent duplicate sessions.list work from piling up while mutations advance
# the fence. A newer request waits for the one already running, then retries at
# the current fence instead of starting another expensive projection in parallel.
# ---------------------------------------------------------------------------

$path = Join-Path $Repo "src/gateway/server-methods/sessions-list-cache.ts"
$text = [IO.File]::ReadAllText($path)

$text = Replace-One $text @'
  const pending = state.inFlight.get(workKey);
  if (pending && matchesSessionListFence(pending, fence)) {
    params.respond(true, await pending.promise, undefined);
    return;
  }

  // A request may share only work begun at the same fence. A transition during projection
  // leaves current callers intact but fences every later caller and cache write.
'@ @'
  const pending = state.inFlight.get(workKey);
  if (pending) {
    if (matchesSessionListFence(pending, fence)) {
      params.respond(true, await pending.promise, undefined);
      return;
    }
    // Do not start duplicate SQLite/projection work merely because the mutation fence moved
    // while the previous list was still running. Wait for it to drain, then retry against
    // the current fence. The retried request still receives an authoritative fresh result.
    try {
      await pending.promise;
    } catch {
      // The retry below owns error reporting for the current request.
    }
    if (state.inFlight.get(workKey) === pending) {
      state.inFlight.delete(workKey);
    }
    return respondWithCachedSessionList(params);
  }

  // A request may share only work begun at the same fence. A transition during projection
  // leaves current callers intact but fences every later caller and cache write.
'@ "sessions-list in-flight coalescing"
$changes[$path] = $text

# ---------------------------------------------------------------------------
# Optional post-ready prewarm is disabled by default. It is a latency hint only,
# and on large/slow stores it competes with real Gateway work immediately after
# readiness. Explicit opt-in remains available for fast environments.
# ---------------------------------------------------------------------------

$path = Join-Path $Repo "src/gateway/server-startup-handler-prewarm.ts"
$text = [IO.File]::ReadAllText($path)

$text = Replace-One $text @'
const SIDEBAR_SESSION_LIST_LIMIT = 60;
const SIDEBAR_PREWARM_MAX_SESSION_ENTRIES = 2_000;
const GATEWAY_HANDLER_PREWARM_RETRY_DELAY_MS = 250;
'@ @'
const SIDEBAR_SESSION_LIST_LIMIT = 60;
const SIDEBAR_PREWARM_MAX_SESSION_ENTRIES = 2_000;
const GATEWAY_HANDLER_PREWARM_RETRY_DELAY_MS = 250;
const DASHBOARD_PREWARM_ENV = "OPENCLAW_ENABLE_DASHBOARD_PREWARM";

function isDashboardPrewarmEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
  const value = env[DASHBOARD_PREWARM_ENV]?.trim().toLowerCase();
  return value === "1" || value === "true" || value === "yes" || value === "on";
}
'@ "dashboard prewarm env gate"

$text = Replace-One $text @'
function dashboardDataPrewarmItems(
  cfg: OpenClawConfig,
  log: { info?: (msg: string) => void },
): GatewayHandlerPrewarmItem[] {
  const agentIds = listAgentIds(cfg);
'@ @'
function dashboardDataPrewarmItems(
  cfg: OpenClawConfig,
  log: { info?: (msg: string) => void },
): GatewayHandlerPrewarmItem[] {
  if (!isDashboardPrewarmEnabled()) {
    log.info?.(
      `skipping optional dashboard prewarm; set ${DASHBOARD_PREWARM_ENV}=1 to enable`,
    );
    return [];
  }
  const agentIds = listAgentIds(cfg);
'@ "dashboard prewarm default off"
$changes[$path] = $text

# ---------------------------------------------------------------------------
# Build entry for the new stable worker filename.
# ---------------------------------------------------------------------------

$path = Join-Path $Repo "tsdown.config.ts"
$text = [IO.File]::ReadAllText($path)
$text = Replace-One $text @'
    "config/sessions/combined-store-gateway.worker":
      "src/config/sessions/combined-store-gateway.worker.ts",
    "config/sessions/session-transcript-reconcile.worker":
'@ @'
    "config/sessions/combined-store-gateway.worker":
      "src/config/sessions/combined-store-gateway.worker.ts",
    "gateway/session-list-read.worker": "src/gateway/session-list-read.worker.ts",
    "config/sessions/session-transcript-reconcile.worker":
'@ "tsdown session-list worker entry"
$changes[$path] = $text

# ---------------------------------------------------------------------------
# Write only after every anchor has validated.
# ---------------------------------------------------------------------------

foreach ($entry in $changes.GetEnumerator()) {
    $target = $entry.Key
    $dir = Split-Path -Parent $target
    if (-not (Test-Path $dir)) {
        [IO.Directory]::CreateDirectory($dir) | Out-Null
    }
    [IO.File]::WriteAllText($target, [string]$entry.Value, $encoding)
}

Write-Host ""
Write-Host "Applied Gateway session-read hardening batch."
Write-Host ""

git diff --check
if ($LASTEXITCODE -ne 0) {
    throw "git diff --check failed."
}

git status --short

Write-Host ""
Write-Host "Build and verify:"
Write-Host "  pnpm build"
Write-Host "  Test-Path .\dist\gateway\session-list-read.worker.js"
Write-Host ""
Write-Host "Optional: re-enable post-ready dashboard prewarm only for testing:"
Write-Host '  $env:OPENCLAW_ENABLE_DASHBOARD_PREWARM = "1"'
