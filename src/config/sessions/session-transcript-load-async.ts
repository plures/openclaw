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
  return [scope.agentId ?? "", scope.sessionId, scope.sessionKey ?? "", scope.storePath ?? ""].join(
    "\0",
  );
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
