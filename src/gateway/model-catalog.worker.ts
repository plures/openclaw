import { isMainThread, parentPort } from "node:worker_threads";
import { resolvePublishedModelCatalogOwner } from "../agents/prepared-model-catalog-owner.js";
import type { OpenClawConfig } from "../config/types.openclaw.js";

type WorkerRequest = {
  id: number;
  agentId?: string;
  agentDir?: string;
  config: OpenClawConfig;
  readOnly: boolean;
  workspaceDir?: string;
};
type WorkerResponse =
  | { id: number; ok: true; result: unknown }
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
      const { loadPublishedPreparedModelCatalogOwnerSnapshot } =
        await import("../agents/prepared-model-catalog.js");
      const owner = resolvePublishedModelCatalogOwner(
        await loadPublishedPreparedModelCatalogOwnerSnapshot({
          ...(request.agentId ? { agentId: request.agentId } : {}),
          ...(request.agentDir ? { agentDir: request.agentDir } : {}),
          config: request.config,
          readOnly: request.readOnly,
          ...(request.workspaceDir ? { workspaceDir: request.workspaceDir } : {}),
        }),
      );
      response = {
        id: request.id,
        ok: true,
        result: {
          ...owner.modelCatalog,
          agentId: owner.agentId,
          agentDir: owner.agentDir,
          workspaceDir: owner.workspaceDir,
          config: owner.config,
        },
      };
    } catch (error) {
      response = { id: request.id, ok: false, error: serializeError(error) };
    }
    // Node MessagePort.postMessage is not the browser Window API.
    // oxlint-disable-next-line unicorn/require-post-message-target-origin
    port.postMessage(response);
  });
}
