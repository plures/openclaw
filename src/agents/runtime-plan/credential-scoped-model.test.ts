import { describe, expect, it, vi } from "vitest";
import { createPreparedRuntimeModelMaterializer } from "./credential-scoped-model.js";
import type { AgentRuntimeAuthPlan } from "./types.js";

const model = {
  provider: "openai",
  id: "gpt-5.5",
  api: "openai-chatgpt-responses",
  baseUrl: "https://chatgpt.com/backend-api/codex",
};

function createPlan(profileId: string): AgentRuntimeAuthPlan {
  return {
    providerForAuth: "openai",
    authProfileProviderForAuth: "openai",
    forwardedAuthProfileId: profileId,
    selectedAuthMode: "token",
    modelRoute: {
      provider: "openai",
      modelId: "gpt-5.5",
      api: "openai-chatgpt-responses",
      baseUrl: "https://chatgpt.com/backend-api/codex",
      authRequirement: "subscription",
      requestTransportOverrides: "none",
    },
  };
}

describe("createPreparedRuntimeModelMaterializer", () => {
  it("reuses metadata already resolved for the selected auth profile", async () => {
    const resolveModel = vi.fn();
    const materializer = createPreparedRuntimeModelMaterializer({
      provider: "openai",
      modelId: "gpt-5.5",
      getModel: () => model,
      nativeModelOwned: false,
      requestedProfileId: "openai:subscription",
      initialModelAuthProfileId: "openai:subscription",
      providerUsesProfileScopedModelMetadata: true,
      resolveModel,
    });

    await expect(materializer.materialize(createPlan("openai:subscription"))).resolves.toBe(model);
    expect(resolveModel).not.toHaveBeenCalled();
  });

  it("re-resolves metadata when auth preparation selects another profile", async () => {
    const replacement = { ...model, name: "backup profile" };
    const resolveModel = vi.fn(async () => ({ model: replacement }));
    const materializer = createPreparedRuntimeModelMaterializer({
      provider: "openai",
      modelId: "gpt-5.5",
      getModel: () => model,
      nativeModelOwned: false,
      requestedProfileId: "openai:subscription",
      initialModelAuthProfileId: "openai:subscription",
      providerUsesProfileScopedModelMetadata: true,
      resolveModel,
    });

    await expect(materializer.materialize(createPlan("openai:backup"))).resolves.toBe(replacement);
    expect(resolveModel).toHaveBeenCalledWith(
      expect.objectContaining({ authProfileId: "openai:backup" }),
    );
  });
});
