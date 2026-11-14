import fuzzysort from "@jamun/fuzzysort";
import { Process } from "@jamun/api-bindings";
import type { HistoryEntry } from "./atuin";

const MAX_EVENTS = 10000;
const LIMIT = 200;
// zsh reads its own history file, so its escaping of multi-line and
// non-ASCII commands is undone correctly. Prints "<epoch>\t<command>\0".
// Terminal.app points $HISTFILE at a per-window file that starts empty and
// is merged into ~/.zsh_history on exit, so both are read.
const SCRIPT = [
  "HISTSIZE=$1; shared=$HOME/.zsh_history; zmodload zsh/parameter",
  "[[ -r $shared ]] && fc -R -- $shared 2>/dev/null",
  '[[ -n $2 && $2 != $shared && -r $2 ]] && fc -R -- "$2" 2>/dev/null',
  "fc -l -t %s 1 2>/dev/null | while read -r num ts rest; do",
  `  print -rn -- "$ts"$'\\t'"$history[$num]"$'\\0'`,
  "done",
].join("\n");

export type DatedCommand = { command: string; time: number };

const UNITS: [string, number][] = [
  ["y", 31536000], ["mo", 2592000], ["d", 86400], ["h", 3600], ["m", 60], ["s", 1],
];

/** Same short form atuin prints: "5m", "2d", "3mo". */
export const relativeTime = (seconds: number): string => {
  for (const [unit, size] of UNITS) {
    if (seconds >= size) return `${Math.floor(seconds / size)}${unit}`;
  }
  return "0s";
};

/** Oldest first, each command once, at its most recent use. */
export const parseZshHistory = (stdout: string, now: number): DatedCommand[] => {
  const latest = new Map<string, number>();
  for (const record of stdout.split("\0")) {
    const tab = record.indexOf("\t");
    if (tab === -1) continue;
    const command = record.slice(tab + 1);
    if (!command.trim()) continue;
    const stamp = Number(record.slice(0, tab));
    // Without EXTENDED_HISTORY the file has no times and zsh reports the
    // moment it read the file. Those entries are shown without a time.
    const time = Number.isFinite(stamp) && stamp > 0 && stamp < now - 5 ? stamp : 0;
    latest.delete(command);
    latest.set(command, time);
  }
  return [...latest].map(([command, time]) => ({ command, time }));
};

/** Fuzzy filter. Result is in list order: the best or newest entry last. */
export const filterZshHistory = (
  all: DatedCommand[],
  query: string,
  now: number,
): HistoryEntry[] => {
  // Every word must match somewhere, as in atuin's fuzzy search. Ties keep
  // their order, so the more recent command ends up nearer the prompt.
  const terms = query.split(/\s+/).filter(Boolean);
  const picked = terms.length
    ? all
        .map((entry) => {
          let score = 0;
          for (const term of terms) {
            const match = fuzzysort.single(term, entry.command);
            if (!match) return undefined;
            score += match.score;
          }
          return { entry, score };
        })
        .filter((scored) => scored !== undefined)
        .sort((x, y) => x.score - y.score)
        .slice(-LIMIT)
        .map((scored) => scored.entry)
    : all.slice(-LIMIT);
  return picked.map(({ command, time }) => ({
    command,
    when: time ? relativeTime(Math.max(0, now - time)) : "",
  }));
};

export async function loadZshHistory(
  sessionId: string,
  historyFile: string | undefined,
): Promise<DatedCommand[]> {
  const { exitCode, stdout } = await Process.run({
    executable: "/bin/zsh",
    args: ["-fc", SCRIPT, "jamun", String(MAX_EVENTS), historyFile ?? ""],
    terminalSessionId: sessionId,
    timeout: 3000,
  });
  if (exitCode !== 0) throw new Error(`could not read zsh history (${exitCode})`);
  return parseZshHistory(stdout, Date.now() / 1000);
}
