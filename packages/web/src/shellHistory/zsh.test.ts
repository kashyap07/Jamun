import { expect, it } from "vitest";
import { filterZshHistory, parseZshHistory, relativeTime } from "./zsh";

const NOW = 1_800_000_000;
const record = (ago: number, command: string) => `${NOW - ago}\t${command}\0`;

it("keeps each command once at its latest use, and drops times zsh made up", () => {
  const all = parseZshHistory(
    record(7200, "git status") + record(600, "for x in a; do\n  echo $x\ndone") + record(60, "git status") + record(0, "no time"),
    NOW,
  );
  expect(all).toEqual([
    { command: "for x in a; do\n  echo $x\ndone", time: NOW - 600 },
    { command: "git status", time: NOW - 60 },
    { command: "no time", time: 0 },
  ]);
  expect(filterZshHistory(all, "", NOW).map((e) => [e.when, e.command])).toEqual([
    ["10m", "for x in a; do\n  echo $x\ndone"], ["1m", "git status"], ["", "no time"],
  ]);
});

it("fuzzy matches with the best match last, nearest the prompt", () => {
  const all = parseZshHistory(record(900, "git push origin main") + record(500, "ls -la") + record(100, "gh pr status"), NOW);
  const found = filterZshHistory(all, "gst", NOW).map((e) => e.command);
  expect(found).not.toContain("ls -la");
  expect(found.at(-1)).toBe("gh pr status");
  expect(filterZshHistory(all, "git push", NOW).map((e) => e.command)).toEqual(["git push origin main"]);
  expect(filterZshHistory(all, "zzzz", NOW)).toEqual([]);
});

it("prints short relative times like atuin", () => {
  expect([5, 90, 7200, 172800, 5184000, 63072000].map(relativeTime)).toEqual(["5s", "1m", "2h", "2d", "2mo", "2y"]);
});
