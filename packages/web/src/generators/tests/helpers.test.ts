import { Annotation } from "@jamun/autocomplete-parser";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  generatorCache,
  runCachedGenerator,
  haveContextForGenerator,
  GeneratorContext,
} from "../helpers";

const context: GeneratorContext = {
  annotations: [] as Annotation[],
  tokenArray: [] as string[],
  currentWorkingDirectory: "",
  currentProcess: "",
  sshPrefix: "",
  searchTerm: "",
  environmentVariables: {},
};

describe("haveContextForGenerator", () => {
  it("true with context", () => {
    expect(
      haveContextForGenerator({
        ...context,
        currentWorkingDirectory: "/",
        currentProcess: "zsh",
      }),
    ).toBe(true);
  });

  it("true with context in ssh", () => {
    expect(
      haveContextForGenerator({
        ...context,
        currentWorkingDirectory: "/",
        currentProcess: "ssh",
      }),
    ).toBe(true);
  });

  it("false when no current dir", () => {
    expect(
      haveContextForGenerator({
        ...context,
        currentWorkingDirectory: "",
      }),
    ).toBe(false);
  });
});

describe("runCachedGenerator", () => {
  beforeEach(() => { generatorCache.clear(); vi.useFakeTimers(); vi.setSystemTime(10000); });
  afterEach(() => vi.useRealTimers());
  it("does not cache without a policy", async () => {
    const run = vi.fn().mockResolvedValue("value");
    const generator = {};
    await runCachedGenerator(generator, context, run);
    await runCachedGenerator(generator, context, run);
    expect(run).toHaveBeenCalledTimes(2);
  });
  it("reuses a static script within one generator but isolates other generators and sessions", async () => {
    const run = vi.fn().mockResolvedValue("value");
    const generator: Fig.Generator = { cache: { strategy: "max-age", ttl: 1000 } };
    await runCachedGenerator(generator, context, run, "script");
    await runCachedGenerator(generator, { ...context, tokenArray: ["different"] }, run, "script");
    expect(run).toHaveBeenCalledTimes(1);
    await runCachedGenerator({ ...generator }, context, run, "script");
    await runCachedGenerator(generator, { ...context, sessionId: "B" }, run, "script");
    expect(run).toHaveBeenCalledTimes(3);
  });
  it.each([true, false])("respects cacheByDirectory=%s", async (cacheByDirectory) => {
    const run = vi.fn().mockResolvedValue("value");
    const generator: Fig.Generator = { cache: { strategy: "max-age", ttl: 1000, cacheByDirectory } };
    await runCachedGenerator(generator, context, run);
    await runCachedGenerator(generator, { ...context, currentWorkingDirectory: "/other" }, run);
    expect(run).toHaveBeenCalledTimes(cacheByDirectory ? 2 : 1);
  });
  it("waits for fresh data when max-age expires", async () => {
    const generator: Fig.Generator = { cache: { strategy: "max-age", ttl: 1000 } };
    expect(await runCachedGenerator(generator, context, async () => "old")).toBe("old");
    vi.advanceTimersByTime(1001);
    expect(await runCachedGenerator(generator, context, async () => "new")).toBe("new");
  });
  it.each([undefined, "stale-while-revalidate"] as const)("returns stale data during background refresh (%s)", async (strategy) => {
    const generator: Fig.Generator = { cache: { strategy, ttl: 1000 } };
    await runCachedGenerator(generator, context, async () => "old");
    vi.advanceTimersByTime(1001);
    let resolve!: (value: string) => void;
    const pending = new Promise<string>((done) => { resolve = done; });
    expect(await runCachedGenerator(generator, context, () => pending)).toBe("old");
    resolve("new");
    await vi.advanceTimersByTimeAsync(0);
    expect(await runCachedGenerator(generator, context, async () => "unexpected")).toBe("new");
  });
  it("recovers from rejection and deduplicates simultaneous callers", async () => {
    const generator: Fig.Generator = { cache: { strategy: "max-age", ttl: 1000 } };
    const failing = vi.fn().mockRejectedValue(new Error("temporary"));
    const results = await Promise.allSettled([
      runCachedGenerator(generator, context, failing), runCachedGenerator(generator, context, failing),
    ]);
    expect(results.map((result) => result.status)).toEqual(["rejected", "rejected"]);
    expect(failing).toHaveBeenCalledTimes(1);
    expect(await runCachedGenerator(generator, context, async () => "recovered")).toBe("recovered");
  });
});
