# Apply worker-thread materialization for Gateway combined session stores.
# Target: plures/openclaw corporate-install branch (2026-08-07 snapshot).
# This script uses anchored source transformations instead of git-apply hunks.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Repo = Join-Path $HOME "openclaw"
Set-Location $Repo

$branch = (git branch --show-current).Trim()
if ($branch -ne "corporate-install") {
    throw "Expected branch 'corporate-install'; current branch is '$branch'."
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
# src/config/sessions/combined-store-gateway.ts
# ---------------------------------------------------------------------------
$path = Join-Path $Repo "src/config/sessions/combined-store-gateway.ts"
$text = [IO.File]::ReadAllText($path)

$old = @'
type GatewaySessionStoreOptions = {
  agentId?: string;
  configuredAgentsOnly?: boolean;
  includeIncognito?: boolean;
  projection?: SessionEntryListScope["projection"];
};
'@
$new = @'
export type GatewaySessionStoreOptions = {
  agentId?: string;
  configuredAgentsOnly?: boolean;
  includeIncognito?: boolean;
  projection?: SessionEntryListScope["projection"];
};

export type GatewayCombinedSessionStoreResult = {
  diagnostics?: string[];
  durableStorePath?: string;
  storePath: string;
  store: Record<string, SessionEntry>;
};
'@
$text = Replace-One $text $old $new "combined-store options/result types"

$old = @'
export function loadCombinedSessionStoreForGateway(
  cfg: OpenClawConfig,
  opts: GatewaySessionStoreOptions = {},
): {
  diagnostics?: string[];
  durableStorePath?: string;
  storePath: string;
  store: Record<string, SessionEntry>;
} {
'@
$new = @'
export function loadCombinedSessionStoreForGateway(
  cfg: OpenClawConfig,
  opts: GatewaySessionStoreOptions = {},
): GatewayCombinedSessionStoreResult {
'@
$text = Replace-One $text $old $new "combined-store return type"

$append = @'

/**
 * Merge process-local open incognito stores into an already materialized durable projection.
 *
 * The async Gateway loader materializes durable SQLite stores in a worker thread. Open
 * incognito database registrations are process-local, so the Gateway process merges those
 * rows after the worker result returns.
 */
export function mergeOpenIncognitoSessionStoresForGateway(
  cfg: OpenClawConfig,
  result: GatewayCombinedSessionStoreResult,
  opts: GatewaySessionStoreOptions = {},
): GatewayCombinedSessionStoreResult {
  if (opts.includeIncognito === false) {
    return result;
  }

  const projection = opts.projection ?? "full";
  const requestedAgentId =
    typeof opts.agentId === "string" && opts.agentId.trim()
      ? normalizeAgentId(opts.agentId)
      : undefined;
  const configuredAgentIds =
    opts.configuredAgentsOnly === true && !requestedAgentId
      ? new Set(listConfiguredSessionStoreAgentIds(cfg))
      : undefined;
  const allowedIncognitoAgentIds = requestedAgentId
    ? new Set([requestedAgentId])
    : configuredAgentIds;
  const incognitoTargets = listOpenIncognitoAgentDatabases().filter(
    (target) => !allowedIncognitoAgentIds || allowedIncognitoAgentIds.has(target.agentId),
  );
  if (incognitoTargets.length === 0) {
    return result;
  }

  const combined = { ...result.store };
  const incognitoStorePaths = mergeOpenIncognitoStores({
    cfg,
    combined,
    projection,
    targets: incognitoTargets,
  });
  if (incognitoStorePaths.length === 0) {
    return result;
  }

  const storeConfig = cfg.session?.store;
  const storePath =
    storeConfig && !isStorePathTemplate(storeConfig)
      ? "(multiple)"
      : resolveCombinedStorePath([result.storePath, ...incognitoStorePaths], storeConfig);

  return {
    ...result,
    storePath,
    store: combined,
  };
}
'@

if ($text -notmatch 'export function mergeOpenIncognitoSessionStoresForGateway\(') {
    $nl = Get-Newline $text
    $text = $text.TrimEnd([char[]]"`r`n") + (Convert-Newlines $append $nl) + $nl
} else {
    throw "combined-store incognito merge helper already exists."
}
$changes[$path] = $text

# ---------------------------------------------------------------------------
# New async loader
# ---------------------------------------------------------------------------
$asyncPath = Join-Path $Repo "src/config/sessions/combined-store-gateway-async.ts"
$asyncText = @'
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { Worker } from "node:worker_threads";
import type { OpenClawConfig } from "../types.openclaw.js";
import {
  mergeOpenIncognitoSessionStoresForGateway,
  type GatewayCombinedSessionStoreResult,
  type GatewaySessionStoreOptions,
} from "./combined-store-gateway.js";

type WorkerRequest = {
  id: number;
  cfg: OpenClawConfig;
  opts: GatewaySessionStoreOptions;
};

type WorkerResponse =
  | { id: number; ok: true; result: GatewayCombinedSessionStoreResult }
  | { id: number; ok: false; error: { message: string; stack?: string } };

type PendingRequest = {
  resolve: (result: GatewayCombinedSessionStoreResult) => void;
  reject: (error: Error) => void;
};

let combinedStoreWorker: Worker | undefined;
let nextRequestId = 1;
const pendingRequests = new Map<number, PendingRequest>();

function resolveCombinedStoreWorkerUrl(currentModuleUrl = import.meta.url): URL {
  const currentPath = fileURLToPath(currentModuleUrl);
  const normalized = currentPath.replaceAll(path.sep, "/");
  const distMarker = "/dist/";
  const distIndex = normalized.lastIndexOf(distMarker);
  if (distIndex >= 0) {
    const distRoot = currentPath.slice(0, distIndex + distMarker.length);
    return pathToFileURL(
      path.join(distRoot, "config", "sessions", "combined-store-gateway.worker.js"),
    );
  }
  const extension = path.extname(currentPath) || ".js";
  return new URL(`./combined-store-gateway.worker${extension}`, currentModuleUrl);
}

function rejectPendingRequests(error: Error): void {
  for (const pending of pendingRequests.values()) {
    pending.reject(error);
  }
  pendingRequests.clear();
}

function resetWorker(worker: Worker, error?: Error): void {
  if (combinedStoreWorker !== worker) {
    return;
  }
  combinedStoreWorker = undefined;
  if (error) {
    rejectPendingRequests(error);
  }
}

function handleWorkerResponse(response: WorkerResponse): void {
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
}

function getCombinedStoreWorker(): Worker {
  if (combinedStoreWorker) {
    return combinedStoreWorker;
  }

  const workerUrl = resolveCombinedStoreWorkerUrl();
  const sourceWorkerExecArgv = workerUrl.pathname.endsWith(".ts")
    ? ["--import", "tsx"]
    : undefined;
  const worker = new Worker(workerUrl, {
    execArgv: sourceWorkerExecArgv,
  });
  worker.unref?.();
  worker.on("message", (response: WorkerResponse) => handleWorkerResponse(response));
  worker.on("error", (error) => resetWorker(worker, error));
  worker.on("exit", (code) => {
    resetWorker(
      worker,
      pendingRequests.size > 0
        ? new Error(`combined session store worker exited with code ${code}`)
        : undefined,
    );
  });
  combinedStoreWorker = worker;
  return worker;
}

function materializeDurableCombinedSessionStore(
  cfg: OpenClawConfig,
  opts: GatewaySessionStoreOptions,
): Promise<GatewayCombinedSessionStoreResult> {
  const worker = getCombinedStoreWorker();
  const id = nextRequestId++;
  const request: WorkerRequest = {
    id,
    cfg,
    // Open incognito DB registrations are local to the Gateway process.
    opts: { ...opts, includeIncognito: false },
  };

  return new Promise((resolve, reject) => {
    pendingRequests.set(id, { resolve, reject });
    try {
      // Node Worker.postMessage is not the browser Window API and has no targetOrigin.
      // oxlint-disable-next-line unicorn/require-post-message-target-origin
      worker.postMessage(request);
    } catch (error) {
      pendingRequests.delete(id);
      reject(error instanceof Error ? error : new Error(String(error)));
    }
  });
}

/**
 * Materialize the Gateway combined durable session store without blocking its event loop.
 *
 * Durable SQLite reads and canonicalization run in a persistent worker thread. Process-local
 * open incognito rows are merged after the worker result returns.
 */
export async function loadCombinedSessionStoreForGatewayAsync(
  cfg: OpenClawConfig,
  opts: GatewaySessionStoreOptions = {},
): Promise<GatewayCombinedSessionStoreResult> {
  const durable = await materializeDurableCombinedSessionStore(cfg, opts);
  return mergeOpenIncognitoSessionStoresForGateway(cfg, durable, opts);
}
'@

if (Test-Path $asyncPath) {
    throw "Refusing to overwrite existing $asyncPath"
}
$changes[$asyncPath] = Convert-Newlines $asyncText "`n"

# ---------------------------------------------------------------------------
# New worker
# ---------------------------------------------------------------------------
$workerPath = Join-Path $Repo "src/config/sessions/combined-store-gateway.worker.ts"
$workerText = @'
import { isMainThread, parentPort } from "node:worker_threads";
import type { OpenClawConfig } from "../types.openclaw.js";
import {
  loadCombinedSessionStoreForGateway,
  type GatewayCombinedSessionStoreResult,
  type GatewaySessionStoreOptions,
} from "./combined-store-gateway.js";

type WorkerRequest = {
  id: number;
  cfg: OpenClawConfig;
  opts: GatewaySessionStoreOptions;
};

type WorkerResponse =
  | { id: number; ok: true; result: GatewayCombinedSessionStoreResult }
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
      const result = loadCombinedSessionStoreForGateway(request.cfg, {
        ...request.opts,
        includeIncognito: false,
      });
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

if (Test-Path $workerPath) {
    throw "Refusing to overwrite existing $workerPath"
}
$changes[$workerPath] = Convert-Newlines $workerText "`n"

# ---------------------------------------------------------------------------
# src/gateway/server-startup-handler-prewarm.ts
# ---------------------------------------------------------------------------
$path = Join-Path $Repo "src/gateway/server-startup-handler-prewarm.ts"
$text = [IO.File]::ReadAllText($path)

$old = @'
  const [{ loadCombinedSessionStoreForGateway }, { listSessionsFromStoreAsync }] =
    await Promise.all([
      import("../config/sessions/combined-store-gateway.js"),
      import("./session-utils-list.js"),
    ]);
  const { durableStorePath, storePath, store } = loadCombinedSessionStoreForGateway(cfg, {
    agentId,
    projection: "list",
  });
'@
$new = @'
  const [{ loadCombinedSessionStoreForGatewayAsync }, { listSessionsFromStoreAsync }] =
    await Promise.all([
      import("../config/sessions/combined-store-gateway-async.js"),
      import("./session-utils-list.js"),
    ]);
  const { durableStorePath, storePath, store } = await loadCombinedSessionStoreForGatewayAsync(
    cfg,
    {
      agentId,
      projection: "list",
    },
  );
'@
$text = Replace-One $text $old $new "startup prewarm async materialization"
$changes[$path] = $text

# ---------------------------------------------------------------------------
# src/gateway/server-methods/sessions-read.ts
# ---------------------------------------------------------------------------
$path = Join-Path $Repo "src/gateway/server-methods/sessions-read.ts"
$text = [IO.File]::ReadAllText($path)

$old = @'
} from "../../config/sessions.js";
import { listSessionEntriesReadOnly } from "../../config/sessions/session-accessor.js";
'@
$new = @'
} from "../../config/sessions.js";
import { loadCombinedSessionStoreForGatewayAsync } from "../../config/sessions/combined-store-gateway-async.js";
import { listSessionEntriesReadOnly } from "../../config/sessions/session-accessor.js";
'@
$text = Replace-One $text $old $new "sessions-read async loader import"

$old = @'
  buildGatewaySessionRow,
  listSessionsFromStoreAsync,
  loadCombinedSessionStoreForGateway,
  resolveCanonicalSessionEntryFromStoreKeys,
'@
$new = @'
  buildGatewaySessionRow,
  listSessionsFromStoreAsync,
  resolveCanonicalSessionEntryFromStoreKeys,
'@
$text = Replace-One $text $old $new "sessions-read remove sync loader import"

$old = @'
            const { durableStorePath, storePath, store } = measureDiagnosticsTimelineSpanSync(
              "gateway.sessions.list.store_load",
              () =>
                loadCombinedSessionStoreForGateway(cfg, {
                  agentId: p.agentId,
                  projection: "list",
                }),
              {
                config: cfg,
                phase: "sessions.list",
                attributes: {
                  agentId: p.agentId ?? null,
                  configuredAgentsOnly,
                },
              },
            );
'@
$new = @'
            const { durableStorePath, storePath, store } = await measureDiagnosticsTimelineSpan(
              "gateway.sessions.list.store_load",
              () =>
                loadCombinedSessionStoreForGatewayAsync(cfg, {
                  agentId: p.agentId,
                  projection: "list",
                }),
              {
                config: cfg,
                phase: "sessions.list",
                attributes: {
                  agentId: p.agentId ?? null,
                  configuredAgentsOnly,
                },
              },
            );
'@
$text = Replace-One $text $old $new "sessions.list async store_load span"
$changes[$path] = $text

# ---------------------------------------------------------------------------
# tsdown.config.ts
# ---------------------------------------------------------------------------
$path = Join-Path $Repo "tsdown.config.ts"
$text = [IO.File]::ReadAllText($path)

$old = @'
    "config/sessions/session-accessor.sqlite-archive.worker":
      "src/config/sessions/session-accessor.sqlite-archive.worker.ts",
    "config/sessions/session-transcript-reconcile.worker":
'@
$new = @'
    "config/sessions/session-accessor.sqlite-archive.worker":
      "src/config/sessions/session-accessor.sqlite-archive.worker.ts",
    "config/sessions/combined-store-gateway.worker":
      "src/config/sessions/combined-store-gateway.worker.ts",
    "config/sessions/session-transcript-reconcile.worker":
'@
$text = Replace-One $text $old $new "tsdown worker entry"
$changes[$path] = $text

# ---------------------------------------------------------------------------
# Commit all filesystem writes only after every source anchor validated.
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
Write-Host "Applied worker-thread combined-session-store changes."
Write-Host ""

git diff --check
if ($LASTEXITCODE -ne 0) {
    throw "git diff --check failed."
}

git status --short
Write-Host ""
Write-Host "Next:"
Write-Host "  pnpm build"
