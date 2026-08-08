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
  const sourceWorkerExecArgv = workerUrl.pathname.endsWith(".ts") ? ["--import", "tsx"] : undefined;
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
