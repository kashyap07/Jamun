/**
 * JSON bridge between the web app and the native jamun host.
 *
 * web -> host: window.webkit.messageHandlers.jamun.postMessage({ id, method, params })
 * host -> web: window.__jamunReceive({ id, ok, result, error }) for responses
 *              window.__jamunReceive({ event, payload }) for notifications
 */

export type NotificationResponse = { unsubscribe: boolean };
export type Subscription = { unsubscribe: () => void };
type Handler<T> = (payload: T) => NotificationResponse | undefined | void;

type HostMessage =
  | { id: number; ok: boolean; result?: unknown; error?: string }
  | { event: string; payload: unknown };

declare global {
  interface Window {
    webkit?: {
      messageHandlers?: {
        jamun?: { postMessage: (message: unknown) => void };
      };
    };
    __jamunReceive?: (message: HostMessage) => void;
  }
}

let nextId = 1;
const pending = new Map<
  number,
  { resolve: (value: unknown) => void; reject: (reason: Error) => void }
>();
const listeners = new Map<string, Set<Handler<unknown>>>();

const post = (message: unknown): boolean => {
  const handler = window.webkit?.messageHandlers?.jamun;
  if (!handler) return false;
  handler.postMessage(message);
  return true;
};

export const hasHost = () => Boolean(window.webkit?.messageHandlers?.jamun);

export function request<T = unknown>(
  method: string,
  params: Record<string, unknown> = {},
): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const id = nextId;
    nextId += 1;
    pending.set(id, { resolve: resolve as (value: unknown) => void, reject });
    if (!post({ id, method, params })) {
      pending.delete(id);
      reject(new Error(`jamun host unavailable (${method})`));
    }
  });
}

/** Fire and forget, for calls where the web app does not need an answer. */
export function notify(method: string, params: Record<string, unknown> = {}) {
  post({ id: 0, method, params });
}

export function subscribe<T>(
  event: string,
  handler: Handler<T>,
): Promise<Subscription> {
  let set = listeners.get(event);
  if (!set) {
    set = new Set();
    listeners.set(event, set);
  }
  const wrapped = handler as Handler<unknown>;
  set.add(wrapped);
  return Promise.resolve({
    unsubscribe: () => {
      listeners.get(event)?.delete(wrapped);
    },
  });
}

/** Deliver an event to web-side subscribers. Also used by the shim itself. */
export function emit(event: string, payload: unknown) {
  const set = listeners.get(event);
  if (!set) return;
  for (const handler of [...set]) {
    const response = handler(payload);
    if (response && response.unsubscribe) set.delete(handler);
  }
}

window.__jamunReceive = (message) => {
  if ("event" in message) {
    emit(message.event, message.payload);
    return;
  }
  const entry = pending.get(message.id);
  if (!entry) return;
  pending.delete(message.id);
  if (message.ok) entry.resolve(message.result);
  else entry.reject(new Error(message.error ?? "jamun host error"));
};
