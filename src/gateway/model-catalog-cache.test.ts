import { describe, expect, it, vi } from "vitest";
import { ModelCatalogCache } from "./model-catalog-cache.js";

describe("ModelCatalogCache", () => {
  it("coalesces cold misses and reuses fresh values", async () => {
    let complete!: (value: string) => void;
    const refresh = vi.fn(() => new Promise<string>((resolve) => (complete = resolve)));
    const cache = new ModelCatalogCache<string>({ freshForMs: 1000 });
    const first = cache.get("main", refresh);
    const second = cache.get("main", refresh);
    expect(refresh).toHaveBeenCalledTimes(1);
    complete("one");
    await expect(Promise.all([first, second])).resolves.toEqual(["one", "one"]);
    await expect(cache.get("main", refresh)).resolves.toBe("one");
  });

  it("returns stale while a single refresh replaces it", async () => {
    let now = 0;
    let complete!: (value: string) => void;
    const refresh = vi
      .fn<() => Promise<string>>()
      .mockResolvedValueOnce("one")
      .mockImplementationOnce(() => new Promise<string>((resolve) => (complete = resolve)));
    const cache = new ModelCatalogCache<string>({ freshForMs: 10, now: () => now });
    await cache.get("main", refresh);
    now = 11;
    await expect(cache.get("main", refresh)).resolves.toBe("one");
    await expect(cache.get("main", refresh)).resolves.toBe("one");
    expect(refresh).toHaveBeenCalledTimes(2);
    complete("two");
    await vi.waitFor(async () => expect(await cache.get("main", refresh)).toBe("two"));
  });

  it("retains the last good value after a failed stale refresh", async () => {
    let now = 0;
    const refresh = vi
      .fn<() => Promise<string>>()
      .mockResolvedValueOnce("one")
      .mockRejectedValue(new Error("failed"));
    const cache = new ModelCatalogCache<string>({ freshForMs: 10, now: () => now });
    await cache.get("main", refresh);
    now = 11;
    await expect(cache.get("main", refresh)).resolves.toBe("one");
    await vi.waitFor(() => expect(refresh).toHaveBeenCalledTimes(2));
    await expect(cache.get("main", refresh)).resolves.toBe("one");
  });
});
