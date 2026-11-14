import { useCallback } from "react";
import logger from "loglevel";
import { Keybindings, Shell } from "@jamun/api-bindings";
import {
  SETTINGS,
  getSetting,
} from "@jamun/api-bindings-wrappers";
import { ACTIONS, AutocompleteAction } from "../actions";
import { useAutocompleteStore } from "../state";
import { Visibility } from "../state/types";
import { scalarLength } from "../state/literalEdit";
import {
  ShellHistoryAction,
  isShellHistoryReady,
  useShellHistory,
} from "../shellHistory";

export const setInterceptKeystrokes = (
  intercept: boolean,
  globalIntercept?: boolean,
  currentTerminalSessionId?: string,
  fallback: Record<string, string> = {},
) =>
  Keybindings.setInterceptKeystrokes(
    ACTIONS,
    intercept,
    globalIntercept,
    currentTerminalSessionId,
    getSetting<boolean>(SETTINGS.ONLY_SHOW_ON_TAB, false),
    fallback,
  );

enum KeyCode {
  TAB = 48,
}

export enum Direction {
  INCREASE = "increase",
  DECREASE = "decrease",
}

export const useAutocompleteKeypressCallback = (
  toggleDescriptionPopout: () => void,
  shake: () => void,
  changeSize: (direction: Direction) => void,
): Parameters<typeof Keybindings.pressed>[0] => {
  return useCallback(
    (notification) => {
      const { action, keypress, context: shellContext } = notification;
      logger.debug("Handling keypress", { notification, keypress, action });

      // Native key events can arrive before React commits another render.
      // Read selection and suggestions together for every individual key.
      const state = useAutocompleteStore.getState();
      const {
        suggestions, selectedIndex, visibleState, settings,
        setHistoryModeEnabled, setUserFuzzySearchEnabled,
        insertTextForItem, insertCommonPrefix, scroll: scrollToIndex, setVisibleState,
        figState: current,
      } = state;
      const selectedItem = suggestions[selectedIndex];
      const history = useShellHistory.getState();
      // Up past the top of the popup, or with no popup at all, opens the
      // shell's history (atuin) in the popup. A multi-line buffer keeps Up
      // for moving between its lines.
      const openHistory = () => {
        if (!isShellHistoryReady(current.shellContext, settings) ||
            current.buffer.includes("\n")) return false;
        history.open();
        return true;
      };
      // Enter and Tab swap the whole line for the chosen command.
      const replaceLine = (command: string, execute: boolean) => {
        Shell.insert({ insertion: command, deletion: 0, moveLeft: 0, immediate: execute, replaceBuffer: true,
          expectedBuffer: current.buffer, expectedCursor: scalarLength(current.buffer.slice(0, current.cursorLocation)),
          revision: shellContext!.revision!, sessionId: shellContext!.sessionId!,
        }).catch(() => logger.warn("History command was rejected or expired"));
      };
      const navigate = (delta: number, hideOrShowHistoryOnNegative = false) => {
        if (!suggestions.length) { Keybindings.passThroughKey(); return; }
        if (delta < 0 && hideOrShowHistoryOnNegative && selectedIndex === 0 &&
            !getSetting<boolean>(SETTINGS.NAVIGATE_TO_HISTORY)) {
          if (openHistory()) return;
          // Without atuin, Up on a popup the user has not moved into belongs
          // to the shell's own history. After navigating down, Up stays in
          // the list, where wrap-around applies as usual.
          if (!state.hasChangedIndex) {
            setVisibleState(Visibility.HIDDEN_UNTIL_KEYPRESS);
            Keybindings.passThroughKey();
            return;
          }
        }
        let newIndex = selectedIndex + delta;
        let newVisibleState = visibleState;
        if (settings[SETTINGS.SCROLL_WRAP_AROUND]) {
          newIndex = (newIndex + suggestions.length) % suggestions.length;
        } else if (newIndex === -1 && hideOrShowHistoryOnNegative) {
          if (getSetting<boolean>(SETTINGS.NAVIGATE_TO_HISTORY)) {
            setHistoryModeEnabled((enabled) => !enabled);
            return;
          }
          newVisibleState = Visibility.HIDDEN_UNTIL_KEYPRESS;
        }
        scrollToIndex(newIndex, newVisibleState);
      };
      if (!shellContext?.sessionId || current.shellContext?.sessionId !== shellContext.sessionId ||
          current.shellContext?.revision !== shellContext.revision) {
        Keybindings.passThroughKey();
        return undefined;
      }

      if (history.active) {
        const entry = history.entries[history.selectedIndex];
        switch (action) {
          case ShellHistoryAction.OLDER:
            history.move(-1);
            break;
          case ShellHistoryAction.NEWER:
            // Down past the newest entry leaves history, as in atuin.
            if (!history.move(1)) history.close();
            break;
          case ShellHistoryAction.RUN:
          case ShellHistoryAction.EDIT:
            // With nothing to pick, the key does what it does in the shell.
            if (entry) replaceLine(entry.command, action === ShellHistoryAction.RUN);
            else Keybindings.passThroughKey();
            history.close();
            break;
          case ShellHistoryAction.CLOSE:
            history.close();
            break;
          default:
            Keybindings.passThroughKey();
            break;
        }
        return undefined;
      }
      if (action === ShellHistoryAction.OPEN) {
        if (!openHistory()) Keybindings.passThroughKey();
        return undefined;
      }

      if (
        getSetting<boolean>(SETTINGS.ONLY_SHOW_ON_TAB) &&
        keypress?.appleKeyCode === KeyCode.TAB &&
        visibleState !== Visibility.VISIBLE
      ) {
        if (suggestions.length === 0) { Keybindings.passThroughKey(); return undefined; }
        if (suggestions.length === 1) {
          insertTextForItem(suggestions[0]);
          return undefined;
        }
        setVisibleState(Visibility.VISIBLE);
        return undefined;
      }
      if (!selectedItem && ![AutocompleteAction.SHOW_AUTOCOMPLETE, AutocompleteAction.HIDE_AUTOCOMPLETE, AutocompleteAction.TOGGLE_AUTOCOMPLETE].includes(action as AutocompleteAction)) {
        Keybindings.passThroughKey(); return undefined;
      }
      switch (action) {
        case AutocompleteAction.NAVIGATE_UP:
          navigate(-1, true);
          break;
        case AutocompleteAction.NAVIGATE_DOWN:
          navigate(1);
          break;
        case AutocompleteAction.INSERT_SELECTED:
          insertTextForItem(selectedItem);
          break;
        case AutocompleteAction.INSERT_COMMON_PREFIX:
          try {
            insertCommonPrefix();
          } catch (_err) {
            shake();
          }
          break;
        case AutocompleteAction.INSERT_COMMON_PREFIX_OR_NAVIGATE_DOWN:
          try {
            insertCommonPrefix();
          } catch (_err) {
            navigate(1);
          }
          break;
        case AutocompleteAction.INSERT_COMMON_PREFIX_OR_INSERT_SELECTED:
          try {
            insertCommonPrefix();
          } catch (_err) {
            insertTextForItem(selectedItem);
          }
          break;
        case AutocompleteAction.INSERT_SELECTED_AND_EXECUTE:
          insertTextForItem(selectedItem, true);
          break;
        case AutocompleteAction.EXECUTE:
          Shell.insert({ insertion: "", deletion: 0, moveLeft: 0, immediate: true,
            expectedBuffer: current.buffer, expectedCursor: scalarLength(current.buffer.slice(0, current.cursorLocation)),
            revision: shellContext.revision!, sessionId: shellContext.sessionId,
          }).catch(() => logger.warn("Execute request expired"));
          break;
        case AutocompleteAction.HIDE_AUTOCOMPLETE:
          setVisibleState(Visibility.HIDDEN_UNTIL_SHOWN);
          break;
        case AutocompleteAction.SHOW_AUTOCOMPLETE:
          setVisibleState(Visibility.VISIBLE);
          break;
        case AutocompleteAction.TOGGLE_AUTOCOMPLETE:
          setVisibleState(
            visibleState === Visibility.VISIBLE
              ? Visibility.HIDDEN_UNTIL_SHOWN
              : Visibility.VISIBLE,
          );
          break;
        case AutocompleteAction.TOGGLE_HISTORY_MODE:
          setHistoryModeEnabled((enabled) => !enabled);
          break;
        case AutocompleteAction.TOGGLE_DESCRIPTION:
          if (!getSetting<boolean>(SETTINGS.ALWAYS_SHOW_DESCRIPTION)) {
            toggleDescriptionPopout();
          }
          break;
        case AutocompleteAction.TOGGLE_FUZZY_SEARCH:
          setUserFuzzySearchEnabled((enabled) => !enabled);
          break;
        case AutocompleteAction.INCREASE_SIZE:
          changeSize(Direction.INCREASE);
          break;
        case AutocompleteAction.DECREASE_SIZE:
          changeSize(Direction.DECREASE);
          break;
        case AutocompleteAction.SELECT_SUGGESTION_1:
        case AutocompleteAction.SELECT_SUGGESTION_2:
        case AutocompleteAction.SELECT_SUGGESTION_3:
        case AutocompleteAction.SELECT_SUGGESTION_4:
        case AutocompleteAction.SELECT_SUGGESTION_5:
        case AutocompleteAction.SELECT_SUGGESTION_6:
        case AutocompleteAction.SELECT_SUGGESTION_7:
        case AutocompleteAction.SELECT_SUGGESTION_8:
        case AutocompleteAction.SELECT_SUGGESTION_9:
        case AutocompleteAction.SELECT_SUGGESTION_10: {
          const suggestionIndex = Number(action.replace("selectSuggestion", "")) - 1;
          if (
            suggestionIndex <= suggestions.length - 1 &&
            suggestionIndex >= 0 &&
            suggestionIndex <= 9
          ) {
            scrollToIndex(suggestionIndex, Visibility.VISIBLE);
          }
          break;
        }
        default:
          logger.error("Unrecognized action");
          break;
      }
      return undefined;
    },
    [toggleDescriptionPopout, shake, changeSize],
  );
};
