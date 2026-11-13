import { emit, subscribe as on, NotificationResponse } from "./bridge.js";

// Local state is Fig's scratch key/value store. Nothing in jamun needs it to
// outlive the web view yet, so it lives in memory.
const state: Record<string, unknown> = {};

export type LocalStateChangedNotification = { jsonBlob?: string };

export const didChange = {
  subscribe(
    handler: (
      notification: LocalStateChangedNotification,
    ) => NotificationResponse | undefined,
  ) {
    return on<LocalStateChangedNotification>("localstate", handler);
  },
};

const changed = () => emit("localstate", { jsonBlob: JSON.stringify(state) });

export async function get(key: string) {
  return state[key] ?? null;
}

export async function set(key: string, value: unknown): Promise<void> {
  state[key] = value;
  changed();
}

export async function remove(key: string) {
  delete state[key];
  changed();
}

export async function current() {
  return { ...state };
}
