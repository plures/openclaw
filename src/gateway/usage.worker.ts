import { isMainThread, parentPort } from "node:worker_threads";
import type { OpenClawConfig } from "../config/types.openclaw.js";
import type { UsageSummary } from "../infra/provider-usage.types.js";
import type { CostUsageSummary } from "../infra/session-cost-usage.js";
import type { UsageDailyBucket } from "../infra/session-cost-usage.js";

type WorkerRequest =
  | {
      id: number;
      type: "status";
      config: OpenClawConfig;
    }
  | {
      id: number;
      type: "cost";
      config: OpenClawConfig;
      startMs: number;
      endMs: number;
      dayBucket?: UsageDailyBucket;
      agentId?: string;
      agentScope?: "all";
    };
type WorkerResponse =
  | { id: number; ok: true; result: UsageSummary | CostUsageSummary }
  | { id: number; ok: false; error: { message: string; stack?: string } };

function serializeError(error: unknown): { message: string; stack?: string } {
  if (error instanceof Error) {
    return { message: error.message, ...(error.stack ? { stack: error.stack } : {}) };
  }
  return { message: String(error) };
}

if (!isMainThread && parentPort) {
  const port = parentPort;
  port.on("message", async (request: WorkerRequest) => {
    let response: WorkerResponse;
    try {
      const result =
        request.type === "status"
          ? await import("./server-methods/models-auth-status-usage-cache.js").then((module) =>
              module.loadUsageStatusStaleWhileRevalidate({ config: request.config }),
            )
          : await import("./server-methods/usage.js").then((module) =>
              module.loadCostUsageSummaryCached({
                config: request.config,
                startMs: request.startMs,
                endMs: request.endMs,
                ...(request.dayBucket ? { dayBucket: request.dayBucket } : {}),
                ...(request.agentId ? { agentId: request.agentId } : {}),
                ...(request.agentScope ? { agentScope: request.agentScope } : {}),
              }),
            );
      response = { id: request.id, ok: true, result };
    } catch (error) {
      response = { id: request.id, ok: false, error: serializeError(error) };
    }
    // Node MessagePort.postMessage is not the browser Window API.
    // oxlint-disable-next-line unicorn/require-post-message-target-origin
    port.postMessage(response);
  });
}
