> Historical audit of the pre-fix revision. Source changes are tracked in [implementation status](IMPLEMENTATION_STATUS.md). Earlier reproduction results below do not validate the new code. The authorized verification results and remaining manual checks are recorded in the implementation status.

Review of Jamun — 13 November 2026

- **Assessment:** the basic architecture works, but I would fix the command-safety and shell-integration issues below before distributing it or relying on it in unfamiliar repositories.
- **Snapshot:** `16b0ca70aae066c56081bdc4d3c483ce40990f6c`.
- **Scope:** Swift host, zsh integration, native bridge, spec loading, insertion, generators, state, settings, packaging, dependencies, and existing tests.
- **Changes made:** this review document only; application source is unchanged. Builds regenerated ignored build outputs. Reproduction harnesses are under `/tmp/jamun-audit`.
- **Evidence labels:** “reproduced” means an isolated test exercised the relevant implementation; “code-confirmed” means the behavior follows from inspected code but was not exercised in a live Terminal session.
- **Limits:** the WebKit smoke test used the real production web bundle and local spec handler, with mocked native requests. It did not exercise Accessibility permissions, live caret tracking, native glass appearance, multiple displays, Spaces, or another Mac. The packaging/signing script was inspected, not executed.

Validation results:

| Check | Result |
|---|---|
| `npm run typecheck` | Passed |
| `npm run build:web` | Passed; JS bundle 428.54 kB, 137.13 kB gzip |
| `swift build --package-path host` | Passed |
| `zsh -n shell/jamun.zsh` | Passed |
| `npm test` | Failed: 10 suites fail during loading; 103 tests pass |
| `npm test -- --environment jsdom` | 174 passed, 108 TODO; 12 suites pass, 2 skipped |
| Isolated WKWebView, production bundle | Rendered Git suggestions for `git co`; no captured JS errors |
| Session switch in WKWebView | Reproduced missing key-interception update |
| Local spec import in WKWebView | Reproduced JavaScript execution and a native process request; request was mocked, not executed |
| JS and zsh reproduction harnesses | Confirmed escaping, Tab binding, text deletion, cache recovery, hidden-key policy, shell context, and output-trimming bugs |
| Native process harness | Confirmed a SIGTERM-ignoring process exceeds its deadline |
| `npm audit` | 4 affected package entries: 2 critical, 1 high, 1 moderate |
| `npm audit --omit=dev` | 1 high entry: Zod |

Prioritized findings:

1. **P1 — Filename completion can insert executable shell syntax. Reproduced.**
   - [insertion.ts:151](packages/web/src/state/insertion.ts#L151) omits semicolons, dollar signs, backticks, tabs, and newlines from its quoting decision.
   - A file suggestion named `report;uname` is inserted unchanged. Evaluating the resulting argument in isolated zsh printed `report` and then `Darwin`: the second command ran. `invoice` followed by backtick-quoted `uname` became `invoiceDarwin.txt` instead of the literal filename.
   - The semicolon/backtick cases execute when the resulting command is run; listing the file alone does not execute them. Separately, a `trailing\n` filename suggestion produced `insertion: "trailing", immediate: true` in the real insertion/bridge code: accepting that completion requests immediate execution.
   - **Fix:** use a shell-aware literal-token serializer for filenames and other data; preserve quote context; keep execution and cursor movement as separate structured fields. Apply equivalent escaping to common-prefix insertion. Test every shell metacharacter, control character, and leading dash.

2. **P1 — Project-local completion specs execute without a trust decision. Reproduced.**
   - [loadSpec.ts:153](packages/autocomplete-parser/src/loadSpec.ts#L153) loads project `.fig/autocomplete/build/*.js` outside developer mode. [loadHelpers.ts:38](packages/autocomplete-parser/src/loadHelpers.ts#L38) imports those contents as executable JavaScript in the popup.
   - Typing a local command such as `./tool ` can lead to this import before the user executes the command. The script shares access to the native bridge, which exposes process execution and filesystem writes.
   - The WebKit harness resolved `/tmp/untrusted-audit/.fig/autocomplete/build/tool.js`, imported mock contents through the real loader, and recorded the script requesting `process.run`. No native command from that spec was executed during the test.
   - **Fix:** disable automatic project-local code loading by default, or require trust for the canonical project path and invalidate trust when relevant code changes. Separate data-only specs from executable generators. Restrict bridge capabilities for untrusted code.
   - **Related hardening:** [PopupPanel.swift:184](host/Sources/JamunHost/PopupPanel.swift#L184) does not validate the sending frame/origin, and navigation is not restricted to the application. Add both checks; they do not replace project trust because project specs already run in the application context.

3. **P1 — Stale completions can modify the wrong buffer or session. Code-confirmed.**
   - The web app sends `insertionBuffer`, but [AppDelegate.swift:345](host/Sources/JamunHost/AppDelegate.swift#L345) discards it and forwards deletion/insertion unconditionally.
   - [AppDelegate.swift:300](host/Sources/JamunHost/AppDelegate.swift#L300) falls back to the active session even when the request explicitly names a session that no longer exists.
   - A delayed completion after further typing, cursor movement, or session closure can therefore apply to text it was not calculated for. The same path permits immediate execution.
   - **Fix:** attach session ID, buffer revision, cursor position, and request ID to every edit. Reject unknown explicit sessions. Have the zsh widget validate the revision/buffer before applying the edit and acknowledge success or rejection. Native validation alone cannot cover typing that has not reached the host yet.

4. **P2 — Tab is never rebound to Jamun. Reproduced.**
   - [jamun.zsh:116](shell/jamun.zsh#L116) uses whitespace splitting on each key's escape sequences. Tab is itself an IFS whitespace character, so its sequence disappears.
   - After `_jamun_set_keys tab up enter`, Tab remained `expand-or-complete`; Up and Enter correctly became Jamun widgets.
   - **Fix:** represent sequences without whitespace splitting, or use an explicit delimiter that preserves literal Tab. Add a real zsh keymap regression test.

5. **P2 — Switching terminal sessions can leave key interception attached to the old session. Reproduced.**
   - [App.tsx:253](packages/web/src/App.tsx#L253) excludes the session ID from the interception effect's dependencies and does not clear the previous session on cleanup.
   - In the production-bundle WebKit test, session A received bindings for `git co`. Switching to session B with the same buffer produced **zero** interception requests for B.
   - **Fix:** include session ID and binding configuration in the dependencies; clear old-session interception before installing new-session bindings. Track bindings per session rather than in one global key map.

6. **P2 — A slow or unresponsive popup silently consumes keys. Reproduced.**
   - [jamun.zsh:132](shell/jamun.zsh#L132) replays a key only if sending fails. If the send succeeds but no `done` arrives within 300 ms, it returns without replaying the key or disabling interception.
   - An isolated delayed-response test confirmed that the timeout path invokes no fallback widget. Enter, arrows, and other intercepted keys can disappear during a WebKit stall.
   - **Fix:** use acknowledged key transactions with request IDs, safe fallback, and cancellation of late replies. Restore normal bindings when the host is unhealthy. Do not simply replay while allowing a late insertion to remain valid.

7. **P2 — Completion replacement corrupts Unicode and escaped-space input. Reproduced.**
   - [insertion.ts:43](packages/web/src/state/insertion.ts#L43) and [insertion.ts:56](packages/web/src/state/insertion.ts#L56) count JavaScript UTF-16 units and reconstruct deletion length from a decoded search term. zsh deletes characters, and only the first whitespace character receives an extra escape count.
   - Replacing the fuzzy query `🍇` in `cat 🍇` with `abc🍇.txt` produced `catabc🍇.txt`: the separating space was also deleted.
   - Completing `cat a\ b\ c` to `a b c.txt` produced `cat aa\ b\ c.txt`.
   - **Fix:** derive replacement spans from the original token source, account for quoting, and define one explicit character-index convention across JS, Swift, and zsh. Convert at the boundary. Test emoji, combining characters, quoted arguments, multiple spaces, and cursor-in-the-middle edits.

8. **P2 — One generator failure permanently poisons its cache entry. Reproduced.**
   - [cache.ts:14](packages/web/src/generators/cache.ts#L14) clears `this.promise` only after successful resolution. Rejection leaves the rejected promise installed.
   - A failed fetch followed by a successful retry callback invoked the underlying callback only once; the second request reused the original rejection.
   - **Fix:** clear in-flight state in `finally`, define whether stale successful values should survive failure, and allow a bounded retry. Test failure → recovery and simultaneous callers.

9. **P2 — Shell identity is not connected to command/history completion. Reproduced at the state/generator boundary.**
   - [fig/hooks.ts:105](packages/web/src/fig/hooks.ts#L105) copies shell context but does not populate `processUserIsIn`. That field changes only on a `process` event; the Swift host never emits that event.
   - [generators.ts:21](packages/web/src/state/generators.ts#L21) consequently supplies an empty `currentProcess`.
   - With `/bin/zsh` present in shell context and first-command completion enabled, the first-token generator returned `[]`. Shell-specific history lookup also selects sources using this missing value.
   - **Fix:** derive shell identity directly from the edit-buffer context or implement the process notification contract consistently. Add end-to-end checks for command-name and history suggestions.

10. **P2 — Login-shell output is truncated when a legacy Fig marker is absent. Reproduced.**
    - [executeCommandWrappers.ts:86](packages/api-bindings-wrappers/src/executeCommandWrappers.ts#L86) adds the marker length to `lastIndexOf(...)` even when it returns `-1`.
    - Jamun's zsh integration does not emit that marker. A mock successful result of `ABCDEFGHIJKLMNO` became an empty string.
    - **Fix:** trim only when the marker exists. Prefer a Jamun-owned request delimiter if startup output must be separated from command output. Test marker present, absent, and repeated.

11. **P2 — Process deadlines are inconsistent and are not a hard bound. Reproduced and code-confirmed.**
    - [ProcessRunner.swift:52](host/Sources/JamunHost/ProcessRunner.swift#L52) sends SIGTERM once, then continues waiting for output and process exit. It has no escalation or output-size limit.
    - The native harness gave a SIGTERM-ignoring process a 100 ms timeout; it completed successfully after approximately 1.09 seconds instead. An indefinitely running equivalent would remain alive.
    - Separately, [executeCommand.ts:27](packages/api-bindings-wrappers/src/executeCommand.ts#L27) computes an effective JS timeout but forwards only `input.timeout`. A spec's longer `scriptTimeout` can therefore still encounter the host's default five-second termination.
    - **Fix:** pass one effective deadline end to end; support cancellation, bounded output, bounded concurrency, and termination escalation for the owned process tree. Report timeout distinctly from ordinary exit status.

12. **P2 — “Only show on Tab” has no default way to receive Tab while hidden. Reproduced.**
    - [keybindings.ts:56](packages/api-bindings/src/keybindings.ts#L56) includes only `ALWAYS` actions when hidden. Both default Tab actions are focused-only.
    - Calling the real keymap code with suggestions available and the popup hidden yielded only `esc`; the Tab-specific show logic in the keypress handler cannot run. This remains broken even after fixing finding 4.
    - **Fix:** explicitly register a hidden-state Tab/show action when the setting is enabled, and preserve the normal terminal action when no suggestions exist.

13. **P2 — The advertised root test command is broken, and integration coverage is missing. Reproduced.**
    - [package.json:13](package.json#L13) runs Vitest from the root without selecting the packages' browser environment. Importing [bridge.ts:92](packages/api-bindings/src/bridge.ts#L92) then fails with `window is not defined`.
    - Explicit jsdom makes the suite pass, but 108 of 282 declared tests are TODO. No Swift/zsh/bridge integration tests are present.
    - **Fix:** create an explicit root Vitest project configuration; keep pure parser tests in Node and web tests in jsdom. Add native process, zsh keymap, protocol, and WebKit/session regressions. Make those checks run in macOS CI.

14. **P2 before distribution — The application depends on its development checkout. Code-confirmed.**
    - [build-host.sh:27](scripts/build-host.sh#L27) symlinks specs, icons, and shell integration from `~/.jamun` into this checkout and `node_modules`.
    - Copying `Jamun.app` to another Mac, deleting the checkout, or moving the source tree leaves those resources unavailable. A missing web build only produces a warning and still builds an empty app.
    - **Fix:** bundle versioned runtime resources; provide explicit install/uninstall steps for shell integration; fail on missing required assets; test a clean installation without the source tree. Add an intentional release signing/notarization process when distributing outside development.

Dependency findings require upgrades, but package severity is not the same as demonstrated application exploitability:

| Installed package | Audit result | Exposure and next step |
|---|---|---|
| Vitest `3.2.7`, `@vitest/mocker` `3.2.7` | Critical aggregate / moderate direct advisory | Development tooling. Upgrade to a maintained patched version and run the suite. The file-read advisory concerns the mock server; this review did not demonstrate that exposure in Jamun. [Advisory](https://github.com/advisories/GHSA-82fw-gwwq-j7x9) |
| Tinypool `1.1.1` | Critical | Transitive test dependency. The cited worker-options exploit requires a prototype-pollution primitive; none was established here. Upgrade through compatible test tooling, accounting for both reported advisories. [Worker-options advisory](https://github.com/advisories/GHSA-5gmw-xhrv-c9v3), [run-options advisory](https://github.com/advisories/GHSA-85c8-ppgw-ccpr) |
| Zod `3.25.76` | High; remains in production-only audit | Used for spec-index validation. Upgrade deliberately and cap index payload/collection sizes. Normal local indexes are a narrower exposure than an arbitrary public request body. [Advisory](https://github.com/advisories/GHSA-mrhx-c7xc-m3w5) |

Additional improvement points:

- **Make the bridge contract explicit.** Define schemas, protocol versions, readiness/replay, error codes, and bounded request lifetimes. Events emitted before `window.__jamunReceive` exists are dropped; WebKit reload does not replay the active buffer. The JS pending-request map has no timeout cleanup.
- **Complete shell context carefully.** Aliases are never sent, and only PATH/HOME/USER are exposed. Ordinary aliases and tools using per-shell `KUBECONFIG`, cloud profiles, or virtual environments may receive incomplete context. Send necessary context with a deliberate secret-handling policy.
- **Align displayed shortcuts with supported keys.** The description advertises Ctrl+K, but it is absent from the supported-key set. Numeric selection actions are also broken: [keypress.ts:182](packages/web/src/hooks/keypress.ts#L182) parses `selectSuggestion1` as a number and checks `<= 0` where a lower bound is needed. Derive hints from actual supported bindings; test every advertised action.
- **Add onboarding and diagnostics.** Show separate states for host running, shell connected, supported terminal, Accessibility access, specs available, and popup health. Add a quick enable/disable control and recovery action. The host currently supports Terminal.app only; document that explicitly.
- **Measure latency and resource use.** Record edit-to-suggestion p50/p95, slow generators, dropped stale responses, and cancellation counts without command contents. Avoid logging the entire parser result on every update. Bound caches, socket messages, process output, and log retention.
- **Improve accessibility and display coverage.** Suggestion rows are clickable divs without listbox/option semantics. Test VoiceOver, contrast over real Terminal backgrounds, reduce-motion/reduce-transparency settings, long descriptions, large fonts, display edges, Spaces, and multiple monitors. The isolated screenshot is insufficient to judge the native glass styling.
- **Harden local transport and file serving.** Add message-size limits, input validation, nonblocking writes/backpressure, and single-instance socket ownership. Resolve candidate symlinks before enforcing the scheme-handler root boundary. Clamp malformed cursor values before Swift string indexing.
- **Document and preserve the upstream boundary.** Add a Jamun root README with supported platforms, setup, development, testing, troubleshooting, and uninstall steps. Keep upstream notices, record the Fig source revision, and isolate compatibility adaptations so upstream changes can be reviewed cleanly.

Recommended implementation order:

| Order | Work | Completion criterion |
|---|---|---|
| 1 | Quoting, local-spec trust, validated edits | File/data suggestions cannot become shell syntax; untrusted project code cannot silently invoke native operations; stale edits are rejected |
| 2 | Tab, session ownership, key timeout recovery, Unicode spans | Terminal input remains correct across normal completion, stalls, session switches, and complex filenames |
| 3 | Test configuration, cache recovery, shell context, output parsing, process deadlines | One documented command runs meaningful unit and macOS integration checks; transient failures recover |
| 4 | Dependencies, packaging, onboarding, accessibility, performance | Clean installation works without the checkout; supported behavior and limitations are visible and tested |

Original scratch evidence was retained locally during the audit and is not part of this repository. Current reproducible checks and results are documented in [implementation status](IMPLEMENTATION_STATUS.md).
