import { notify, subscribe as on, NotificationResponse } from "./bridge.js";

export type ProcessChangedNotification = {
  sessionId?: string;
  newProcess?: { pid?: number; executable?: string; directory?: string };
};
export type ShellPromptReturnedNotification = { sessionId?: string };
export type HistoryUpdatedNotification = {
  command?: string;
  exitCode?: number;
  sessionId?: string;
};
export type TextUpdate = {
  insertion?: string;
  deletion?: number;
  offset?: number;
  immediate?: boolean;
  insertionBuffer?: string;
  insertDuringCommand?: boolean;
};

type Sub<T> = {
  subscribe: (
    handler: (notification: T) => NotificationResponse | undefined,
  ) => ReturnType<typeof on>;
};

export const processDidChange: Sub<ProcessChangedNotification> = {
  subscribe: (handler) => on("process", handler),
};
export const promptDidReturn: Sub<ShellPromptReturnedNotification> = {
  subscribe: (handler) => on("prompt", handler),
};
export const historyUpdated: Sub<HistoryUpdatedNotification> = {
  subscribe: (handler) => on("history", handler),
};

const BACKSPACE = "\b";
const CURSOR_LEFT = "\x1b[D";

/**
 * Fig encodes edits as terminal keystrokes: leading backspaces delete typed
 * characters, trailing cursor-left sequences move the caret back, and a final
 * newline executes. The zsh widget edits the buffer directly, so decode the
 * string into a structured edit here.
 */
export function decodeInsertion(text: string) {
  let rest = text;
  let deletion = 0;
  while (rest.startsWith(BACKSPACE)) {
    deletion += 1;
    rest = rest.slice(BACKSPACE.length);
  }
  let immediate = false;
  if (rest.endsWith("\n") || rest.endsWith("\r")) {
    immediate = true;
    rest = rest.replace(/[\r\n]+$/, "");
  }
  let moveLeft = 0;
  while (rest.endsWith(CURSOR_LEFT)) {
    moveLeft += 1;
    rest = rest.slice(0, -CURSOR_LEFT.length);
  }
  return { deletion, insertion: rest, moveLeft, immediate };
}

export async function insert(
  text: string,
  request?: Omit<TextUpdate, "insertion">,
  terminalSessionId?: string,
) {
  const decoded = decodeInsertion(text);
  notify("shell.insert", {
    sessionId: terminalSessionId,
    deletion: decoded.deletion + (request?.deletion ?? 0),
    insertion: decoded.insertion,
    moveLeft: decoded.moveLeft,
    immediate: decoded.immediate || Boolean(request?.immediate),
    insertionBuffer: request?.insertionBuffer,
  });
}
