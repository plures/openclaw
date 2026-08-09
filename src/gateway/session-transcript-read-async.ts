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
import type { SessionPreviewItem } from "./session-utils.types.js";

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
  | { type: "anchor"; scope: SessionTranscriptReadScope; options: AnchorOptions }
  | {
      type: "preview";
      scope: SessionTranscriptReadScope;
      maxItems: number;
      maxChars: number;
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
  return coalesced(key, () => requestWorker<RecentResult>({ type: "recent", scope, options }));
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
  return coalesced(key, () => requestWorker<PageResult>({ type: "page", scope, options }));
}

export function readSessionTranscriptMessageAnchorPageAsync(
  scope: SessionTranscriptReadScope,
  options: AnchorOptions,
): Promise<AnchorResult> {
  const key = `anchor\0${scopeKey(scope)}\0${JSON.stringify(options)}`;
  return coalesced(key, () => requestWorker<AnchorResult>({ type: "anchor", scope, options }));
}

export function readSessionPreviewItemsInWorkerAsync(
  scope: SessionTranscriptReadScope,
  maxItems: number,
  maxChars: number,
): Promise<SessionPreviewItem[]> {
  return coalesced(`preview\0${scopeKey(scope)}\0${maxItems}\0${maxChars}`, () =>
    requestWorker<SessionPreviewItem[]>({ type: "preview", scope, maxItems, maxChars }),
  );
}
