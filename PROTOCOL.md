Jamun shell and web bridge protocol v2

- Transport: per-user Unix socket, mode 0600, directory created with mode 0700, same-UID peers only, one socket owner protected by a lifetime lock.
- Framing: shell → host JSON object followed by newline; host → shell tab-separated fields followed by newline. Control characters inside JSON are escaped.
- Text fields in insert frames carry a `v` prefix and backslash escapes for tab/newline/carriage-return/backslash, preserving empty fields.
- Limits: 512 KiB per incoming frame/output queue, 64 socket connections, 32,768 shell characters before completion disconnects for that prompt.
- zsh and native edit positions count Unicode scalars. React/parser positions count UTF-16 units and are converted at the bridge boundary.

| Shell event | Required fields | Meaning |
|---|---|---|
| `hello` | `version: 2`, `sid`, `pid`, `tty`, `shell` | Establish the connection's unique session |
| `prompt` | `cwd`, `environment`, `aliases` | Update allowlisted context without copying credentials |
| `edit` | `buf`, `cur`, increasing `rev`, `cwd` | Publish the current editor snapshot |
| `finish` | `rev` | Leave the prompt and cancel session generators |
| `key` | `key`, `keyId`, `rev` | Open a key transaction |
| `editAck` | `requestId`, `accepted` | Acknowledge shell-side validation and application |

| Host frame | Fields after its name |
|---|---|
| `hello` | negotiated protocol version (`2`); required before capturing keys |
| `keys` | comma-separated supported key names |
| `done` | key transaction ID, handled flag |
| `resync` | none; request a new edit snapshot |
| `insert` | request ID, key ID (`0` for clicks), revision, scalar cursor, expiry epoch milliseconds, scalar deletion, scalar move-left, explicit execute flag, prefixed escaped expected buffer, prefixed escaped insertion |

- Before applying an edit, zsh checks revision, complete buffer, cursor, key transaction, expiry, and edit bounds. Native validation is performed too, but does not substitute for the shell's final check.
- A 300 ms key deadline restores ordinary bindings and closes the connection before replaying an unapplied key. Late replies cannot modify the buffer afterward. An already-applied edit suppresses duplicate replay.
- Insert requests expire after 1.5 seconds; the host rejects an unacknowledged request after two seconds.
- Explicit unknown sessions are rejected rather than redirected to the active terminal.

Web messages include `protocol: 2`, `id`, `method`, and `params`. Requests have bounded lifetimes; `id: 0` is a notification. Native replies are `{ id, ok, result }` or `{ id, ok: false, error }`.

- Only the main `jamun://app` frame may use the native bridge. Navigation and subframes are restricted.
- `bridge.ready` is sent after subscriptions mount. The host replays the active buffer and requests shell resynchronization.
- Page generations isolate replies and cancellation IDs across reloads. Closing/reloading a page clears interception, rejects pending edits, and cancels processes.
- `shell.insert` carries a structured edit and expected snapshot. Literal text is never interpreted as backspaces, cursor escapes, or an execution newline.
- `process.run` carries a deadline; `process.cancel` cancels the corresponding request in the current page generation. Session changes and popup closure also cancel owned work.
- `spec.read` uses the native explicit developer-directory trust policy. Ordinary file reads do not authorize executing their contents.
- Common error codes: `protocol_mismatch`, `unknown_session`, `stale_or_invalid_edit`, `stale_edit`, `edit_timeout`, `popup_reset`, `process_timeout`, `process_cancelled`, `process_output_limit`, `process_queue_full`, `local_spec_not_trusted`, `settings_write_failed`.
