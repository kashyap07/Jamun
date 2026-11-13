Jamun adds a completion popup to macOS terminals using a Swift host, zsh widgets, and a React completion engine adapted from Fig.

- Supported: macOS 13+, interactive zsh 5.9, local terminal sessions in Terminal.app and xterm.js based terminals such as VS Code. The host accepts whichever app owns the shell process and needs that app to expose the caret through Accessibility.
- Building the Liquid Glass code requires a macOS 26+ SDK; older supported macOS versions use the material fallback.
- iTerm2, Warp, remote SSH shells, and arbitrary terminal emulators are not currently supported.
- This revision uses shell/bridge protocol v2. Restart old shells after installing the updated integration.
- See IMPLEMENTATION_STATUS.md for validation results and remaining manual checks.

Development and installation:

1. Install Node.js 22.16+ and an Xcode toolchain with the required SDK.
2. Install dependencies with `npm ci`.
3. Build the app with `npm run build`. The resulting `build/Jamun.app` contains the web UI, completion specs, icons, shell script, and license notices; it does not depend on the checkout at runtime.
4. Copy `Jamun.app` to Applications and open it.
5. Use the Jamun menu → **Set Up Shell Integration…**. This copies the bundled script to `~/.jamun/jamun.zsh` and adds a marked block to `.zshrc`. Existing configuration is preserved; a backup is saved before changes.
6. Grant Accessibility access using **Open Accessibility Settings**, then open a new Terminal window.
7. Use **Show Diagnostics…** if suggestions do not appear.

- If zsh uses a custom `ZDOTDIR`, ensure the host receives that value before using the installer, or add this line to your actual zshrc manually: `[[ -r "$HOME/.jamun/jamun.zsh" ]] && source "$HOME/.jamun/jamun.zsh"`.
- A rebuild no longer rewrites live shell resources. Run **Set Up Shell Integration…** again when the bundled integration changes.
- For local development only, `JAMUN_WEB_DIR` can point the host at a built web directory.
- The unsigned development build uses a discovered Apple Development identity when available, otherwise ad-hoc signing. Ad-hoc rebuilds may require granting Accessibility access again.

| Control | Default behavior |
|---|---|
| Tab | Insert common prefix; show suggestions when Tab-only mode is enabled |
| Enter | Accept the selected completion |
| Up / Down, Ctrl+P / Ctrl+N | Navigate suggestions |
| Shift+Tab | Navigate upward |
| Escape | Hide suggestions |
| Ctrl+K | Toggle the description |
| Ctrl+R | Toggle history suggestions while the popup is active |
| Menu → Enable Autocomplete | Pause/resume completion and key interception |
| Menu → Reload Autocomplete | Reload the popup, cancel generators, and replay the active buffer |

- Normal shell bindings are restored when interception stops. A host timeout disconnects the integration and returns the key to zsh unless the edit already succeeded.
- Command-number shortcuts are not advertised because Terminal does not forward those key combinations to this integration. Selection actions can be assigned to supported keys.
- Completion data is quoted as shell arguments. Execution is an explicit operation, never inferred from a filename's trailing newline.
- Completion edits require a matching session, buffer, cursor, revision, and deadline. Stale replies are rejected.

Settings live in `~/.jamun/settings.json` using the existing `autocomplete.*` keys. Example:

```json
{
  "autocomplete.onlyShowOnTab": true,
  "autocomplete.fontSize": 14,
  "autocomplete.width": 360,
  "autocomplete.keybindings.enter": "insertSelected",
  "autocomplete.keybindings.tab": "insertCommonPrefix",
  "autocomplete.history.disableLoading": false
}
```

- Reload autocomplete after editing the file externally. Invalid JSON is not overwritten by settings updates.
- Project `.fig` JavaScript is disabled by default. To develop specs, use **Trust Developer Specs Folder…** and select a folder you control. The explicit trust includes future edits within that folder. Use **Disable Developer Specs** to revoke access and reload the execution context.
- Trusted completion specs and their generators run with your account's privileges. This is not a sandbox for hostile JavaScript. Untrusted project paths and HTTP developer modules cannot load automatically.
- The host passes a documented allowlist of context variables, including PATH, locale, selected cloud profile/region, KUBECONFIG, and virtual-environment paths. It does not copy arbitrary credentials from the shell environment. Generators can still use your tools' normal credential/config files.

Diagnostics and limits:

- Menu diagnostics show host connectivity, shell installation, Accessibility status, bundled resources, popup health, recent p50/p95 timings, and failure counters.
- Timing samples and counters contain no command buffers, arguments, environments, or filenames.
- Host logs rotate at approximately 1 MiB with one previous file under `~/Library/Logs/Jamun`.
- `~/.jamun/debug` enables verbose diagnostics and Web Inspector at launch. Verbose messages from trusted specs may contain command details; remove the file and restart to disable them.
- Generator work is capped at four active processes and 36 total queued/active requests, 2 MiB combined output per process, and 120 seconds maximum deadline. Cancellation terminates the owned process group and escalates to SIGKILL.
- Socket frames/output queues are bounded. Very large pasted buffers disable completion for that prompt rather than delaying the editor.
- Reduced motion, reduced transparency, higher contrast, listbox/option semantics, and selected-item announcements are implemented; live VoiceOver and multi-display acceptance checks remain manual.

Verification commands:

| Command | Purpose |
|---|---|
| `npm run check` | JS tests, TypeScript, real-zsh/PTY tests and native runtime checks |
| `npm run test:package` | Relocated bundle resources, signature and production WebKit UI |
| `npm run typecheck` | TypeScript checks |
| `npm run build:web` | Production web build |
| `swift build --package-path host` | Native compilation |
| `zsh -n shell/jamun.zsh` | Shell syntax |
| `npm audit` / `npm audit --omit=dev` | Dependency advisories |

- Regression coverage includes JS, zsh, native process, socket, and WebKit behavior. See the implementation status for what has been exercised.
- Existing TODO tests are not counted as passing coverage.
- The acceptance matrix includes special filenames, quotes, emoji/combining text, cursor edits, session switching, popup reload/crash, slow generators, deadline cancellation, keybinding restoration, clean installation, Accessibility, VoiceOver, multiple displays, and Spaces.

Distribution:

1. Set `JAMUN_RELEASE=1` and `JAMUN_SIGN_IDENTITY` to a Developer ID Application identity, then build.
2. Configure an Apple notarytool keychain profile outside the repository.
3. Set `JAMUN_NOTARY_PROFILE` and explicitly run `scripts/notarize.sh` to submit and staple the app.
4. Complete the clean-machine acceptance checks before publishing. Validation builds use ad-hoc signing. No notarization, submission, or publication was performed.

Uninstall:

1. Use **Remove Shell Integration…** and quit Jamun.
2. Restart existing terminal sessions; remove any manually added source lines if they were not installed using Jamun's marked block.
3. Delete the application. Settings, backups, and logs are retained unless you explicitly remove them.
4. Existing legacy `~/.jamun/specs` and `~/.jamun/icons` symlinks are unused and may be removed separately.

See [upstream notices](THIRD_PARTY_NOTICES.md), [original audit](JAMUN_REVIEW.md), and [protocol reference](PROTOCOL.md).

- Use `JAMUN_BUILD_DIR="$PWD/build/validation" JAMUN_SIGN_IDENTITY=- npm run build` for an isolated validation bundle.
- Native tests use a standalone Swift harness so Command Line Tools installations do not need XCTest.
- CI runs on the macOS 26 image; runner details: https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md.
