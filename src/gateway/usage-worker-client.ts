import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { Worker } from "node:worker_threads";
import type { OpenClawConfig } from "../config/types.openclaw.js";
import type { UsageSummary } from "../infra/provider-usage.types.js";
import type { CostUsageSummary, UsageDailyBucket } from "../infra/session-cost-usage.js";

type UsageWorkerRequest =
  | { type: "status"; config: OpenClawConfig }
  | {
      type: "cost";
      config: OpenClawConfig;
      startMs: number;
      endMs: number;
      dayBucket?: UsageDailyBucket;
      agentId?: string;
      agentScope?: "all";
    };
type UsageWorkerResponse =
  | { id: number; ok: true; result: UsageSummary | CostUsageSummary }
  | { id: number; ok: false; error: { message: string; stack?: string } };
type PendingRequest = {
  resolve: (result: UsageSummary | CostUsageSummary) => void;
  reject: (error: Error) => void;
};

let workerInstance: Worker | undefined;
let nextRequestId = 1;
const pendingRequests = new Map<number, PendingRequest>();

export function resolveUsageWorkerUrl(currentModuleUrl = import.meta.url): URL {
  const currentPath = fileURLToPath(currentModuleUrl);
  const normalized = currentPath.replaceAll(path.sep, "/");
  const distMarker = "/dist/";
  const distIndex = normalized.lastIndexOf(distMarker);
  if (distIndex >= 0) {
    const distRoot = currentPath.slice(0, distIndex + distMarker.length);
    return pathToFileURL(path.join(distRoot, "gateway", "usage.worker.js"));
  }
  const extension = path.extname(currentPath) || ".js";
  return new URL(`./usage.worker${extension}`, currentModuleUrl);
}

function rejectAllPending(error: Error): void {
  for (const pending of pendingRequests.values()) pending.reject(error);
  pendingRequests.clear();
}

function resetWorker(worker: Worker, error?: Error): void {
  if (workerInstance !== worker) return;
  workerInstance = undefined;
  if (error) rejectAllPending(error);
}

function getWorker(): Worker {
  if (workerInstance) return workerInstance;
  const workerUrl = resolveUsageWorkerUrl();
  const worker = new Worker(workerUrl, {
    execArgv: workerUrl.pathname.endsWith(".ts") ? ["--import", "tsx"] : undefined,
  });
  worker.unref?.();
  worker.on("message", (response: UsageWorkerResponse) => {
    const pending = pendingRequests.get(response.id);
    if (!pending) return;
    pendingRequests.delete(response.id);
    if (response.ok) {
      pending.resolve(response.result);
      return;
    }
    const error = new Error(response.error.message);
    if (response.error.stack) error.stack = response.error.stack;
    pending.reject(error);
  });
  worker.on("error", (error) =>
    resetWorker(worker, error instanceof Error ? error : new Error(String(error))),
  );
  worker.on("exit", (code) => {
    resetWorker(
      worker,
      pendingRequests.size > 0 ? new Error(`usage worker exited with code ${code}`) : undefined,
    );
  });
  workerInstance = worker;
  return worker;
}

function requestWorker<T extends UsageSummary | CostUsageSummary>(
  request: UsageWorkerRequest,
): Promise<T> {
  const worker = getWorker();
  const id = nextRequestId++;
  return new Promise((resolve, reject) => {
    pendingRequests.set(id, { resolve: (result) => resolve(result as T), reject });
    try {
      // Node Worker.postMessage is not the browser Window API.
      // oxlint-disable-next-line unicorn/require-post-message-target-origin
      worker.postMessage({ ...request, id });
    } catch (error) {
      pendingRequests.delete(id);
      reject(error instanceof Error ? error : new Error(String(error)));
    }
  });
}

export function loadUsageStatusInWorker(config: OpenClawConfig): Promise<UsageSummary> {
  return requestWorker({ type: "status", config });
}

export function loadUsageCostInWorker(params: {
  config: OpenClawConfig;
  startMs: number;
  endMs: number;
  dayBucket?: UsageDailyBucket;
  agentId?: string;
  agentScope?: "all";
}): Promise<CostUsageSummary> {
  return requestWorker({ type: "cost", ...params });
}
