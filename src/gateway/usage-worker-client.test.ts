import { describe, expect, it } from "vitest";
import { resolveUsageWorkerUrl } from "./usage-worker-client.js";

describe("usage worker URL", () => {
  it("resolves the stable dist worker entry", () => {
    const url = resolveUsageWorkerUrl("file:///C:/openclaw/dist/chunk-ABC.js");
    expect(url.pathname).toBe("/C:/openclaw/dist/gateway/usage.worker.js");
  });

  it("resolves the TypeScript sibling during development", () => {
    const url = resolveUsageWorkerUrl("file:///C:/openclaw/src/gateway/usage-worker-client.ts");
    expect(url.pathname).toBe("/C:/openclaw/src/gateway/usage.worker.ts");
  });
});
