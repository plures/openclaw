import { isMainThread, parentPort } from "node:worker_threads";
import {
  readRecentSessionTranscriptMessageEvents,
  readSessionTranscriptMessageAnchorPage,
  readSessionTranscriptMessageEventById,
  readSessionTranscriptMessageEventCount,
  readSessionTranscriptMessageEventPage,
  readSessionTranscriptMessageEvents,
  type SessionTranscriptReadScope,
} from "../config/sessions/session-accessor.js";

type WorkerRequest =
  | { id: number; type: "events"; scope: SessionTranscriptReadScope }
  | {
      id: number;
      type: "recent";
      scope: SessionTranscriptReadScope;
      options: Parameters<typeof readRecentSessionTranscriptMessageEvents>[1];
    }
  | { id: number; type: "by-id"; scope: SessionTranscriptReadScope; messageId: string }
  | { id: number; type: "count"; scope: SessionTranscriptReadScope }
  | {
      id: number;
      type: "page";
      scope: SessionTranscriptReadScope;
      options: Parameters<typeof readSessionTranscriptMessageEventPage>[1];
    }
  | {
      id: number;
      type: "anchor";
      scope: SessionTranscriptReadScope;
      options: Parameters<typeof readSessionTranscriptMessageAnchorPage>[1];
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

if (!isMainThread && parentPort) {
  parentPort.on("message", (request: WorkerRequest) => {
    let response: WorkerResponse;
    try {
      let result: unknown;
      switch (request.type) {
        case "events":
          result = readSessionTranscriptMessageEvents(request.scope);
          break;
        case "recent":
          result = readRecentSessionTranscriptMessageEvents(request.scope, request.options);
          break;
        case "by-id":
          result = readSessionTranscriptMessageEventById(request.scope, request.messageId);
          break;
        case "count":
          result = readSessionTranscriptMessageEventCount(request.scope);
          break;
        case "page":
          result = readSessionTranscriptMessageEventPage(request.scope, request.options);
          break;
        case "anchor":
          result = readSessionTranscriptMessageAnchorPage(request.scope, request.options);
          break;
      }
      response = { id: request.id, ok: true, result };
    } catch (error) {
      response = { id: request.id, ok: false, error: serializeError(error) };
    }

    // Node MessagePort.postMessage is not the browser Window API.
    // oxlint-disable-next-line unicorn/require-post-message-target-origin
    parentPort.postMessage(response);
  });
}
