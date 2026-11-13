import { request, subscribe as on, NotificationResponse } from "./bridge.js";
import { setUserBindings } from "./keybindings.js";

export type SettingsChangedNotification = { jsonBlob?: string };

export const didChange = {
  subscribe(
    handler: (
      notification: SettingsChangedNotification,
    ) => NotificationResponse | undefined,
  ) {
    return on<SettingsChangedNotification>("settings", (notification) => {
      try {
        setUserBindings(JSON.parse(notification.jsonBlob ?? "{}"));
      } catch {
        /* ignore malformed settings */
      }
      return handler(notification);
    });
  },
};

export async function get(key: string) {
  return request<{ jsonBlob?: string }>("settings.get", { key });
}

export async function set(key: string, value: unknown): Promise<void> {
  await request("settings.set", { key, value: JSON.stringify(value) });
}

export async function remove(key: string): Promise<void> {
  await request("settings.set", { key });
}

export async function current() {
  const all = await request<{ jsonBlob?: string }>("settings.get", {});
  const parsed = JSON.parse(all.jsonBlob ?? "{}");
  setUserBindings(parsed);
  return parsed;
}
