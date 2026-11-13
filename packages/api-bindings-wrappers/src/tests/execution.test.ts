import { beforeEach, expect, it, vi } from "vitest";
import { Process } from "@jamun/api-bindings";
import { executeCommandTimeout } from "../executeCommand";
import { executeLoginShell } from "../executeCommandWrappers";
vi.mock("@jamun/api-bindings", () => ({ Process: { run: vi.fn() } }));
beforeEach(() => {
  window.fig = { constants: { os: "macos" } } as typeof window.fig;
  window.f = {} as typeof window.f;
  vi.mocked(Process.run).mockResolvedValue({ exitCode: 0, stdout: "ABCDEFGHIJKLMNO", stderr: "" });
});
it("preserves output when no legacy marker exists", async () => {
  expect(await executeLoginShell({ command: "test", executable: "/bin/zsh" })).toBe("ABCDEFGHIJKLMNO");
});
it("removes startup output through the last marker", async () => {
  vi.mocked(Process.run).mockResolvedValueOnce({ exitCode: 0, stdout: "noise\x1b]697;DoneSourcing\x07result", stderr: "" });
  expect(await executeLoginShell({ command: "test", executable: "/bin/zsh" })).toBe("result");
});
it("forwards the effective script timeout and owning session", async () => {
  await executeCommandTimeout({ command: "example", args: [] }, 15000, "session-A");
  expect(Process.run).toHaveBeenLastCalledWith(expect.objectContaining({ timeout: 15000, terminalSessionId: "session-A" }));
});
