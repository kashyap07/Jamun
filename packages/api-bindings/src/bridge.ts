/** Protocol v2: bounded requests, explicit readiness and acknowledged shell edits. */
export const PROTOCOL_VERSION = 2;
export type NotificationResponse = { unsubscribe: boolean };
export type Subscription = { unsubscribe: () => void };
type Handler<T> = (payload: T) => NotificationResponse | undefined | void;
type HostMessage = { id: number; ok: boolean; result?: unknown; error?: string } | { event: string; payload: unknown };
declare global {
  interface Window {
    webkit?: { messageHandlers?: { jamun?: { postMessage: (message: unknown) => void } } };
    __jamunReceive?: (message: HostMessage) => void;
  }
}
let nextId = 1;
const pending = new Map<number, { resolve: (value: unknown) => void; reject: (reason: Error) => void; timer: ReturnType<typeof setTimeout> }>();
const listeners = new Map<string, Set<Handler<unknown>>>();
const post = (message: unknown): boolean => {
  const handler = typeof window !== "undefined" && window.webkit?.messageHandlers?.jamun;
  if (!handler) return false;
  handler.postMessage(message);
  return true;
};
export const hasHost = () => typeof window !== "undefined" && Boolean(window.webkit?.messageHandlers?.jamun);
export function request<T = unknown>(method: string, params: Record<string, unknown> = {}, timeoutMs = 10000): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const id = nextId++;
    const timer = setTimeout(() => {
      pending.delete(id);
      if (method === "process.run") notify("process.cancel", { requestId: id });
      reject(new Error(`jamun request timed out (${method})`));
    }, timeoutMs);
    pending.set(id, { resolve: resolve as (value: unknown) => void, reject, timer });
    try {
      if (!post({ id, method, params, protocol: PROTOCOL_VERSION })) throw new Error(`jamun host unavailable (${method})`);
    } catch (error) {
      clearTimeout(timer); pending.delete(id); reject(error);
    }
  });
}
export function notify(method: string, params: Record<string, unknown> = {}) {
  post({ id: 0, method, params, protocol: PROTOCOL_VERSION });
}
export function subscribe<T>(event: string, handler: Handler<T>): Promise<Subscription> {
  let set = listeners.get(event);
  if (!set) { set = new Set(); listeners.set(event, set); }
  set.add(handler as Handler<unknown>);
  return Promise.resolve({ unsubscribe: () => { listeners.get(event)?.delete(handler as Handler<unknown>); } });
}
export function emit(event: string, payload: unknown) {
  for (const handler of [...(listeners.get(event) ?? [])]) {
    const response = handler(payload);
    if (response && response.unsubscribe) listeners.get(event)?.delete(handler);
  }
}
export let keyTransaction: { id: string; sessionId: string; handled: boolean } | undefined;
export function withKeyTransaction(id: string, sessionId: string, fn: () => void) {
  const transaction = { id, sessionId, handled: true };
  keyTransaction = transaction;
  try { fn(); } catch (error) { transaction.handled = false; throw error; }
  finally {
    keyTransaction = undefined;
    notify("key.done", { sessionId, keyId: id, handled: transaction.handled });
  }
}
export function passThroughKey() { if (keyTransaction) keyTransaction.handled = false; }
if (typeof window !== "undefined") {
  window.__jamunReceive = (message) => {
    if ("event" in message) { emit(message.event, message.payload); return; }
    const entry = pending.get(message.id);
    if (!entry) return;
    clearTimeout(entry.timer); pending.delete(message.id);
    if (message.ok) entry.resolve(message.result);
    else entry.reject(new Error(message.error ?? "jamun host error"));
  };
  window.addEventListener("pagehide", () => {
    notify("bridge.closed");
    for (const entry of pending.values()) { clearTimeout(entry.timer); entry.reject(new Error("jamun page closed")); }
    pending.clear();
  });
}
