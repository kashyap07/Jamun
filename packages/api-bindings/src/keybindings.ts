import { emit, notify, subscribe as on, NotificationResponse, withKeyTransaction, passThroughKey } from "./bridge.js";
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
  "control+k",
  "control+r",
]);

const APPLE_KEY_CODES: Record<string, number> = { tab: 48 };

const sessionKeyMaps = new Map<string, Map<string, string>>();
export { passThroughKey };
export const isSupportedKey = (key: string) => SUPPORTED_KEYS.has(key);
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
      action.availability === ActionAvailability.ALWAYS ||
      (action.availability === ActionAvailability.WHEN_HIDDEN ? !focused : focused);
    if (!available) continue;
    for (const key of action.defaultBindings) {
      if (SUPPORTED_KEYS.has(key)) map.set(key, action.identifier);
    }
  }
  for (const [key, identifier] of Object.entries(userBindings)) {
    if (!SUPPORTED_KEYS.has(key)) continue;
    if (identifier === "ignore") map.delete(key);
    else if (actions.some((a) => a.identifier === identifier &&
      (a.availability === ActionAvailability.ALWAYS ||
        (a.availability === ActionAvailability.WHEN_HIDDEN ? !focused : focused)))) {
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
  showOnTab = false,
  /** key -> action, captured whenever the popup itself does not claim the key */
  fallback: Record<string, string> = {},
) {
  if (!currentTerminalSessionId) return;
  const map = intercept || globalIntercept ? buildKeyMap(actions, intercept) : new Map<string, string>();
  if (!intercept && globalIntercept && showOnTab && userBindings.tab !== "ignore") map.set("tab", "showAutocomplete");
  for (const [key, identifier] of Object.entries(fallback)) {
    if (SUPPORTED_KEYS.has(key) && !map.has(key) && userBindings[key] !== "ignore") map.set(key, identifier);
  }
  applyKeyMap(currentTerminalSessionId, map);
}

/** Capture exactly these keys, ignoring the regular popup actions. */
export function setKeyMap(sessionId: string | undefined, keys: Record<string, string>) {
  if (!sessionId) return;
  applyKeyMap(sessionId, new Map(Object.entries(keys).filter(([key]) => SUPPORTED_KEYS.has(key))));
}

function applyKeyMap(sessionId: string, map: Map<string, string>) {
  if (map.size) sessionKeyMaps.set(sessionId, map);
  else sessionKeyMaps.delete(sessionId);
  notify("keys.intercept", { keys: [...map.keys()], sessionId });
}

on<{ key: string; keyId: string; context?: ShellContext }>("key", ({ key, keyId, context }) => {
  if (!context?.sessionId) return undefined;
  withKeyTransaction(keyId, context.sessionId, () => {
    const action = sessionKeyMaps.get(context.sessionId!)?.get(key);
    if (!action) { passThroughKey(); return; }
    emit("keybinding", { action, keypress: { appleKeyCode: APPLE_KEY_CODES[key] }, context } satisfies KeybindingPressedNotification);
  });
  return undefined;
});
