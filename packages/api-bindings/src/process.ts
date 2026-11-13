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
  return request<RunProcessResponse>("process.run", {
    executable,
    args,
    environment: environment ?? {},
    workingDirectory,
    sessionId: terminalSessionId,
    timeout,
  });
}
