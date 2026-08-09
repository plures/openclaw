import { resolvePublishedModelCatalogOwner } from "../agents/prepared-model-catalog-owner.js";
import type { PublishedModelCatalogOwnerCandidate } from "../agents/prepared-model-catalog.types.js";
// Gateway catalog reads use the atomic prepared runtime generation.
import { getRuntimeConfig } from "../config/io.js";
import { ModelCatalogCache } from "./model-catalog-cache.js";
import { loadGatewayModelCatalogSnapshotInWorker } from "./model-catalog-worker-client.js";
import type {
  GatewayModelCatalogOwnerSnapshot,
  GatewayModelCatalogSnapshot,
} from "./server-model-catalog.types.js";

export type GatewayModelChoice = import("../agents/model-catalog.js").ModelCatalogEntry;
export type { GatewayModelCatalogSnapshot } from "./server-model-catalog.types.js";

type GatewayModelCatalogConfig = ReturnType<typeof getRuntimeConfig>;
type LoadPublishedPreparedModelCatalogOwnerSnapshot = (params: {
  agentId?: string;
  agentDir?: string;
  config: GatewayModelCatalogConfig;
  readOnly?: boolean;
  workspaceDir?: string;
}) => Promise<PublishedModelCatalogOwnerCandidate>;
type LoadGatewayModelCatalogParams = {
  agentId?: string;
  agentDir?: string;
  getConfig?: () => GatewayModelCatalogConfig;
  loadPublishedPreparedModelCatalogOwnerSnapshot?: LoadPublishedPreparedModelCatalogOwnerSnapshot;
  readOnly?: boolean;
  workspaceDir?: string;
};

const modelCatalogCache = new ModelCatalogCache<GatewayModelCatalogSnapshot>({
  freshForMs: 10 * 60 * 1000,
});
const configIds = new WeakMap<object, number>();
let nextConfigId = 1;

function resolveConfigId(config: GatewayModelCatalogConfig): number {
  const object = config as object;
  const existing = configIds.get(object);
  if (existing) return existing;
  const id = nextConfigId++;
  configIds.set(object, id);
  return id;
}

async function resolveLoader(
  params?: LoadGatewayModelCatalogParams,
): Promise<LoadPublishedPreparedModelCatalogOwnerSnapshot> {
  if (params?.loadPublishedPreparedModelCatalogOwnerSnapshot) {
    return params.loadPublishedPreparedModelCatalogOwnerSnapshot;
  }
  const { loadPublishedPreparedModelCatalogOwnerSnapshot } =
    await import("../agents/prepared-model-catalog.js");
  return loadPublishedPreparedModelCatalogOwnerSnapshot;
}

// Isolated gateway tests share process module state with lifecycle-owner tests.
export async function resetPreparedModelCatalogForTest(): Promise<void> {
  const [{ resetPreparedModelRuntimeSnapshotsForTest }, { resetModelCatalogBuilderCacheForTest }] =
    await Promise.all([
      import("../agents/prepared-model-runtime.test-support.js"),
      import("../agents/model-catalog.js"),
    ]);
  resetPreparedModelRuntimeSnapshotsForTest();
  resetModelCatalogBuilderCacheForTest();
  modelCatalogCache.clear();
}

async function loadGatewayModelCatalogOwnerSnapshot(
  params?: LoadGatewayModelCatalogParams,
): Promise<GatewayModelCatalogOwnerSnapshot> {
  const loadOwner = await resolveLoader(params);
  return resolvePublishedModelCatalogOwner(
    await loadOwner({
      ...(params?.agentId ? { agentId: params.agentId } : {}),
      ...(params?.agentDir ? { agentDir: params.agentDir } : {}),
      config: (params?.getConfig ?? getRuntimeConfig)(),
      readOnly: params?.readOnly !== false,
      ...(params?.workspaceDir ? { workspaceDir: params.workspaceDir } : {}),
    }),
  );
}

export async function loadGatewayModelCatalogSnapshot(
  params?: LoadGatewayModelCatalogParams,
): Promise<GatewayModelCatalogSnapshot> {
  if (!params?.getConfig && !params?.loadPublishedPreparedModelCatalogOwnerSnapshot) {
    const config = getRuntimeConfig();
    const readOnly = params?.readOnly !== false;
    const key = [
      resolveConfigId(config),
      params?.agentId ?? "",
      params?.agentDir ?? "",
      params?.workspaceDir ?? "",
      readOnly ? "read-only" : "full",
    ].join("\0");
    return modelCatalogCache.get(key, () =>
      loadGatewayModelCatalogSnapshotInWorker({
        ...(params?.agentId ? { agentId: params.agentId } : {}),
        ...(params?.agentDir ? { agentDir: params.agentDir } : {}),
        config,
        readOnly,
        ...(params?.workspaceDir ? { workspaceDir: params.workspaceDir } : {}),
      }),
    );
  }
  const owner = await loadGatewayModelCatalogOwnerSnapshot(params);
  return {
    ...owner.modelCatalog,
    agentId: owner.agentId,
    agentDir: owner.agentDir,
    workspaceDir: owner.workspaceDir,
    config: owner.config,
  };
}

export async function loadGatewayModelCatalog(
  params?: LoadGatewayModelCatalogParams,
): Promise<GatewayModelChoice[]> {
  return (await loadGatewayModelCatalogSnapshot(params)).entries;
}

/** Reads the already-published startup catalog without starting provider discovery. */
export async function readPreparedGatewayModelCatalog(
  params?: LoadGatewayModelCatalogParams,
): Promise<GatewayModelChoice[] | undefined> {
  const { getPreparedModelCatalogSnapshot } = await import("../agents/prepared-model-catalog.js");
  const config = (params?.getConfig ?? getRuntimeConfig)();
  return getPreparedModelCatalogSnapshot({
    ...(params?.agentId ? { agentId: params.agentId } : {}),
    ...(params?.agentDir ? { agentDir: params.agentDir } : {}),
    config,
    readOnly: true,
    ...(params?.workspaceDir ? { workspaceDir: params.workspaceDir } : {}),
  })?.entries;
}
