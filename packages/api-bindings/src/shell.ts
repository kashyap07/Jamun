import { request as hostRequest, keyTransaction, subscribe as on, NotificationResponse } from "./bridge.js";

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

export type ValidatedEdit = {
  insertion: string;
  deletion: number;
  moveLeft?: number;
  immediate?: boolean;
  /** swap the whole line for `insertion`; needs the shell's "replace" capability */
  replaceBuffer?: boolean;
  expectedBuffer: string;
  expectedCursor: number;
  revision: number;
  sessionId: string;
};

/** Literal text and execution intent are separate; no terminal-control decoding. */
export function insert(edit: ValidatedEdit): Promise<{ accepted: boolean }> {
  return hostRequest("shell.insert", {
    ...edit,
    moveLeft: edit.moveLeft ?? 0,
    keyId: keyTransaction?.sessionId === edit.sessionId ? keyTransaction.id : "0",
  }, 2500);
}
