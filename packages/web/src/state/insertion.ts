import logger from "loglevel";
import { StoreApi } from "zustand";
import { Shell } from "@jamun/api-bindings";
import {
  Suggestion,
} from "@jamun/shared/internal";
import {
  makeArray,
  longestCommonPrefix,
  ensureTrailingSlash,
} from "@jamun/shared/utils";
import { SETTINGS } from "@jamun/api-bindings-wrappers";
import { trackEvent } from "../telemetry";
import { NamedSetState, AutocompleteState, Visibility } from "./types";
import {
  isMatchingType,
  getNameMatch,
  getQueryTermForSuggestion,
} from "../suggestions/helpers";
import { updateAutocompleteIndexFromUserInsert } from "../suggestions/sorting";
import { InsertPrefixError } from "./errors";
import { literalReplacement, replacementSpan, scalarLength } from "./literalEdit";

const insertString = (
  state: AutocompleteState,
  item: Suggestion,
  text: string,
  isFullCompletion: boolean,
  execute = false,
) => {
  const { buffer, cursorLocation, shellContext } = state.figState;
  if (!shellContext?.sessionId || shellContext.revision === undefined) throw new InsertPrefixError("No active shell snapshot");
  const query = getQueryTermForSuggestion(item, state.parserResult.searchTerm);
  const token = state.command?.tokens.at(-1);
  const raw = buffer.slice(token?.originalNode.startIndex ?? cursorLocation, cursorLocation);
  const isFile = item.type === "file" || item.type === "folder";
  const isTemplate = isFullCompletion && Boolean(item.insertValue) && !isFile;
  const autoExecute = isFullCompletion && item.type === "auto-execute";
  let deletion = 0;
  let insertion = text;
  let moveLeft = 0;
  if (autoExecute) {
    insertion = "";
  } else if (isTemplate) {
    const span = replacementSpan(raw, query);
    deletion = scalarLength(raw.slice(span.start));
    // Raw templates must replace an entire quoted token, not nest their syntax in a quote.
    if (span.quote) {
      if (raw[0] !== span.quote || span.start !== 1) throw new InsertPrefixError("Cannot insert a template inside a partially quoted token");
      deletion = scalarLength(raw);
    }
    const marker = insertion.indexOf("{cursor}");
    if (marker !== -1) {
      moveLeft = scalarLength(insertion.slice(marker + "{cursor}".length));
      insertion = insertion.slice(0, marker) + insertion.slice(marker + "{cursor}".length);
    }
    // Templates may describe multiple tokens, but cannot smuggle terminal controls/execution.
    if (/[\x00-\x1f\x7f]/.test(insertion)) throw new InsertPrefixError("Control characters are not allowed in completion templates");
  } else {
    ({ deletion, insertion } = literalReplacement(raw, query, text, isFile));
  }
  if (!autoExecute && isFullCompletion && item.shouldAddSpace &&
      (state.settings[SETTINGS.INSERT_SPACE_AUTOMATICALLY] ?? true)) insertion += " ";
  const rootCommand = state.command?.tokens[state.parserResult.commandIndex]?.text ?? "";
  if (item.type === "shortcut" || rootCommand === "?") {
    deletion = scalarLength(buffer.slice(state.command?.originalTree.startIndex ?? 0, cursorLocation));
  }
  return Shell.insert({
      insertion, deletion, moveLeft, immediate: execute || autoExecute,
      expectedBuffer: buffer, expectedCursor: scalarLength(buffer.slice(0, cursorLocation)),
      revision: shellContext.revision, sessionId: shellContext.sessionId,
    }).then(() => {
    if (isFullCompletion) updateAutocompleteIndexFromUserInsert(rootCommand, makeArray(item.name)[0] ?? "");
    trackEvent("autocomplete-insert", { insertionLength: scalarLength(insertion), suggestion_type: item.type ?? null });
    state.updateVisibilityPostInsert(item, isFullCompletion);
  }).catch(() => {
    logger.warn("Completion was rejected or expired; waiting for the next edit");
  });
};

const getFullInsertion = (
  item: Suggestion,
  searchTerm: string,
  fuzzySearch: boolean,
  preferVerboseSuggestions: boolean,
): string => {
  const queryTerm = getQueryTermForSuggestion(item, searchTerm);

  const isFolder = item.type === "folder";
  const isFileOrFolder = item.type === "file" || isFolder;

  if (item.insertValue && !isFileOrFolder) {
    return item.insertValue;
  }

  const match = getNameMatch(
    item,
    queryTerm,
    fuzzySearch,
    preferVerboseSuggestions,
  );
  if (!match) throw new InsertPrefixError("Suggestion no longer matches");
  return item.separatorToAdd ? `${match}${item.separatorToAdd}` : match;
};

const makeInsertTextForItem =
  (get: StoreApi<AutocompleteState>["getState"]) =>
  (item: Suggestion, execute = false) => {
    const state = get();
    const {
      parserResult: { searchTerm },
      fuzzySearchEnabled,
      settings,
    } = state;
    const text = getFullInsertion(
      item,
      searchTerm,
      fuzzySearchEnabled,
      settings[SETTINGS.PREFER_VERBOSE_SUGGESTIONS] as boolean,
    );

    return insertString(state, item, text, true, execute).catch(() => logger.warn("Unable to safely insert this suggestion"));
  };

const makeInsertCommonPrefix =
  (get: StoreApi<AutocompleteState>["getState"]) => () => {
    const state = get();
    const {
      suggestions,
      selectedIndex,
      parserResult: { searchTerm },
      fuzzySearchEnabled,
      settings,
      insertTextForItem,
    } = state;
    const selectedItem = suggestions[selectedIndex];

    const queryTerm = getQueryTermForSuggestion(selectedItem, searchTerm);
    if (suggestions.length === 1) {
      return insertTextForItem(selectedItem);
    }

    let { type: itemType } = selectedItem;

    if (itemType === "auto-execute") {
      itemType = selectedItem.originalType;
    }

    if (itemType && ["special", "auto-execute"].includes(itemType)) {
      throw new InsertPrefixError(
        `Cannot insert common prefix for type ${itemType}`,
      );
    }

    const typeFilterItem = {
      ...selectedItem,
      type: itemType,
      name:
        selectedItem.type === "auto-execute" &&
        selectedItem.originalType === "folder"
          ? makeArray(selectedItem.name ?? []).map(ensureTrailingSlash)
          : selectedItem.name,
    };

    const sameTypeSuggestionNames = suggestions
      .filter((suggestion) => isMatchingType(suggestion, typeFilterItem))
      .map((suggestion) =>
        (makeArray(suggestion.name || [])[0] ?? "").toLowerCase(),
      )
      .filter((name) => name.startsWith(queryTerm.toLowerCase()));

    if (sameTypeSuggestionNames.length === 1) {
      if (selectedItem.type === "auto-execute") {
        throw new InsertPrefixError(`Cannot auto-execute using common prefix`);
      }
      return insertTextForItem(selectedItem);
    }

    const uncasedSharedPrefix = longestCommonPrefix(sameTypeSuggestionNames);
    const sharedPrefix = makeArray(selectedItem.name || [])[0].slice(
      0,
      uncasedSharedPrefix.length,
    );
    if (!sharedPrefix || sharedPrefix === queryTerm) {
      throw new InsertPrefixError("No remaining prefix to insert");
    }
    const text = sharedPrefix;
    if (
      text ===
      getFullInsertion(
        selectedItem,
        searchTerm,
        fuzzySearchEnabled,
        settings[SETTINGS.PREFER_VERBOSE_SUGGESTIONS] as boolean,
      )
    ) {
      if (selectedItem.type === "auto-execute") {
        throw new InsertPrefixError(`Cannot auto-execute using common prefix`);
      }
      return insertTextForItem(selectedItem);
    }
    return insertString(state, selectedItem, text, false).catch(() => logger.warn("Unable to safely insert this prefix"));
  };

export const createInsertionState = (
  setNamed: NamedSetState<AutocompleteState>,
  get: StoreApi<AutocompleteState>["getState"],
) => ({
  insertCommonPrefix: makeInsertCommonPrefix(get),
  insertTextForItem: makeInsertTextForItem(get),
  updateVisibilityPostInsert: (
    suggestion: Suggestion,
    isFullCompletion: boolean,
  ) => {
    if (isFullCompletion) {
      setNamed("updateVisibilityPostInsert", {
        visibleState: Visibility.HIDDEN_BY_INSERTION,
        lastInsertedSuggestion: suggestion,
        justInserted: true,
      });
    } else {
      setNamed("updateVisibilityPostInsert", { justInserted: true });
    }
  },
});
