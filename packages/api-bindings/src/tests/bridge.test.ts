import { afterEach, expect, it, vi } from "vitest";
import { emit, passThroughKey, request, subscribe, withKeyTransaction } from "../bridge";
import * as Keybindings from "../keybindings";

afterEach(() => { vi.useRealTimers(); delete window.webkit; });
it("expires requests, cancels process work, and ignores late replies", async () => {
  vi.useFakeTimers();
  const postMessage = vi.fn(); window.webkit = { messageHandlers: { jamun: { postMessage } } };
  const pending = request("process.run", {}, 50);
  const rejected = expect(pending).rejects.toThrow("timed out");
  await vi.advanceTimersByTimeAsync(51); await rejected;
  expect(postMessage).toHaveBeenLastCalledWith(expect.objectContaining({ method: "process.cancel", params: { requestId: postMessage.mock.calls[0][0].id } }));
  expect(() => window.__jamunReceive?.({ id: postMessage.mock.calls[0][0].id, ok: true })).not.toThrow();
});
it("acknowledges every key transaction and records pass-through", () => {
  const postMessage = vi.fn(); window.webkit = { messageHandlers: { jamun: { postMessage } } };
  withKeyTransaction("1", "A", () => {});
  withKeyTransaction("2", "A", passThroughKey);
  expect(() => withKeyTransaction("3", "A", () => { throw Error("failure"); })).toThrow();
  expect(postMessage.mock.calls.map(([value]) => value.params)).toEqual([
    { sessionId: "A", keyId: "1", handled: true }, { sessionId: "A", keyId: "2", handled: false }, { sessionId: "A", keyId: "3", handled: false },
  ]);
});
it("keeps session maps separate and exposes Tab while hidden", async () => {
  const postMessage = vi.fn(); window.webkit = { messageHandlers: { jamun: { postMessage } } };
  const listener = vi.fn(); const subscription = await subscribe("keybinding", listener);
  const actions = [{ identifier: "navigateDown", availability: Keybindings.ActionAvailability.WHEN_FOCUSED, defaultBindings: ["down"] }];
  Keybindings.setInterceptKeystrokes(actions, true, true, "A");
  Keybindings.setInterceptKeystrokes(actions, false, true, "B", true);
  emit("key", { key: "down", keyId: "1", context: { sessionId: "A" } });
  emit("key", { key: "tab", keyId: "2", context: { sessionId: "B" } });
  expect(listener.mock.calls.map(([event]) => event.action)).toEqual(["navigateDown", "showAutocomplete"]);
  Keybindings.setInterceptKeystrokes(actions, false, false, "A");
  emit("key", { key: "down", keyId: "3", context: { sessionId: "A" } });
  expect(postMessage).toHaveBeenLastCalledWith(expect.objectContaining({ method: "key.done", params: { sessionId: "A", keyId: "3", handled: false } }));
  subscription.unsubscribe();
});
