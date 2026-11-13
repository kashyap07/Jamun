class CacheEntry<T> {
  private lastFetch = 0;

  private promise: Promise<T> | undefined = undefined;

  value: T | undefined = undefined;

  private isInitialized = false;

  private get isFetching() {
    return !!this.promise;
  }

  private async fetchSync(run: () => Promise<T>) {
    const promise = Promise.resolve().then(run);
    this.promise = promise;
    try {
      this.value = await promise;
      this.lastFetch = Date.now();
      this.isInitialized = true;
      return this.value;
    } finally {
      if (this.promise === promise) this.promise = undefined;
    }
  }

  private async fetchAsync(run: () => Promise<T>): Promise<T | undefined> {
    if (this.isFetching) {
      await this.promise;
      return this.value;
    }
    return this.fetchSync(run);
  }

  private async maxAgeCache(run: () => Promise<T>, maxAge: number) {
    if (Date.now() >= (maxAge ?? 0) + this.lastFetch) {
      return this.fetchAsync(run);
    }
    return this.value;
  }

  private async swrCache(run: () => Promise<T>, maxAge = 0) {
    if (!this.isFetching && Date.now() > this.lastFetch + maxAge) {
      void this.fetchAsync(run).catch(() => { /* Keep stale success and retry on the next request. */ });
    }
    return this.value as T;
  }

  async entry(run: () => Promise<T>, cache: Fig.Cache): Promise<T | undefined> {
    if (!this.isInitialized) return this.fetchAsync(run);
    switch (cache.strategy || "stale-while-revalidate") {
      case "max-age":
        return this.maxAgeCache(run, cache.ttl!);
      case "stale-while-revalidate":
        // cache.ttl must be defined when no strategy is specified
        return this.swrCache(run, cache.ttl!);
      default:
        return this.fetchAsync(run);
    }
  }
}

export class Cache {
  private cache = new Map<string, CacheEntry<unknown>>();

  async entry<T>(
    key: string,
    run: () => Promise<T>,
    cache: Fig.Cache,
  ): Promise<T> {
    if (!this.cache.has(key)) {
      if (this.cache.size >= 256) this.cache.delete(this.cache.keys().next().value!);
      this.cache.set(key, new CacheEntry());
    }
    return this.cache.get(key)!.entry(run, cache) as Promise<T>;
  }

  currentValue<T>(key: string, _cache: Fig.Cache): T | undefined {
    if (!this.cache.has(key)) {
      if (this.cache.size >= 256) this.cache.delete(this.cache.keys().next().value!);
      this.cache.set(key, new CacheEntry());
    }
    return this.cache.get(key)!.value as T | undefined;
  }

  clear() {
    this.cache.clear();
  }
}
