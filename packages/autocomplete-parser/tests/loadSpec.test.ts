import logger from "loglevel";
import {
  SETTINGS,
  updateSettings,
} from "@jamun/api-bindings-wrappers";
import { SpecLocationSource } from "@jamun/shared/utils";
import {
  getSpecPath,
  loadFigSubcommand,
  loadSubcommandCached,
} from "../src/loadSpec";
import * as loadHelpers from "../src/loadHelpers";
import {
  expect,
  it,
  beforeAll,
  describe,
  beforeEach,
  vi,
  Mock,
  afterEach,
} from "vitest";

const { importSpecFromFile } = loadHelpers;

vi.mock("../src/loadHelpers", () => ({
  importSpecFromFile: vi
    .fn()
    .mockResolvedValue({ default: { name: "loadFromFile" } }),
  getPrivateSpec: vi.fn().mockReturnValue(undefined),
  isDiffVersionedSpec: vi.fn(),
}));

vi.mock("@jamun/api-bindings-wrappers", async () => ({
  ...(await vi.importActual(
    "@jamun/api-bindings-wrappers",
  )),
  executeCommand: vi.fn(),
}));

// TODO: remove this statement and move fig dir to shared
const FIG_DIR = "~/.fig";

beforeAll(() => {
  updateSettings({});
});

describe("getSpecPath", () => {
  const cwd = "test_cwd";

  it("works", async () => {
    expect(await getSpecPath("git", cwd)).toEqual({
      type: SpecLocationSource.GLOBAL,
      name: "git",
    });
  });

  it("works for specs containing a slash in the name", async () => {
    expect(
      await getSpecPath("@withfig/autocomplete-tools", cwd, false),
    ).toEqual({
      type: SpecLocationSource.GLOBAL,
      name: "@withfig/autocomplete-tools",
    });
  });

  it("works for scripts containing a slash in the name", async () => {
    expect(await getSpecPath("@withfig/autocomplete-tools", cwd)).toEqual({
      type: SpecLocationSource.LOCAL,
      name: "autocomplete-tools",
      path: `${cwd}/@withfig/`,
    });
  });

  it("works properly with local commands", async () => {
    expect(await getSpecPath("./test", cwd)).toEqual({
      type: SpecLocationSource.LOCAL,
      name: "test",
      path: `${cwd}/`,
    });
    expect(await getSpecPath("~/test", cwd)).toEqual({
      type: SpecLocationSource.LOCAL,
      path: `~/`,
      name: "test",
    });
    expect(await getSpecPath("/test", cwd)).toEqual({
      type: SpecLocationSource.LOCAL,
      path: `/`,
      name: "test",
    });
    expect(await getSpecPath("/dir/test", cwd)).toEqual({
      type: SpecLocationSource.LOCAL,
      path: `/dir/`,
      name: "test",
    });
    expect(await getSpecPath("~/dir/test", cwd)).toEqual({
      type: SpecLocationSource.LOCAL,
      path: `~/dir/`,
      name: "test",
    });
    expect(await getSpecPath("./dir/test", cwd)).toEqual({
      type: SpecLocationSource.LOCAL,
      path: `${cwd}/dir/`,
      name: "test",
    });
  });

  it("works properly with ? commands", async () => {
    expect(await getSpecPath("?", cwd)).toEqual({
      type: SpecLocationSource.LOCAL,
      path: `${cwd}/`,
      name: "_shortcuts",
    });
  });

  it("works properly with + commands", async () => {
    expect(await getSpecPath("+", cwd)).toEqual({
      type: SpecLocationSource.LOCAL,
      name: "+",
      path: "~/",
    });
  });
});

describe("loadFigSubcommand", () => {
  window.URL.createObjectURL = vi.fn();

  beforeEach(() => {
    (loadHelpers.isDiffVersionedSpec as Mock).mockResolvedValue(false);
    updateSettings({});
  });

  afterEach(() => {
    (loadHelpers.isDiffVersionedSpec as Mock).mockClear();
  });

  it("rejects project-local specs without attempting to import code", async () => {
    vi.mocked(importSpecFromFile).mockClear();
    await expect(loadFigSubcommand({ name: "path", type: SpecLocationSource.LOCAL }))
      .rejects.toThrow("Project-local completion code is disabled");
    expect(importSpecFromFile).not.toHaveBeenCalled();
  });

  it("loads a developer spec through the native trust-gated reader", async () => {
    const devPath = "~/some-folder/";
    updateSettings({ [SETTINGS.DEV_COMPLETIONS_FOLDER]: devPath, [SETTINGS.DEV_MODE]: true });
    const result = await loadFigSubcommand({ name: "git", type: SpecLocationSource.LOCAL });
    expect(importSpecFromFile).toHaveBeenLastCalledWith("git", devPath, logger);
    expect(result.name).toBe("loadFromFile");
  });

  it("does not fall back to project code when the developer reader denies access", async () => {
    updateSettings({ [SETTINGS.DEV_COMPLETIONS_FOLDER]: "~/untrusted", [SETTINGS.DEV_MODE]: true });
    vi.mocked(importSpecFromFile).mockRejectedValueOnce(new Error("local_spec_not_trusted"));
    await expect(loadFigSubcommand({ name: "tool", type: SpecLocationSource.LOCAL }))
      .rejects.toThrow("Project-local completion code is disabled");
  });

});

describe("loadSubcommandCached", () => {
  it.todo("deduplicates subcommand loading across matching contexts");
});
