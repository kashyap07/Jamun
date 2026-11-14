import { Process } from "@jamun/api-bindings";

export type HistoryEntry = {
  command: string;
  /** atuin's relative time, e.g. "5m" or "2d" */
  when: string;
};

const LIMIT = 200;
const FORMAT = "{relativetime}\t{command}";
// atuin refuses to run without a session id; global search never reads it.
const ENVIRONMENT = { ATUIN_SESSION: "jamun" };

/** Entries arrive NUL separated, oldest first, the best match last. */
export const parseAtuinOutput = (stdout: string): HistoryEntry[] =>
  stdout
    .split("\0")
    .map((record) => {
      const tab = record.indexOf("\t");
      return tab === -1
        ? { when: "", command: record }
        : { when: record.slice(0, tab), command: record.slice(tab + 1) };
    })
    .filter((entry) => entry.command.trim() !== "");

/**
 * Same search as atuin's own interface: fuzzy, across all history.
 * Rejects when atuin cannot be run; no match is an empty list.
 */
export async function searchAtuin(
  query: string,
  sessionId: string,
): Promise<HistoryEntry[]> {
  const { exitCode, stdout, stderr } = await Process.run({
    executable: "atuin",
    args: [
      "search", "--search-mode", "fuzzy", "--filter-mode", "global",
      "--limit", String(LIMIT), "--print0", "--format", FORMAT, "--", query,
    ],
    environment: ENVIRONMENT,
    terminalSessionId: sessionId,
    timeout: 3000,
  });
  // atuin exits 1 without output when nothing matches.
  if (exitCode !== 0 && (stdout || stderr.trim())) {
    throw new Error(`atuin search failed (${exitCode})`);
  }
  if (exitCode !== 0 && exitCode !== 1) throw new Error(`atuin search failed (${exitCode})`);
  return parseAtuinOutput(stdout);
}

export async function isAtuinInstalled(sessionId: string): Promise<boolean> {
  try {
    const { exitCode } = await Process.run({
      executable: "atuin", args: ["--version"], environment: ENVIRONMENT,
      terminalSessionId: sessionId, timeout: 3000,
    });
    return exitCode === 0;
  } catch {
    return false;
  }
}
