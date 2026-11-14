import { create } from "zustand";
import type { Types } from "@jamun/api-bindings";
import { SETTINGS, SettingsMap } from "@jamun/api-bindings-wrappers";
import type { HistoryEntry } from "./atuin";

export type { HistoryEntry };

/** Actions sent by the shell while the history list is open. */
export enum ShellHistoryAction {
  OPEN = "openShellHistory",
  OLDER = "shellHistoryOlder",
  NEWER = "shellHistoryNewer",
  RUN = "shellHistoryRun",
  EDIT = "shellHistoryEdit",
  CLOSE = "shellHistoryClose",
}

/** Up is captured even with no popup showing, so it can open the list. */
export const OPEN_KEYS: Record<string, string> = { up: ShellHistoryAction.OPEN };

/** Same keys as atuin: Enter runs, Tab puts the command on the line. */
export const LIST_KEYS: Record<string, string> = {
  up: ShellHistoryAction.OLDER,
  "control+p": ShellHistoryAction.OLDER,
  down: ShellHistoryAction.NEWER,
  "control+n": ShellHistoryAction.NEWER,
  enter: ShellHistoryAction.RUN,
  tab: ShellHistoryAction.EDIT,
  esc: ShellHistoryAction.CLOSE,
};

/** atuin when it is installed, otherwise zsh's own history file. */
export type HistorySource = "atuin" | "zsh";

type ShellHistoryState = {
  /** Whether any history can be shown; undefined until checked. */
  available: boolean | undefined;
  source: HistorySource | undefined;
  active: boolean;
  /** False until the first results for this opening have arrived. */
  loaded: boolean;
  /** Oldest first. The newest entry is the last one, nearest the prompt. */
  entries: HistoryEntry[];
  selectedIndex: number;
  setSource: (source: HistorySource | undefined) => void;
  open: () => void;
  close: () => void;
  setEntries: (entries: HistoryEntry[]) => void;
  /** -1 is older, 1 is newer. False when there is nowhere left to go. */
  move: (delta: number) => boolean;
};

export const useShellHistory = create<ShellHistoryState>((set, get) => ({
  available: undefined,
  source: undefined,
  active: false,
  loaded: false,
  entries: [],
  selectedIndex: 0,
  setSource: (source) =>
    set(source
      ? { available: true, source }
      : { available: false, source, active: false, loaded: false, entries: [] }),
  open: () => set({ active: true, loaded: false, entries: [], selectedIndex: 0 }),
  close: () => {
    if (get().active) set({ active: false, loaded: false, entries: [], selectedIndex: 0 });
  },
  setEntries: (entries) =>
    set({ entries, loaded: true, selectedIndex: Math.max(0, entries.length - 1) }),
  move: (delta) => {
    const { entries, selectedIndex } = get();
    const next = selectedIndex + delta;
    if (next < 0 || next >= entries.length) return false;
    set({ selectedIndex: next });
    return true;
  },
}));

/**
 * The list replaces the whole line, which older shell scripts cannot do,
 * so it is offered only to shells that announce the "replace" capability.
 */
export const isShellHistoryReady = (
  shellContext: Types.ShellContext | undefined,
  settings: SettingsMap,
): boolean =>
  settings[SETTINGS.SHELL_HISTORY] !== false &&
  useShellHistory.getState().available === true &&
  Boolean(shellContext?.capabilities?.includes("replace"));
