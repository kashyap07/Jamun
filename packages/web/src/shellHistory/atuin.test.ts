import { expect, it } from "vitest";
import { parseAtuinOutput } from "./atuin";

it("parses NUL separated atuin records, keeping multi-line commands whole", () => {
  expect(parseAtuinOutput("2d\tgit log\x001h\tfor x in a b; do\n  echo $x\ndone\x005m\tprintf 'a\\tb'\x00")).toEqual([
    { when: "2d", command: "git log" },
    { when: "1h", command: "for x in a b; do\n  echo $x\ndone" },
    { when: "5m", command: "printf 'a\\tb'" },
  ]);
  expect(parseAtuinOutput("")).toEqual([]);
});
