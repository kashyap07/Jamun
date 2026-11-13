import { request, notify, PROTOCOL_VERSION } from "./bridge.js";
import { subscribe as on, NotificationResponse } from "./bridge.js";

export function subscribe<T>(
  eventName: string,
  handler: (payload: T) => NotificationResponse | undefined,
) {
  return on<T>(`event:${eventName}`, handler);
}

export async function ready() {
  return request("bridge.ready", { version: PROTOCOL_VERSION });
}
export const closed = () => notify("bridge.closed");

export const measure = (name: string, value: number) => notify("metrics.record", { name, value });
