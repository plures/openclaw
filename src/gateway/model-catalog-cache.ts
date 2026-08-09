export type ModelCatalogCacheOptions = {
  freshForMs: number;
  now?: () => number;
};

type CacheEntry<T> = {
  value?: T;
  refreshedAt: number;
  refresh?: Promise<T>;
};

/** Process-local stale-while-refresh cache with one refresh per key. */
export class ModelCatalogCache<T> {
  private readonly entries = new Map<string, CacheEntry<T>>();
  private readonly freshForMs: number;
  private readonly now: () => number;

  constructor(options: ModelCatalogCacheOptions) {
    this.freshForMs = options.freshForMs;
    this.now = options.now ?? Date.now;
  }

  get(key: string, refresh: () => Promise<T>): Promise<T> {
    const entry = this.entries.get(key) ?? { refreshedAt: 0 };
    this.entries.set(key, entry);

    if (entry.value !== undefined && this.now() - entry.refreshedAt < this.freshForMs) {
      return Promise.resolve(entry.value);
    }

    if (!entry.refresh) {
      const pending = refresh()
        .then((value) => {
          entry.value = value;
          entry.refreshedAt = this.now();
          return value;
        })
        .finally(() => {
          if (entry.refresh === pending) {
            entry.refresh = undefined;
          }
        });
      entry.refresh = pending;
    }

    if (entry.value !== undefined) {
      entry.refresh.catch(() => undefined);
      return Promise.resolve(entry.value);
    }
    return entry.refresh;
  }

  clear(): void {
    this.entries.clear();
  }
}
