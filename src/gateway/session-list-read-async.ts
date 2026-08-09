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
  worker.on("error", (error) =>
    resetWorker(worker, error instanceof Error ? error : new Error(String(error))),
  );
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
