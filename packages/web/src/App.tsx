import {
  WindowPosition,
  Settings,
  Event,
  Keybindings,
  Shell,
} from "@jamun/api-bindings";
import { SETTINGS } from "@jamun/api-bindings-wrappers";
import React, {
  useState,
  useEffect,
  useCallback,
  useRef,
  useMemo,
  MutableRefObject,
} from "react";

import logger from "loglevel";
import { getCWDForFilesAndFolders } from "@jamun/shared/utils";
import * as jsxRuntime from "react/jsx-runtime";
import * as figApiBindings from "@jamun/api-bindings";
import { getMaxHeight, getMaxWidth, POPOUT_WIDTH } from "./window";
import { useParseArgumentsEffect } from "./parser/hooks";
import { loadHistory } from "./history";
import "./index.css";
import AutoSizedList, { AutoSizedHandleRef } from "./components/AutoSizedList";

import {
  useFigKeypress,
  useFigAutocomplete,
  useFigSettings,
  useFigClearCache,
} from "./fig/hooks";

import { getCommonSuggestionPrefix } from "./suggestions/helpers";

import { useAutocompleteStore } from "./state";
import { Visibility } from "./state/types";
import {
  useAutocompleteKeypressCallback,
  setInterceptKeystrokes,
  Direction,
} from "./hooks/keypress";
import {
  useShake,
  useDynamicResizeObserver,
  useSystemTheme,
} from "./hooks/helpers";

import Suggestion from "./components/Suggestion";
import Description, { DescriptionPosition } from "./components/Description";
import { setFontFamily, setFontSize, setTheme } from "./fig/themes";
import LoadingIcon from "./components/LoadingIcon";
import ShellHistory from "./components/ShellHistory";
import {
  HistoryEntry,
  LIST_KEYS,
  OPEN_KEYS,
  isShellHistoryReady,
  useShellHistory,
} from "./shellHistory";
import { isAtuinInstalled, searchAtuin } from "./shellHistory/atuin";
import { DatedCommand, filterZshHistory, loadZshHistory } from "./shellHistory/zsh";
import { scalarLength } from "./state/literalEdit";

// eslint-disable-next-line @typescript-eslint/ban-ts-comment
// @ts-ignore
window.jsxRuntime = jsxRuntime;
window.React = React;
// eslint-disable-next-line @typescript-eslint/ban-ts-comment
// @ts-ignore
window.figApiBindings = figApiBindings;

const getIconPath = (cwd: string): string => {
  const { home } = fig.constants ?? {};
  const path = home && cwd.startsWith("~") ? home + cwd.slice(1) : cwd;
  return path.startsWith("//") ? path.slice(1) : path;
};

const HISTORY_ROWS = 10;

function App() {
  const {
    generatorStates,
    suggestions,
    selectedIndex,
    visibleState,
    figState: { buffer, cursorLocation, cwd, shellContext, receivedAt },
    parserResult: { searchTerm, currentArg },
    settings,
    setSettings,
    insertTextForItem,

    fuzzySearchEnabled,
    setUserFuzzySearchEnabled,
    setFigState,
  } = useAutocompleteStore();

  const history = useShellHistory();
  const historyReady = isShellHistoryReady(shellContext, settings);
  const [systemTheme] = useSystemTheme();
  const [isShaking, shake] = useShake();
  const [isLoadingSuggestions, setIsLoadingSuggestions] = useState(false);
  const [windowState, setWindowState] = useState({
    isDescriptionSeparate: false,
    isAboveCursor: true,
    descriptionPosition: "unknown" as DescriptionPosition,
  });
  const {
    [SETTINGS.THEME]: theme,
    [SETTINGS.FUZZY_SEARCH]: userFuzzySearch,
    [SETTINGS.FONT_FAMILY]: fontFamily,
    [SETTINGS.FONT_SIZE]: settingsFontSize,
    [SETTINGS.WIDTH]: settingsWidth,
    [SETTINGS.HEIGHT]: settingsHeight,
    [SETTINGS.ALWAYS_SHOW_DESCRIPTION]: alwaysShowDescription,
    [SETTINGS.DEV_MODE]: devMode,
  } = settings;

  const [size, setSize] = useState({
    fontSize: settingsFontSize as number | undefined,
    maxHeight: getMaxHeight(),
    suggestionWidth: getMaxWidth(),
    // 20 is the default height of a suggestion row. Font size is undefined unless set by user
    // in settings. If not set, row height should default to 20px.
    itemSize: 20,
  });

  useEffect(() => {
    setSize((oldSize) => ({
      ...oldSize,
      maxHeight: getMaxHeight(),
      suggestionWidth: getMaxWidth(),
    }));
  }, [settingsHeight, settingsWidth]);

  // useEffect(() => {
  //   loadPrivateSpecs(authClient).catch(captureError);
  // }, []);

  // jamun: unless the user set a height, fit six whole rows plus the
  // description line, so no row is ever cut in half.
  const listMaxHeight =
    typeof settingsHeight === "number" ? size.maxHeight : size.itemSize * 7;

  const isLoading = isLoadingSuggestions;

  useEffect(() => {
    // Default font-size is 12.8px (0.8em) and default row size is 20px = 12.8 * 1.5625
    // Row height should scale accordingly with font-size
    const fontSize =
      typeof settingsFontSize === "number" && settingsFontSize > 0
        ? settingsFontSize
        : 12.8;

    setSize((oldSize) => ({
      ...oldSize,
      fontSize,
      // jamun: slightly taller rows than Fig, on whole pixels.
      itemSize: Math.round(fontSize * 1.7),
    }));
  }, [settingsFontSize]);

  // Info passed down to suggestions to render icons and underline.
  const iconPath = useMemo(
    () => getIconPath(getCWDForFilesAndFolders(cwd, searchTerm)),
    [cwd, searchTerm],
  );

  const commonPrefix = useMemo(
    () => getCommonSuggestionPrefix(selectedIndex, suggestions),
    [selectedIndex, suggestions],
  );

  useEffect(() => {
    setWindowState((state) => ({
      isAboveCursor: alwaysShowDescription ? state.isAboveCursor : false,
      isDescriptionSeparate: alwaysShowDescription as boolean,
      descriptionPosition: "unknown",
    }));
  }, [alwaysShowDescription]);

  // Effect hooks into fig autocomplete events, parser, async generator results, and keypresses.
  const toggleDescriptionPopout = () => {
    setWindowState((state) => ({
      // if we are bringing the description back to the suggestion list, set isAboveCursor to false.
      isAboveCursor: state.isDescriptionSeparate ? false : state.isAboveCursor,
      isDescriptionSeparate: !state.isDescriptionSeparate,
      descriptionPosition: "unknown",
    }));
  };

  const changeSize = useCallback((direction: Direction): void => {
    // --font-size is read from the stylesheet as " 12.8px". We just want the number
    const currentFontSize = window
      .getComputedStyle(document.documentElement)
      .getPropertyValue("--font-size")
      .slice(0, -2)
      .trim();
    // Increase or decrease current size by 10%
    const change = (val: number) =>
      direction === Direction.INCREASE ? val * 1.1 : val / 1.1;

    setSize((oldSize) => ({
      fontSize: change(oldSize.fontSize ?? Number(currentFontSize)),
      itemSize: change(oldSize.itemSize),
      maxHeight: change(oldSize.maxHeight),
      suggestionWidth: change(oldSize.suggestionWidth),
    }));
  }, []);

  const keypressCallback = useAutocompleteKeypressCallback(
    toggleDescriptionPopout,
    shake,
    changeSize,
  );

  useEffect(() => {
    window.globalCWD = "";
    window.globalTerminalSessionId = "";
    window.globalSSHString = "";
  }, []);

  useFigAutocomplete(setFigState);
  useParseArgumentsEffect(setIsLoadingSuggestions);
  useFigSettings(setSettings);
  useFigKeypress(keypressCallback);
  useFigClearCache();
  useEffect(() => {
    Event.ready().catch(() => logger.warn("Jamun protocol handshake failed"));
    return () => Event.closed();
  }, []);

  useEffect(() => {
    Settings.get(SETTINGS.DISABLE_HISTORY_LOADING)
      .catch(() => undefined)
      .then((res) => {
        if (!JSON.parse(res?.jsonBlob ?? "false")) {
          loadHistory({});
        }
      });
  }, []);

  useEffect(() => {
    let isMostRecentEffect = true;
    if (generatorStates.some(({ loading }) => loading)) {
      setTimeout(() => {
        if (isMostRecentEffect) {
          setIsLoadingSuggestions(true);
        }
      }, 200);
    } else {
      setIsLoadingSuggestions(false);
    }
    return () => {
      isMostRecentEffect = false;
    };
  }, [generatorStates]);

  // Make sure fig dimensions align with our desired dimensions.
  const isHidden = visibleState !== Visibility.VISIBLE;
  const interceptKeystrokes = Boolean(!isHidden && suggestions.length > 0);
  const measuredRevision = useRef<string>();
  useEffect(() => {
    const revision = `${shellContext?.sessionId}:${shellContext?.revision}`;
    if (isHidden || isLoading || !receivedAt || measuredRevision.current === revision) return;
    measuredRevision.current = revision;
    const frame = requestAnimationFrame(() => Event.measure("suggestion_ms", performance.now() - receivedAt));
    return () => cancelAnimationFrame(frame);
  }, [isHidden, isLoading, receivedAt, shellContext?.sessionId, shellContext?.revision, suggestions]);

  // Shell history: find out once per shell whether atuin can be run.
  const sessionId = shellContext?.sessionId;
  const historyFile = shellContext?.historyFile;
  const { source: historySource, active: historyActive,
    setSource: setHistorySource, setEntries: setHistoryEntries, close: closeHistory } = history;
  // atuin when installed, otherwise zsh's own history file. Checked for each
  // shell, since they need not share a PATH.
  useEffect(() => {
    if (!sessionId) return undefined;
    let isMostRecentEffect = true;
    isAtuinInstalled(sessionId)
      .then(async (installed) => {
        if (installed) return "atuin" as const;
        return (await loadZshHistory(sessionId, historyFile)).length > 0 ? ("zsh" as const) : undefined;
      })
      .catch((error) => {
        logger.warn(`Shell history is unavailable: ${error}`);
        return undefined;
      })
      .then((source) => { if (isMostRecentEffect) setHistorySource(source); });
    return () => { isMostRecentEffect = false; };
  }, [sessionId, historyFile, setHistorySource]);
  // The history file is read once each time the list opens.
  const zshHistory = useRef<Promise<DatedCommand[]>>();
  useEffect(() => { if (!historyActive) zshHistory.current = undefined; }, [historyActive]);
  // The list belongs to one shell.
  useEffect(() => closeHistory, [sessionId, closeHistory]);
  // While the list is open, what is typed on the line is the search query.
  useEffect(() => {
    if (!historyActive || !sessionId) return undefined;
    let isMostRecentEffect = true;
    const search = () => {
      if (historySource === "atuin") return searchAtuin(buffer, sessionId);
      zshHistory.current ??= loadZshHistory(sessionId, historyFile);
      return zshHistory.current.then((all) => filterZshHistory(all, buffer, Date.now() / 1000));
    };
    search()
      .then((entries) => { if (isMostRecentEffect) setHistoryEntries(entries); })
      .catch(() => {
        logger.warn("Shell history search failed");
        if (isMostRecentEffect) closeHistory();
      });
    return () => { isMostRecentEffect = false; };
  }, [historyActive, historySource, historyFile, buffer, sessionId, setHistoryEntries, closeHistory]);

  useEffect(() => {
    logger.info("Setting intercept keystrokes", {
      suggestions,
      interceptKeystrokes,
    });
    if (historyActive) {
      Keybindings.setKeyMap(sessionId, LIST_KEYS);
      return;
    }
    setInterceptKeystrokes(
      interceptKeystrokes,
      suggestions.length > 0,
      sessionId,
      historyReady ? OPEN_KEYS : {},
    );
  }, [interceptKeystrokes, suggestions.length, sessionId, settings, historyActive, historyReady]);
  // Updating the current map must not briefly release every key to zsh.
  // Release only when leaving this terminal session or unmounting the UI.
  useEffect(() => () => {
    setInterceptKeystrokes(false, false, shellContext?.sessionId);
  }, [shellContext?.sessionId]);
  useEffect(() => {
    setTheme(systemTheme, theme as string);
  }, [theme, systemTheme]);
  useEffect(() => {
    setFontSize(size.fontSize);
  }, [size.fontSize]);
  useEffect(() => {
    setUserFuzzySearchEnabled((userFuzzySearch ?? false) as boolean);
  }, [setUserFuzzySearchEnabled, userFuzzySearch]);
  useEffect(() => {
    setFontFamily(fontFamily as string);
  }, [fontFamily]);
  // Scroll when selectedIndex changes.
  const listRef =
    useRef<AutoSizedHandleRef>() as MutableRefObject<AutoSizedHandleRef>;

  const scrollToItemCallback = useCallback(() => {
    logger.info("Scrolling to", { selectedIndex });
    listRef.current?.scrollToItem(selectedIndex);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selectedIndex, windowState.descriptionPosition]);

  useEffect(() => {
    let isMostRecentEffect = true;

    if (
      windowState.isDescriptionSeparate ||
      Boolean(suggestions[selectedIndex]?.previewComponent)
    ) {
      WindowPosition.isValidFrame({
        height: listMaxHeight,
        width: size.suggestionWidth + POPOUT_WIDTH,
        anchorX: 0,
      })
        .then(({ isAbove, isClipped }) => {
          if (isMostRecentEffect) {
            setWindowState((state) =>
              state.isDescriptionSeparate ||
              Boolean(suggestions[selectedIndex]?.previewComponent)
                ? {
                    ...state,
                    descriptionPosition: isClipped ? "left" : "right",
                    isAboveCursor: isAbove ?? false,
                    previewPosition: isClipped ? "left" : "right",
                  }
                : state,
            );
          }
        })
        .catch((err) => {
          logger.error("Error checking window position", { err });
        });
    }

    return () => {
      isMostRecentEffect = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [
    size.suggestionWidth,
    listMaxHeight,
    buffer,
    windowState.isDescriptionSeparate,
    // eslint-disable-next-line react-hooks/exhaustive-deps
    suggestions[selectedIndex]?.previewComponent,
  ]);

  const hasSpecialArgDescription =
    suggestions.length === 0 &&
    Boolean(currentArg?.name || currentArg?.description);

  const onResize: (size: { height?: number; width?: number }) => void =
    useCallback(
      ({ height, width }) => {
        const onLeft =
          !hasSpecialArgDescription &&
          windowState.descriptionPosition === "left";

        const frame = {
          height: height || 1,
          width: width || 1,
          anchorX: onLeft && !historyActive ? -POPOUT_WIDTH : 0,
          offsetFromBaseline: -3,
          // History reads upwards from the prompt, newest entry nearest.
          preferAbove: historyActive,
        };
        logger.debug("Setting window position", { frame });
        WindowPosition.setFrame(frame)
          .then(({ isClipped, isAbove }) => {
            setWindowState((state) =>
              state.isDescriptionSeparate ||
              devMode ||
              Boolean(suggestions[selectedIndex]?.previewComponent)
                ? {
                    ...state,
                    descriptionPosition: isClipped ? "left" : "right",
                    isAboveCursor: isAbove ?? false,
                    previewPosition: isClipped ? "left" : "right",
                  }
                : state,
            );
          })
          .catch((err) => {
            logger.debug("Unable to set window position", { err });
          });
      },
      // eslint-disable-next-line react-hooks/exhaustive-deps
      [
        windowState.descriptionPosition,
        hasSpecialArgDescription,
        isHidden,
        historyActive,
        // eslint-disable-next-line react-hooks/exhaustive-deps
        suggestions[selectedIndex]?.previewComponent,
      ],
    );

  // A click puts the command on the line; only Enter runs one.
  const pickHistoryEntry = useCallback(
    (entry: HistoryEntry) => {
      if (!shellContext?.sessionId || shellContext.revision === undefined) return;
      Shell.insert({
        insertion: entry.command, deletion: 0, moveLeft: 0, replaceBuffer: true,
        expectedBuffer: buffer, expectedCursor: scalarLength(buffer.slice(0, cursorLocation)),
        revision: shellContext.revision, sessionId: shellContext.sessionId,
      }).catch(() => logger.warn("History command was rejected or expired"));
      closeHistory();
    },
    [shellContext, buffer, cursorLocation, closeHistory],
  );

  useEffect(() => {
    onResize({});
  }, [onResize]);

  // A hidden web view reports its size late, which delayed the first history
  // list after launch. Its size is known up front, so ask for it directly.
  const historyWidth = Math.round(size.suggestionWidth * 1.8);
  const historyRows = Math.max(1, Math.min(history.entries.length, HISTORY_ROWS));
  useEffect(() => {
    if (!historyActive || !history.loaded) return;
    // Rows, the hint line, and 4px of padding above and below.
    onResize({ width: historyWidth, height: (historyRows + 1) * size.itemSize + 8 });
  }, [historyActive, history.loaded, historyRows, historyWidth, size.itemSize, onResize]);

  const { ref: autocompleteWindowRef } = useDynamicResizeObserver({ onResize });

  if (historyActive) {
    // Nothing is drawn until the first results arrive, to avoid a flash.
    if (!history.loaded) return <div ref={autocompleteWindowRef} id="autocompleteWindow" />;
    return (
      <div
        ref={autocompleteWindowRef}
        id="autocompleteWindow"
        className="relative flex flex-col overflow-hidden"
      >
        <ShellHistory
          entries={history.entries}
          selectedIndex={history.selectedIndex}
          itemSize={size.itemSize}
          width={historyWidth}
          maxRows={HISTORY_ROWS}
          onPick={pickHistoryEntry}
        />
        <span className="sr-only" role="status" aria-live="polite" aria-atomic="true">
          {history.entries[history.selectedIndex]
            ? `${history.entries.length - history.selectedIndex} of ${history.entries.length}: ${history.entries[history.selectedIndex].command}`
            : "No matching history"}
        </span>
      </div>
    );
  }

  if (isHidden) {
    return <div ref={autocompleteWindowRef} id="autocompleteWindow" />;
  }

  const hasSuggestions = suggestions.length > 0;

  const descriptionPosition =
    hasSuggestions && windowState.isDescriptionSeparate
      ? windowState.descriptionPosition
      : "unknown";

  const description = (
    <Description
      currentArg={currentArg}
      hasSuggestions={hasSuggestions}
      selectedItem={suggestions[selectedIndex]}
      shouldShowHint={!isLoading && !alwaysShowDescription}
      position={descriptionPosition}
      height={size.itemSize}
    />
  );

  const hasBottomDescription =
    descriptionPosition === "unknown" && description !== null;
  const listClasses = [
    "rounded",
    isShaking && "shake",
    hasBottomDescription && "rounded-b-none",
  ];

  const devModeWarning: React.ReactNode = devMode ? (
    <div
      style={{
        width: size.suggestionWidth - 20,
      }}
      className="m-1 space-y-1.5 rounded bg-amber-500 px-2.5 py-2 text-black"
    >
      <div className="text-base font-bold">Developer mode enabled!</div>
      <div className="text-sm">Using your trusted developer specs folder.</div>
      <button type="button" className="text-xs underline" onClick={() => Settings.set("autocomplete.developerMode", false).then(() => window.location.reload()).catch(() => logger.warn("Could not disable developer specs"))}>
        Disable developer specs
      </button>
    </div>
  ) : null;

  let contents: React.ReactNode;

  if (isLoading) {
    contents = <LoadingIcon />;
  } else {
    contents = (
      <>
        {windowState.isAboveCursor && devModeWarning}
        <div className="flex flex-row gap-1.5 py-1">
          {descriptionPosition === "left" && description}
          <div
            className="relative flex flex-none flex-col items-stretch overflow-hidden"
            style={
              hasSuggestions
                ? {
                    width: size.suggestionWidth,
                    height: "100%",
                    alignSelf: windowState.isAboveCursor
                      ? "flex-end"
                      : "flex-start",
                    maxHeight: listMaxHeight,
                  }
                : {}
            }
          >
            <AutoSizedList
              className={listClasses.filter((x) => !!x).join(" ")}
              onResize={scrollToItemCallback}
              ref={listRef}
              itemSize={size.itemSize}
              width="100%"
              itemCount={Math.round(suggestions.length)}
            >
              {({ index, style }) => (
                <Suggestion
                  index={index}
                  total={suggestions.length}
                  style={style}
                  suggestion={suggestions[index]}
                  commonPrefix={commonPrefix || ""}
                  onClick={insertTextForItem}
                  isActive={selectedIndex === index}
                  searchTerm={searchTerm}
                  fuzzySearchEnabled={fuzzySearchEnabled}
                  iconPath={iconPath}
                  iconSize={size.itemSize * 0.75}
                />
              )}
            </AutoSizedList>
            <div className="scrollbar-none flex flex-shrink-0 flex-row">
              {descriptionPosition === "unknown" && description}
              {isLoading && (
                <LoadingIcon
                  className={
                    hasSuggestions
                      ? "left-[2px] [&>*]:top-[calc(50%-5px)]"
                      : "left-[2px] [&>*]:top-[calc(50%-3px)]"
                  }
                />
              )}
            </div>
          </div>
          {descriptionPosition === "right" && description}
        </div>
        {!windowState.isAboveCursor && devModeWarning}
      </>
    );
  }

  return (
    <div
      ref={autocompleteWindowRef}
      id="autocompleteWindow"
      className="relative flex flex-col overflow-hidden"
    >
      {contents}
      <span className="sr-only" role="status" aria-live="polite" aria-atomic="true">
        {suggestions[selectedIndex] ? `${selectedIndex + 1} of ${suggestions.length}: ${suggestions[selectedIndex].description ?? ""}` : ""}
      </span>
    </div>
  );
}

export default App;
