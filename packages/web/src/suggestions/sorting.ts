import { makeArray } from "@jamun/shared/utils";
import { Suggestion } from "@jamun/shared/internal";
import {
  SETTINGS,
  getSetting,
} from "@jamun/api-bindings-wrappers";

// { command: { commandParam: count/lastUsedDate } }
// e.g. git: { add: 2, push: 4 }
type Index = Record<string, Record<string, number>>;

const readIndex = (key: string): Index => {
  try {
    const raw = localStorage.getItem(key);
    if (!raw || raw.length > 1_000_000) return Object.create(null);
    const parsed: unknown = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return Object.create(null);
    const index: Index = Object.create(null);
    for (const [command, values] of Object.entries(parsed).slice(-100)) {
      if (!values || typeof values !== "object") continue;
      index[command] = Object.assign(Object.create(null), Object.fromEntries(Object.entries(values).filter(([, value]) => typeof value === "number" && Number.isFinite(value)).slice(-200)));
    }
    return index;
  } catch { return Object.create(null); }
};
const frequencyIndex = readIndex("term_frequency_index_fig_only");
const recencyIndex = readIndex("term_frequency_index_fig_only_recency");
const boundIndex = (index: Index) => {
  for (const key of Object.keys(index).slice(0, -100)) delete index[key];
  for (const key of Object.keys(index)) {
    const values = Object.entries(index[key]).slice(-200);
    index[key] = Object.assign(Object.create(null), Object.fromEntries(values));
  }
};

// This function is called every time a user does an autocomplete command
export const updateAutocompleteIndexFromUserInsert = (
  cmd: string,
  param: string,
) => {
  if (param.includes("↪")) return;

  const frequencyIndexCmd = frequencyIndex[cmd] || {};
  const recencyIndexCmd = recencyIndex[cmd] || {};

  frequencyIndex[cmd] = {
    ...frequencyIndexCmd,
    [param]: (frequencyIndexCmd[param] || 0) + 1,
  };

  recencyIndex[cmd] = {
    ...recencyIndexCmd,
    [param]: Date.now(),
  };

  boundIndex(frequencyIndex); boundIndex(recencyIndex);
  try {
    localStorage.setItem("term_frequency_index_fig_only", JSON.stringify(frequencyIndex));
    localStorage.setItem("term_frequency_index_fig_only_recency", JSON.stringify(recencyIndex));
  } catch { /* Quota/storage failures must never interrupt a shell edit. */ }
};

export const updatePriorities = (suggestions: Suggestion[], cmd: string) => {
  let idxToUse;

  // Default setting for autocomplete.sortMethod is "recency".
  try {
    if (getSetting(SETTINGS.SORT_METHOD) !== "alphabetical") {
      idxToUse = recencyIndex;
    }
  } catch (_err) {
    idxToUse = recencyIndex;
  }

  const cmdRecency = idxToUse && idxToUse[cmd];

  return suggestions.map((suggestion) => {
    const name = makeArray(suggestion.name)[0] || "";
    const recency = name !== "../" && cmdRecency && cmdRecency[name];
    const recencyBoost = recency ? recency / 10000000000000 : 0;

    let priority = suggestion.priority || 50;
    if (suggestion.type !== "auto-execute") {
      priority = Math.max(Math.min(100, priority), 0);
    }

    if (recency && priority >= 50 && priority <= 75) {
      priority = 75 + recencyBoost;
    } else {
      priority += recencyBoost;
    }
    return { ...suggestion, priority };
  });
};
