import { Subcommand } from "@jamun/shared/internal";

const allCaches: Array<Map<string, unknown>> = [];

class BoundedMap<T> extends Map<string, T> {
  override set(key: string, value: T) {
    if (!this.has(key) && this.size >= 256) this.delete(this.keys().next().value!);
    return super.set(key, value);
  }
}
export const createCache = <T>() => {
  const cache = new BoundedMap<T>();
  allCaches.push(cache);
  return cache;
};

export const resetCaches = () => {
  allCaches.forEach((cache) => {
    cache.clear();
  });
};

window.resetCaches = resetCaches;

export const specCache = createCache<Subcommand>();
export const generateSpecCache = createCache<Subcommand>();

window.listCache = () => {
  console.log(specCache);
  console.log(generateSpecCache);
};
