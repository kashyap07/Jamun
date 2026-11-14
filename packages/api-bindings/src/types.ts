export interface EnvironmentVariable {
  key: string;
  value?: string;
}

export interface ShellContext {
  /** The current PID of the shell process */
  pid?: number;
  /** /dev/ttys## of terminal session */
  ttys?: string;
  /** the name of the process */
  processName?: string;
  /** the directory where the user ran the command */
  currentWorkingDirectory?: string;
  /** unique id of the shell session */
  sessionId?: string;
  integrationVersion?: number;
  /** optional protocol features of the shell script, e.g. "replace" */
  capabilities?: string[];
  /** the shell's $HISTFILE, when it reported one */
  historyFile?: string;
  revision?: number;
  terminal?: string;
  hostname?: string;
  /** path to the shell being used in the terminal */
  shellPath?: string;
  /** exported environment variables of the shell */
  environmentVariables?: EnvironmentVariable[];
  /** the raw output of alias */
  alias?: string;
  aliases?: Record<string, string>;
}
