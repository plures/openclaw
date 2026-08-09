import { isMainThread, parentPort } from "node:worker_threads";
import { readAcpSessionMetaBatch } from "../acp/runtime/session-meta.js";
import { listSessionMembershipKeys, type SessionEntry } from "../config/sessions.js";
import type { SessionTranscriptReadScope } from "../config/sessions/session-accessor.js";
import type { OpenClawConfig } from "../config/types.openclaw.js";
import { resolveSessionSharingTarget, type SessionSharingTarget } from "./session-sharing.js";
import { readSessionTitleFieldsFromTranscriptBatch } from "./session-transcript-title-reader.js";
import type {
  GatewaySessionStoreCache,
  GatewaySessionStoreDiscoveryCache,
} from "./session-utils-store-lookup.js";

type AcpMetaEntry = {
  sessionKey: string;
  entry: SessionEntry;
};

type WorkerRequest =
  | {
      id: number;
      type: "title-fields";
      scopes: SessionTranscriptReadScope[];
      includeInterSession?: boolean;
    }
  | {
      id: number;
      type: "acp-meta";
      entries: AcpMetaEntry[];
    }
  | {
      id: number;
      type: "sharing";
      cfg: OpenClawConfig;
      sessionKeys: string[];
      identityId?: string;
      agentId?: string;
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

function resolveSharing(request: Extract<WorkerRequest, { type: "sharing" }>) {
  const sharingStoreCache: GatewaySessionStoreCache = new Map();
  const targetDiscoveryCache: GatewaySessionStoreDiscoveryCache = new Map();
  const sharingTargets = request.sessionKeys.map((sessionKey) =>
    resolveSessionSharingTarget({
      cfg: request.cfg,
      projection: "list",
      sessionKey,
      storeCache: sharingStoreCache,
      targetDiscoveryCache,
      ...(sessionKey === "global" && request.agentId ? { agentId: request.agentId } : {}),
    }),
  );

  const membershipKeys: string[] = [];
  if (request.identityId) {
    const groups = new Map<
      string,
      {
        agentId: string;
        sessionKeys: string[];
        storePath: string;
      }
    >();

    for (const target of sharingTargets) {
      if (!target) {
        continue;
      }
      const groupKey = `${target.agentId}\0${target.storePath}`;
      const group = groups.get(groupKey) ?? {
        agentId: target.agentId,
        sessionKeys: [],
        storePath: target.storePath,
      };
      group.sessionKeys.push(target.storeKey);
      groups.set(groupKey, group);
    }

    for (const group of groups.values()) {
      const firstSessionKey = group.sessionKeys[0];
      if (!firstSessionKey) {
        continue;
      }
      for (const sessionKey of listSessionMembershipKeys(
        {
          agentId: group.agentId,
          sessionKey: firstSessionKey,
          storePath: group.storePath,
        },
        group.sessionKeys,
        request.identityId,
      )) {
        membershipKeys.push(`${group.agentId}\0${group.storePath}\0${sessionKey}`);
      }
    }
  }

  return {
    sharingTargets: sharingTargets as Array<SessionSharingTarget | null>,
    membershipKeys,
  };
}

if (!isMainThread && parentPort) {
  const port = parentPort;
  port.on("message", (request: WorkerRequest) => {
    let response: WorkerResponse;
    try {
      let result: unknown = undefined;
      switch (request.type) {
        case "title-fields":
          result = readSessionTitleFieldsFromTranscriptBatch(request.scopes, {
            ...(request.includeInterSession === true ? { includeInterSession: true } : {}),
          });
          break;
        case "acp-meta": {
          const metaByEntry = readAcpSessionMetaBatch({ entries: request.entries });
          result = request.entries.map(({ entry }) => metaByEntry.get(entry));
          break;
        }
        case "sharing":
          result = resolveSharing(request);
          break;
      }
      response = { id: request.id, ok: true, result };
    } catch (error) {
      response = { id: request.id, ok: false, error: serializeError(error) };
    }

    // Node MessagePort.postMessage is not the browser Window API and has no targetOrigin.
    // oxlint-disable-next-line unicorn/require-post-message-target-origin
    port.postMessage(response);
  });
}
