import { isMainThread, parentPort } from "node:worker_threads";
import type { SessionTranscriptReadScope } from "./session-accessor.sqlite-contract.js";
import {
  hasSqliteTranscriptMessageEventsSync,
  loadSqliteTranscriptEventsSync,
} from "./session-accessor.sqlite-read.js";

type WorkerRequest =
  | { id: number; type: "load"; scope: SessionTranscriptReadScope }
  | { id: number; type: "has-message"; scope: SessionTranscriptReadScope };

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
      const result =
        request.type === "load"
          ? loadSqliteTranscriptEventsSync(request.scope)
          : hasSqliteTranscriptMessageEventsSync(request.scope);
      response = { id: request.id, ok: true, result };
    } catch (error) {
      response = { id: request.id, ok: false, error: serializeError(error) };
    }

    // Node MessagePort.postMessage is not the browser Window API.
    // oxlint-disable-next-line unicorn/require-post-message-target-origin
    parentPort.postMessage(response);
  });
}
