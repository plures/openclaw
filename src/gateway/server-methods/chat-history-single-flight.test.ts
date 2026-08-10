import { describe, expect, test, vi } from "vitest";
import { ChatHistorySingleFlight, type GatewayResponseArgs } from "./chat-history-single-flight.js";

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((resolvePromise) => {
    resolve = resolvePromise;
  });
  return { promise, resolve };
}

describe("ChatHistorySingleFlight", () => {
  test("shares identical in-flight work within one Gateway context", async () => {
    const singleFlight = new ChatHistorySingleFlight();
    const context = {};
    const pending = deferred<GatewayResponseArgs>();
    const build = vi.fn(() => pending.promise);

    const first = singleFlight.run(context, "same", build);
    const second = singleFlight.run(context, "same", build);
    pending.resolve([true, { messages: ["shared"] }]);

    await expect(Promise.all([first, second])).resolves.toEqual([
      [true, { messages: ["shared"] }],
      [true, { messages: ["shared"] }],
    ]);
    expect(build).toHaveBeenCalledTimes(1);
  });

  test("does not retain completed responses", async () => {
    const singleFlight = new ChatHistorySingleFlight();
    const context = {};
    const build = vi.fn(async (): Promise<GatewayResponseArgs> => [true, { messages: [] }]);

    await singleFlight.run(context, "same", build);
    await singleFlight.run(context, "same", build);

    expect(build).toHaveBeenCalledTimes(2);
  });

  test("evicts failed work so a retry can rebuild", async () => {
    const singleFlight = new ChatHistorySingleFlight();
    const context = {};
    const build = vi
      .fn<() => Promise<GatewayResponseArgs>>()
      .mockRejectedValueOnce(new Error("projection failed"))
      .mockResolvedValueOnce([true, { messages: [] }]);

    await expect(singleFlight.run(context, "same", build)).rejects.toThrow("projection failed");
    await expect(singleFlight.run(context, "same", build)).resolves.toEqual([
      true,
      { messages: [] },
    ]);
    expect(build).toHaveBeenCalledTimes(2);
  });

  test("bounds distinct cold history work per Gateway context", async () => {
    const singleFlight = new ChatHistorySingleFlight({ maxConcurrentPerContext: 2 });
    const context = {};
    const pending = [
      deferred<GatewayResponseArgs>(),
      deferred<GatewayResponseArgs>(),
      deferred<GatewayResponseArgs>(),
    ];
    let active = 0;
    let maxActive = 0;
    const runs = pending.map((item, index) =>
      singleFlight.run(context, `history-${index}`, async () => {
        active += 1;
        maxActive = Math.max(maxActive, active);
        const result = await item.promise;
        active -= 1;
        return result;
      }),
    );

    await vi.waitFor(() => expect(active).toBe(2));
    expect(maxActive).toBe(2);
    pending[0]?.resolve([true, { messages: [] }]);
    await vi.waitFor(() => expect(active).toBe(2));
    pending[1]?.resolve([true, { messages: [] }]);
    pending[2]?.resolve([true, { messages: [] }]);
    await Promise.all(runs);
    expect(maxActive).toBe(2);
  });

  test("keeps overflow work behind the same admission bound", async () => {
    const singleFlight = new ChatHistorySingleFlight({
      maxConcurrentPerContext: 1,
      maxEntriesPerContext: 1,
    });
    const context = {};
    const pending = deferred<GatewayResponseArgs>();
    const overflow = vi.fn(async (): Promise<GatewayResponseArgs> => [true, { overflow: true }]);

    const first = singleFlight.run(context, "first", () => pending.promise);
    const second = singleFlight.run(context, "second", overflow);
    await new Promise<void>((resolve) => {
      setImmediate(resolve);
    });
    expect(overflow).not.toHaveBeenCalled();
    pending.resolve([true, { messages: [] }]);
    await first;
    await expect(second).resolves.toEqual([true, { overflow: true }]);
    expect(overflow).toHaveBeenCalledTimes(1);
  });
});
