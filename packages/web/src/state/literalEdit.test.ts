import { execFileSync } from "node:child_process";
import { describe, expect, it } from "vitest";
import { literalReplacement, quoteLiteral, scalarLength } from "./literalEdit";

const decode = (argument: string) => execFileSync("/bin/zsh", ["-dfc", `print -rn -- ${argument}`], { encoding: "utf8" });
describe("literal completion arguments", () => {
  it.each(["normal.txt", "a b c.txt", "x; printf INJECTED", "$(printf INJECTED)", "`printf INJECTED`", "a'b\"c", "last\n", "🍇é.txt", "a\\b", "-rf", ""])('round-trips %j without executing syntax', (value) => {
    expect(decode(quoteLiteral(value))).toBe(value);
  });
  it.each([
    ["🍇", "🍇", "abc🍇.txt"],
    ["a\\ b\\ c", "a b c", "a b c.txt"],
    ['"a b"', "a b", "a $b.txt"],
    ["'it's", "its", "x'y"],
    ["dir/a\\ b", "a b", "a b.txt"],
    ["--file=a", "a", "a;bad"],
    ["\"dir/\"a", "a", "a\n"],
  ])("replaces the original source span: %s", (raw, query, value) => {
    const { deletion, insertion } = literalReplacement(raw, query, value, true);
    const prefix = Array.from(raw).slice(0, scalarLength(raw) - deletion).join("");
    const expectedPrefix = raw.startsWith("dir/") || raw.includes('dir/') ? "dir/" : raw.startsWith("--file=") ? "--file=" : "";
    expect(decode(prefix + insertion)).toBe(expectedPrefix + value);
  });
  it("protects option-looking filenames and rejects stale spans/NUL", () => {
    expect(literalReplacement("-", "-", "-rf", true).insertion).toBe("./-rf");
    expect(() => literalReplacement("abc", "xyz", "anything")).toThrow();
    expect(() => quoteLiteral("a\0b")).toThrow();
  });
});
