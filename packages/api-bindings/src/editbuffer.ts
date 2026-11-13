import { subscribe as on, NotificationResponse } from "./bridge.js";
import type { ShellContext } from "./types.js";

export type EditBufferChangedNotification = {
  sessionId?: string;
  cursor?: number;
  revision?: number;
  buffer?: string;
  context?: ShellContext;
};

export function subscribe(
  handler: (
    notification: EditBufferChangedNotification,
  ) => NotificationResponse | undefined,
) {
  return on<EditBufferChangedNotification>("editbuffer", handler);
}
