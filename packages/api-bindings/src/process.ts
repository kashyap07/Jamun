import { request } from "./bridge.js";

export type RunProcessResponse = {
  exitCode: number;
  stdout: string;
  stderr: string;
};

export async function run({
  executable,
  args,
  environment,
  workingDirectory,
  terminalSessionId,
  timeout,
}: {
  executable: string;
  args: string[];
  environment?: Record<string, string | undefined>;
  workingDirectory?: string;
  terminalSessionId?: string;
  /** milliseconds */
  timeout?: number;
}) {
  const deadline = Number.isFinite(timeout) ? Math.min(120000, Math.max(50, timeout!)) : 5000;
  return request<RunProcessResponse>("process.run", {
    executable,
    args,
    environment: environment ?? {},
    workingDirectory,
    sessionId: terminalSessionId || undefined,
    timeout: deadline,
  }, deadline + 1000);
}
