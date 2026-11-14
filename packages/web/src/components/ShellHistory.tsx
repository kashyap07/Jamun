import { useCallback, useEffect, useRef, MutableRefObject } from "react";
import AutoSizedList, { AutoSizedHandleRef } from "./AutoSizedList";
import type { HistoryEntry } from "../shellHistory";

type ShellHistoryProps = {
  entries: HistoryEntry[];
  selectedIndex: number;
  itemSize: number;
  width: number;
  maxRows: number;
  onPick: (entry: HistoryEntry) => void;
};

// One row per command, so a multi-line command is shown folded.
const oneLine = (command: string) => command.replace(/\s*\n\s*/g, " ↵ ");

const ShellHistory = ({
  entries,
  selectedIndex,
  itemSize,
  width,
  maxRows,
  onPick,
}: ShellHistoryProps) => {
  const listRef =
    useRef<AutoSizedHandleRef>() as MutableRefObject<AutoSizedHandleRef>;
  const scrollToSelected = useCallback(() => {
    listRef.current?.scrollToItem(selectedIndex);
  }, [selectedIndex]);
  useEffect(scrollToSelected, [scrollToSelected, entries]);
  // A zsh history file without EXTENDED_HISTORY has no times to show.
  const showTime = entries.some((entry) => entry.when);

  return (
    <div className="flex flex-row py-1">
      <div
        className="relative flex flex-none flex-col items-stretch overflow-hidden"
        style={{ width, maxHeight: itemSize * (maxRows + 1) }}
      >
        {entries.length > 0 ? (
          <AutoSizedList
            className="rounded rounded-b-none"
            onResize={scrollToSelected}
            ref={listRef}
            itemSize={itemSize}
            width="100%"
            itemCount={entries.length}
          >
            {({ index, style }) => {
              const entry = entries[index];
              const isActive = index === selectedIndex;
              return (
                <div
                  style={style}
                  className={`flex items-center overflow-hidden pl-2.5 pr-2 ${
                    isActive ? "bg-selected-bg/90 [clip-path:inset(0.5px_4px_round_8px)]" : ""
                  }`}
                  id={`history-${index}`}
                  role="option"
                  aria-selected={isActive}
                  aria-posinset={index + 1}
                  aria-setsize={entries.length}
                  aria-label={entry.when ? `${entry.command}. ${entry.when} ago` : entry.command}
                  onClick={() => onPick(entry)}
                >
                  {showTime && (
                    <span
                      className="text data-[active-item]:text-selected-text mr-3 flex-none whitespace-nowrap text-right opacity-50"
                      style={{ width: "7ch" }}
                      data-active-item={isActive ? true : undefined}
                    >
                      {entry.when ? `${entry.when} ago` : ""}
                    </span>
                  )}
                  <span
                    className="text data-[active-item]:text-selected-text min-w-0 truncate whitespace-nowrap"
                    data-active-item={isActive ? true : undefined}
                  >
                    {oneLine(entry.command)}
                  </span>
                </div>
              );
            }}
          </AutoSizedList>
        ) : (
          <div
            className="text flex items-center px-3 opacity-60"
            style={{ height: itemSize }}
          >
            No matching history
          </div>
        )}
        <div className="scrollbar-none flex flex-shrink-0 flex-row">
          <div
            id="description"
            className="withSuggestions"
            style={{ height: itemSize }}
          >
            <span className="whitespace-nowrap">History</span>
            <span className="whitespace-nowrap">↵ run · ⇥ edit · esc close</span>
          </div>
        </div>
      </div>
    </div>
  );
};

export default ShellHistory;
