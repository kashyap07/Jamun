import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { beforeEach, expect, it, vi } from "vitest";
import { updateSettings } from "@jamun/api-bindings-wrappers";
import { useAutocompleteStore } from "../state";
import { initialFigState } from "../fig/hooks";
import { Visibility } from "../state/types";
import { useAutocompleteKeypressCallback } from "./keypress";

let callback: ReturnType<typeof useAutocompleteKeypressCallback>;
function Harness() { callback = useAutocompleteKeypressCallback(vi.fn(), vi.fn(), vi.fn()); return null; }
beforeEach(() => {
  (globalThis as Record<string, unknown>).IS_REACT_ACT_ENVIRONMENT = true;
  updateSettings({});
  useAutocompleteStore.setState({
    figState: { ...initialFigState, buffer: "git ", cwd: "/tmp", shellContext: { sessionId: "A", revision: 1 } },
    suggestions: [{ name: "add" }, { name: "branch" }, { name: "commit" }], selectedIndex: 0,
    visibleState: Visibility.VISIBLE, hasChangedIndex: false, settings: { "autocomplete.scrollWrapAround": true },
  });
});
it("handles consecutive arrows before React renders and keeps the popup open", async () => {
  const container = document.createElement("div"); const root = createRoot(container);
  await act(async () => root.render(React.createElement(Harness)));
  const key = (action: string) => callback({ action, context: { sessionId: "A", revision: 1 } });
  key("navigateDown"); key("navigateDown");
  expect(useAutocompleteStore.getState().selectedIndex).toBe(2);
  expect(useAutocompleteStore.getState().visibleState).toBe(Visibility.VISIBLE);
  key("navigateDown"); expect(useAutocompleteStore.getState().selectedIndex).toBe(0);
  key("navigateUp"); expect(useAutocompleteStore.getState().selectedIndex).toBe(2);
  callback({ action: "navigateDown", context: { sessionId: "B", revision: 1 } });
  expect(useAutocompleteStore.getState().selectedIndex).toBe(2);
  callback({ action: "navigateDown", context: { sessionId: "A", revision: 0 } });
  expect(useAutocompleteStore.getState().selectedIndex).toBe(2);
  await act(async () => root.unmount());
});
