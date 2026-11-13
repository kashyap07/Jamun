import logger, { Logger } from "loglevel";
import * as semver from "semver";
import {
  ensureTrailingSlash,
  withTimeout,
  exponentialBackoff,
} from "@jamun/shared/utils";
import {
  executeCommand,
  isInDevMode,
} from "@jamun/api-bindings-wrappers";
import { fs as FileSystem } from "@jamun/api-bindings";
import { MOST_USED_SPECS } from "./constants.js";
import { LoadLocalSpecError, SpecCDNError } from "./errors.js";

export type SpecFileImport =
  | {
      default: Fig.Spec;
      getVersionCommand?: Fig.GetVersionCommand;
    }
  | {
      default: Fig.Subcommand;
      versions: Fig.VersionDiffMap;
    };

const makeCdnUrlFactory =
  (baseUrl: string) =>
  (specName: string, ext: string = "js") =>
    `${baseUrl}${specName}.${ext}`;

const cdnUrlFactory = makeCdnUrlFactory(
  "https://specs.q.us-east-1.amazonaws.com/",
);

const stringImportCache = new Map<string, SpecFileImport>();

export const importString = async (str: string) => {
  if (stringImportCache.has(str)) {
    return stringImportCache.get(str)!;
  }
  if (str.length > 2_000_000) throw new LoadLocalSpecError("Spec exceeds the size limit");
  const url = URL.createObjectURL(new Blob([str], { type: "text/javascript" }));
  try {
    const result = await import(/* @vite-ignore */ url);
    if (stringImportCache.size >= 128) stringImportCache.delete(stringImportCache.keys().next().value!);
    stringImportCache.set(str, result);
    return result;
  } finally { URL.revokeObjectURL(url); }
};

/*
 * Deprecated: eventually will just use importLocalSpec above
 * Load a spec import("{path}/{name}")
 */
export async function importSpecFromFile(
  name: string,
  path: string,
  localLogger: Logger = logger,
): Promise<SpecFileImport> {
  const importFromPath = async (fullPath: string) => {
    localLogger.info(`Loading spec from ${fullPath}`);
    const contents = await FileSystem.readSpec(fullPath);
    if (!contents) {
      throw new LoadLocalSpecError(`Failed to read file: ${fullPath}`);
    }
    return contents;
  };

  let result: string;
  const joinedPath = `${ensureTrailingSlash(path)}${name}`;
  try {
    result = await importFromPath(`${joinedPath}.js`);
  } catch (_) {
    result = await importFromPath(`${joinedPath}/index.js`);
  }

  return importString(result);
}

/**
 * Specs can only be loaded from non "secure" contexts, so we can't load from https
 */
export const canLoadSpecProtocol = () => window.location.protocol !== "https:";

// TODO: this is a problem for diff-versioned specs
export async function importFromPublicCDN<T = SpecFileImport>(
  name: string,
): Promise<T> {
  if (canLoadSpecProtocol()) {
    return withTimeout(
      20000,
      import(
        /* @vite-ignore */
        `spec://localhost/${name}.js`
      ),
    );
  }

  // Total of retries in the worst case should be close to previous timeout value
  // 500ms * 2^5 + 5 * 1000ms + 5 * 100ms = 21500ms, before the timeout was 20000ms
  try {
    return await exponentialBackoff(
      {
        attemptTimeout: 1000,
        baseDelay: 500,
        maxRetries: 5,
        jitter: 100,
      },

      () => import(/* @vite-ignore */ cdnUrlFactory(name)),
    );
  } catch {
    /**/
  }

  throw new SpecCDNError("Unable to load from a CDN");
}

async function jsonFromPublicCDN(path: string): Promise<unknown> {
  if (canLoadSpecProtocol()) {
    return fetch(`spec://localhost/${path}.json`).then(async (res) => {
      if (!res.ok) throw new Error("Spec index unavailable");
      const reader = res.body?.getReader();
      if (!reader) throw new Error("Spec index stream unavailable");
      const chunks: Uint8Array[] = []; let size = 0;
      try {
        while (true) { const next = await reader.read(); if (next.done) break; size += next.value.length; if (size > 2_000_000) throw new Error("Spec index too large"); chunks.push(next.value); }
      } finally { await reader.cancel(); }
      const bytes = new Uint8Array(size); let offset = 0;
      for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
      return JSON.parse(new TextDecoder().decode(bytes));
    });
  }

  return exponentialBackoff(
    {
      attemptTimeout: 1000,
      baseDelay: 500,
      maxRetries: 5,
      jitter: 100,
    },
    () => fetch(cdnUrlFactory(path, "json")).then(async (res) => {
      if (!res.ok) throw new Error("Spec index unavailable");
      const reader = res.body?.getReader();
      if (!reader) throw new Error("Spec index stream unavailable");
      const chunks: Uint8Array[] = []; let size = 0;
      try {
        while (true) { const next = await reader.read(); if (next.done) break; size += next.value.length; if (size > 2_000_000) throw new Error("Spec index too large"); chunks.push(next.value); }
      } finally { await reader.cancel(); }
      const bytes = new Uint8Array(size); let offset = 0;
      for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
      return JSON.parse(new TextDecoder().decode(bytes));
    }),
  );
}

// TODO: this is a problem for diff-versioned specs
export async function importFromLocalhost<T = SpecFileImport>(
  name: string,
  port: number | string,
): Promise<T> {
  void name; void port;
  throw new LoadLocalSpecError("HTTP developer specs are disabled; select a trusted local directory");
}

const cachedCLIVersions = new Map<string, string | undefined>();
const cacheCLIVersion = (key: string, value: string | undefined) => {
  if (cachedCLIVersions.size >= 256) cachedCLIVersions.delete(cachedCLIVersions.keys().next().value!);
  cachedCLIVersions.set(key, value);
};

export const getCachedCLIVersion = (key: string) =>
  cachedCLIVersions.get(key) ?? null;

export async function getVersionFromFullFile(
  specData: SpecFileImport,
  name: string,
) {
  // if the default export is a function it is a versioned spec
  if (typeof specData.default === "function") {
    try {
      const storageKey = `cliVersion-${name}`;
      const version = getCachedCLIVersion(storageKey);
      if (!isInDevMode() && version !== null) {
        return version;
      }

      if ("getVersionCommand" in specData && specData.getVersionCommand) {
        const newVersion = await specData.getVersionCommand(executeCommand);
        cacheCLIVersion(storageKey, newVersion);
        return newVersion;
      }

      const newVersion = semver.clean(
        (
          await executeCommand({
            command: name,
            args: ["--version"],
          })
        ).stdout,
      );
      if (newVersion) {
        cacheCLIVersion(storageKey, newVersion);
        return newVersion;
      }
    } catch {
      /**/
    }
  }
  return undefined;
}

// TODO: cache this request using SWR strategy
let publicSpecsRequest:
  | Promise<{
      completions: Set<string>;
      diffVersionedSpecs: Set<string>;
    }>
  | undefined;

export function clearSpecIndex() {
  publicSpecsRequest = undefined;
}

const parseSpecIndex = (value: unknown): { completions: string[]; diffVersionedCompletions: string[] } => {
  if (!value || typeof value !== "object") throw new Error("Invalid spec index");
  const index = value as Record<string, unknown>;
  for (const key of ["completions", "diffVersionedCompletions"]) {
    const values = index[key];
    if (!Array.isArray(values) || values.length > 20000 || values.some((v) => typeof v !== "string" || v.length > 256 || !/^[a-zA-Z0-9_@+./-]+$/.test(v) || v.includes(".."))) {
      throw new Error("Invalid or oversized spec index");
    }
  }
  return index as { completions: string[]; diffVersionedCompletions: string[] };
};

const createPublicSpecsRequest = async () => {
  if (publicSpecsRequest === undefined) {
    publicSpecsRequest = jsonFromPublicCDN("index")
      .then(parseSpecIndex)
      .then((index) => ({
        completions: new Set(index.completions),
        diffVersionedSpecs: new Set(index.diffVersionedCompletions),
      }))
      .catch(() => {
        publicSpecsRequest = undefined;
        return { completions: new Set(), diffVersionedSpecs: new Set() };
      });
  }
  return publicSpecsRequest;
};

export async function publicSpecExists(name: string): Promise<boolean> {
  const { completions } = await createPublicSpecsRequest();
  return completions.has(name);
}

export async function isDiffVersionedSpec(name: string): Promise<boolean> {
  const { diffVersionedSpecs } = await createPublicSpecsRequest();
  return diffVersionedSpecs.has(name);
}

export async function preloadSpecs(): Promise<SpecFileImport[]> {
  return Promise.all(
    MOST_USED_SPECS.map(async (name) => {
      // TODO: refactor everything to allow the correct diff-versioned specs to be loaded
      // too, now we are only loading the index
      if (await isDiffVersionedSpec(name)) {
        return importFromPublicCDN(`${name}/index`);
      }
      return importFromPublicCDN(name);
    }).map((promise) => promise.catch((e) => e)),
  );
}
