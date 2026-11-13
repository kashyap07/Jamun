import { defineConfig } from "vitest/config";

// Pure parsers run in Node; UI and bridge consumers run in jsdom.
export default defineConfig({
  test: {
    projects: [
      {
        test: {
          name: "node",
          environment: "node",
          include: ["packages/shell-parser/tests/**/*.test.ts", "packages/shared/tests/**/*.test.ts"],
        },
      },
      {
        test: {
          name: "browser",
          environment: "jsdom",
          include: [
            "packages/web/src/**/*.test.ts",
            "packages/autocomplete-parser/tests/**/*.test.ts",
            "packages/api-bindings/src/**/*.test.ts",
            "packages/api-bindings-wrappers/src/**/*.test.ts",
          ],
        },
      },
    ],
  },
});
