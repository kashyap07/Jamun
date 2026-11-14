import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { beforeEach, expect, it, vi } from "vitest";
import { updateSettings } from "@jamun/api-bindings-wrappers";
import { Keybindings, Shell } from "@jamun/api-bindings";
import { useShellHistory } from "../shellHistory";
import { useAutocompleteStore } from "../state";
import { initialFigState } from "../fig/hooks";
import { Visibility } from "../state/types";
import { useAutocompleteKeypressCallback } from "./keypress";

let callback: ReturnType<typeof useAutocompleteKeypressCallback>;
function Harness() { callback = useAutocompleteKeypressCallback(vi.fn(), vi.fn(), vi.fn()); return null; }
beforeEach(() => {
  (globalThis as Record<string, unknown>).IS_REACT_ACT_ENVIRONMENT = true;
  updateSettings({});
  useShellHistory.setState({ available: undefined, source: undefined, active: false, loaded: false, entries: [], selectedIndex: 0 });
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
it("hands Up to the shell when the popup has not been navigated", async () => {
  const container = document.createElement("div"); const root = createRoot(container);
  await act(async () => root.render(React.createElement(Harness)));
  const passThrough = vi.spyOn(Keybindings, "passThroughKey").mockImplementation(() => {});
  const key = (action: string) => callback({ action, context: { sessionId: "A", revision: 1 } });
  key("navigateUp");
  expect(passThrough).toHaveBeenCalledTimes(1);
  expect(useAutocompleteStore.getState().visibleState).toBe(Visibility.HIDDEN_UNTIL_KEYPRESS);
  expect(useAutocompleteStore.getState().selectedIndex).toBe(0);
  // Once the user is in the list, Up navigates and wraps instead.
  useAutocompleteStore.setState({ visibleState: Visibility.VISIBLE });
  key("navigateDown"); key("navigateUp"); key("navigateUp");
  expect(passThrough).toHaveBeenCalledTimes(1);
  expect(useAutocompleteStore.getState().selectedIndex).toBe(2);
  expect(useAutocompleteStore.getState().visibleState).toBe(Visibility.VISIBLE);
  passThrough.mockRestore();
  await act(async () => root.unmount());
});
it("opens shell history on Up past the top, then runs or edits like atuin", async () => {
  const container = document.createElement("div"); const root = createRoot(container);
  await act(async () => root.render(React.createElement(Harness)));
  const passThrough = vi.spyOn(Keybindings, "passThroughKey").mockImplementation(() => {});
  const insert = vi.spyOn(Shell, "insert").mockResolvedValue({ accepted: true });
  const context = { sessionId: "A", revision: 1, capabilities: ["replace"] };
  useAutocompleteStore.setState({
    figState: { ...initialFigState, buffer: "git ", cursorLocation: 4, cwd: "/tmp", shellContext: context },
  });
  const key = (action: string) => callback({ action, context });
  const history = () => useShellHistory.getState();
  useShellHistory.setState({ available: true });
  key("navigateUp");
  expect(history().active).toBe(true);
  history().close();
  // A shell script without whole-line replace keeps the old behavior.
  useAutocompleteStore.setState({
    figState: { ...useAutocompleteStore.getState().figState, shellContext: { sessionId: "A", revision: 1 } },
  });
  key("openShellHistory");
  expect(history().active).toBe(false);
  expect(passThrough).toHaveBeenCalledTimes(1);
  useAutocompleteStore.setState({
    figState: { ...useAutocompleteStore.getState().figState, shellContext: context },
  });

  // Up on the top row opens history instead of wrapping, even after navigating.
  key("navigateDown"); key("navigateUp"); key("navigateUp");
  expect(history().active).toBe(true);
  expect(useAutocompleteStore.getState().selectedIndex).toBe(0);
  history().setEntries([{ when: "2d", command: "git log" }, { when: "1h", command: "git status" }, { when: "5m", command: "git push" }]);
  expect(history().selectedIndex).toBe(2);
  key("shellHistoryOlder"); key("shellHistoryOlder"); key("shellHistoryOlder");
  expect(history().selectedIndex).toBe(0);
  key("shellHistoryNewer");
  key("shellHistoryRun");
  expect(insert).toHaveBeenLastCalledWith(expect.objectContaining({
    insertion: "git status", immediate: true, replaceBuffer: true, deletion: 0, expectedBuffer: "git ", expectedCursor: 4,
  }));
  expect(history().active).toBe(false);

  // With no popup, Up opens it too. Tab edits, Down past the newest closes.
  key("openShellHistory");
  history().setEntries([{ when: "5m", command: "git push" }]);
  key("shellHistoryEdit");
  expect(insert).toHaveBeenLastCalledWith(expect.objectContaining({ insertion: "git push", immediate: false, replaceBuffer: true }));
  key("openShellHistory");
  history().setEntries([{ when: "5m", command: "git push" }]);
  key("shellHistoryNewer");
  expect(history().active).toBe(false);
  // No match: Enter runs what is typed.
  key("openShellHistory");
  history().setEntries([]);
  key("shellHistoryRun");
  expect(passThrough).toHaveBeenCalledTimes(2);
  expect(insert).toHaveBeenCalledTimes(2);
  // A multi-line buffer keeps Up for moving between lines.
  useAutocompleteStore.setState({
    figState: { ...useAutocompleteStore.getState().figState, buffer: "for x in a\n", shellContext: context },
  });
  key("openShellHistory");
  expect(history().active).toBe(false);
  expect(passThrough).toHaveBeenCalledTimes(3);
  passThrough.mockRestore(); insert.mockRestore();
  await act(async () => root.unmount());
});
