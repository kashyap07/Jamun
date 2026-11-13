import { emit, notify, subscribe as on, NotificationResponse } from "./bridge.js";
import type { ShellContext } from "./types.js";

export enum ActionAvailability {
  ALWAYS = 0,
  WHEN_FOCUSED = 1,
  WHEN_HIDDEN = 2,
  WHEN_VISIBLE = 3,
}

export type Action = {
  identifier: string;
  name?: string;
  description?: string;
  category?: string;
  availability?: ActionAvailability;
  defaultBindings: string[];
};

export type KeybindingPressedNotification = {
  action?: string;
  keypress?: { appleKeyCode?: number; characters?: string };
  context?: ShellContext;
};

/** Keys the shell integration knows how to capture and forward. */
const SUPPORTED_KEYS = new Set([
  "up",
  "down",
  "tab",
  "shift+tab",
  "enter",
  "esc",
  "control+p",
  "control+n",
]);

const APPLE_KEY_CODES: Record<string, number> = { tab: 48 };

let keyToAction = new Map<string, string>();
let userBindings: Record<string, string> = {};

/**
 * User overrides from settings, in Fig's format:
 * "autocomplete.keybindings.<key>": "<action identifier>" (or "ignore").
 */
export function setUserBindings(settings: Record<string, unknown>) {
  userBindings = {};
  for (const [key, value] of Object.entries(settings)) {
    if (key.startsWith("autocomplete.keybindings.") && typeof value === "string") {
      userBindings[key.replace("autocomplete.keybindings.", "")] = value;
    }
  }
}

function buildKeyMap(actions: Action[], focused: boolean) {
  const map = new Map<string, string>();
  for (const action of actions) {
    const available =
      action.availability === ActionAvailability.ALWAYS || focused;
    if (!available) continue;
    for (const key of action.defaultBindings) {
      if (SUPPORTED_KEYS.has(key)) map.set(key, action.identifier);
    }
  }
  for (const [key, identifier] of Object.entries(userBindings)) {
    if (!SUPPORTED_KEYS.has(key)) continue;
    if (identifier === "ignore") map.delete(key);
    else if (actions.some((a) => a.identifier === identifier)) {
      map.set(key, identifier);
    }
  }
  return map;
}

export function pressed(
  handler: (
    notification: KeybindingPressedNotification,
  ) => NotificationResponse | undefined,
) {
  return on<KeybindingPressedNotification>("keybinding", handler);
}

export function setInterceptKeystrokes(
  actions: Action[],
  intercept: boolean,
  globalIntercept?: boolean,
  currentTerminalSessionId?: string,
) {
  keyToAction =
    intercept || globalIntercept ? buildKeyMap(actions, intercept) : new Map();
  notify("keys.intercept", {
    keys: [...keyToAction.keys()],
    sessionId: currentTerminalSessionId,
  });
}

// The shell forwards raw key names. Translate them to actions here so the
// binding logic stays in TypeScript. The shell blocks until it hears
// "key.done", so that is sent even when the key maps to nothing.
on<{ key: string; context?: ShellContext }>("key", ({ key, context }) => {
  try {
    const action = keyToAction.get(key);
    if (action) {
      emit("keybinding", {
        action,
        keypress: { appleKeyCode: APPLE_KEY_CODES[key] },
        context,
      } satisfies KeybindingPressedNotification);
    }
  } finally {
    notify("key.done", { sessionId: context?.sessionId });
  }
  return undefined;
});
