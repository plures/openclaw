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
