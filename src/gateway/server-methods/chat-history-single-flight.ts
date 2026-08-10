import type { RespondFn } from "./types.js";

export type GatewayResponseArgs = Parameters<RespondFn>;

type ChatHistoryAdmissionState = {
  active: number;
  inFlight: Map<string, Promise<GatewayResponseArgs>>;
  queued: Array<() => void>;
};

/**
 * Coalesces identical read-only history projections within one Gateway context.
 * Entries exist only while work is running; completed responses are never cached.
 */
export class ChatHistorySingleFlight {
  readonly #maxConcurrentPerContext: number;
  readonly #maxEntriesPerContext: number;
  readonly #stateByContext = new WeakMap<object, ChatHistoryAdmissionState>();

  constructor(options?: { maxConcurrentPerContext?: number; maxEntriesPerContext?: number }) {
    this.#maxConcurrentPerContext = options?.maxConcurrentPerContext ?? 2;
    this.#maxEntriesPerContext = options?.maxEntriesPerContext ?? 128;
  }

  #getState(context: object): ChatHistoryAdmissionState {
    let state = this.#stateByContext.get(context);
    if (!state) {
      state = { active: 0, inFlight: new Map(), queued: [] };
      this.#stateByContext.set(context, state);
    }
    return state;
  }

  #enqueue(
    state: ChatHistoryAdmissionState,
    build: () => Promise<GatewayResponseArgs>,
  ): Promise<GatewayResponseArgs> {
    return new Promise<GatewayResponseArgs>((resolve, reject) => {
      const start = () => {
        state.active += 1;
        void Promise.resolve()
          .then(build)
          .then(resolve, reject)
          .finally(() => {
            state.active -= 1;
            this.#drain(state);
          });
      };
      state.queued.push(start);
      this.#drain(state);
    });
  }

  #drain(state: ChatHistoryAdmissionState): void {
    while (state.active < this.#maxConcurrentPerContext) {
      const start = state.queued.shift();
      if (!start) {
        return;
      }
      state.active += 1;
      setImmediate(() => {
        state.active -= 1;
        start();
      });
    }
  }

  run(
    context: object,
    key: string,
    build: () => Promise<GatewayResponseArgs>,
  ): Promise<GatewayResponseArgs> {
    const state = this.#getState(context);
    const existing = state.inFlight.get(key);
    if (existing) {
      return existing;
    }
    // Do not let arbitrary distinct request keys grow process-local bookkeeping
    // without bound. Overflow requests retain the original independent behavior.
    if (state.inFlight.size >= this.#maxEntriesPerContext) {
      return this.#enqueue(state, build);
    }
    const operation = this.#enqueue(state, build);
    state.inFlight.set(key, operation);
    const release = () => {
      if (state.inFlight.get(key) === operation) {
        state.inFlight.delete(key);
      }
    };
    void operation.then(release, release);
    return operation;
  }
}
