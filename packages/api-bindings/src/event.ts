import { subscribe as on, NotificationResponse } from "./bridge.js";

export function subscribe<T>(
  eventName: string,
  handler: (payload: T) => NotificationResponse | undefined,
) {
  return on<T>(`event:${eventName}`, handler);
}
