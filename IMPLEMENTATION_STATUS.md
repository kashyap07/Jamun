Validation results — 13 November 2026

- Automated checks pass for the current working tree.
- README shortened; detailed setup, architecture, troubleshooting and release notes moved to DEVELOPING.md.
- Validation build: `build/validation/Jamun.app`, signed ad hoc for local checks. The running app and installed shell integration were not replaced during validation.

| Check | Result |
| --- | --- |
| JavaScript / TypeScript tests | **210 passed**, 96 existing TODOs; 17 suites passed, one TODO suite skipped |
| TypeScript | Passed |
| Swift debug and release compilation | Passed |
| Native runtime harness | **17 assertions passed** |
| Real zsh / PTY integration | **5 tests passed** |
| Production WebKit UI | Passed: readiness, bundled specs, consecutive Down/Up, session switch and completion edit metadata |
| Standalone bundle | Copied outside checkout; signature and plist valid; required resources present; no symlinks; WebKit checks passed using only copied bundle assets |
| Shell syntax and diff whitespace | Passed |
| Dependency audits, full and production-only | **0 vulnerabilities** |
| Clean dependency installation | `npm ci --ignore-scripts --no-audit --no-fund` passed in a temporary workspace |
| macOS CI | Workflow added; not yet run on GitHub |

Regression coverage:

- Literal arguments: shell metacharacters, command substitutions, quotes, whitespace/newlines, emoji, combining characters, option-looking filenames, raw replacement spans and stale queries.
- Keyboard: repeated arrows before React renders, wraparound, stale/wrong sessions, hidden Tab, acknowledgements, original-widget pass-through, timeout disconnection/replay and Unicode edits through real ZLE.
- Protocol mismatch: shell waits for an explicit v2 host acknowledgement before accepting keyboard interception. A legacy host is disconnected before it can capture keys.
- Generators: failure → recovery, simultaneous callers, cache scope, TTL, stale-while-revalidate, effective timeout and execution session, script output normalization.
- Native resources: SIGTERM-resistant processes, inherited pipes, output limits, cancellation/recovery, single socket ownership and malformed frames.
- Trust/setup: default local-spec rejection, developer-reader denial, canonical symlink boundaries and preservation/removal of managed shell configuration blocks.

Findings addressed in source:

| Audit findings | Changes |
| --- | --- |
| 1–3 | Literal quoting, explicit execution intent, native local-spec trust policy, validated session/revision/buffer/cursor edits |
| 4–7 | Tab preservation, session-owned bindings, key fallback, raw Unicode replacement spans |
| 8–12 | Recoverable bounded caches, shell identity/context, legacy-marker handling, process deadlines, hidden Tab action |
| 13 | Root Node/jsdom configuration, regression harnesses and macOS CI |
| 14 | Bundled runtime resources, explicit shell setup/removal, staged packaging and release scripts |
| Additional improvements | Readiness/reload handling, bounded transport/logging, diagnostics, shortcut consistency, accessibility semantics and display preferences |

Remaining acceptance checks and limitations:

- Live VoiceOver, native glass contrast, Spaces and multiple monitors need manual acceptance testing.
- Full clean-machine installation, Accessibility onboarding and interactive setup/uninstall have not been exercised; bundle relocation and managed-block behavior were checked separately.
- The WebKit harness uses the production bundle and scheme handler with mocked native command execution. The native process/socket and real-shell protocol harnesses test their respective boundaries separately; this is not a complete live Terminal-to-host end-to-end test.
- 96 inherited TODO tests remain; these are not passing coverage. Twelve previously disabled script-generator tests were enabled.
- Upstream `@fig/autocomplete-shared` emits missing-source-map warnings. The standalone native harness emits a macOS deprecation warning for the compatible `posix_spawn_file_actions_addchdir_np` API. Neither blocks the checks.
- No notarization, release publication or GitHub CI execution was performed.
- Trusted specs run with the user's privileges. Process-group limits are not a hostile-code sandbox.

Keyboard regression history:

- The installed `~/.jamun/jamun.zsh` previously pointed into the source checkout. Editing protocol v2 therefore changed new shells while the existing app still spoke v1.
- Existing logs showed a Down event followed by an unnumbered acknowledgement and disconnection roughly 300 ms later. This explained the popup disappearing and the next Up reaching Atuin.
- The live symlink was replaced with a standalone copy of the committed v1 script; the user confirmed navigation recovered. The original link was saved as `~/.jamun/jamun.zsh.before-protocol-recovery.link`.
- The validated v2 build must be installed together with its bundled shell integration, followed by new Terminal sessions. Source edits and validation builds now leave the recovered live integration alone.

Reproduce locally:

```sh
npm ci
npm run check
JAMUN_BUILD_DIR="$PWD/build/validation" JAMUN_SIGN_IDENTITY=- npm run build
npm run test:package
npm audit
npm audit --omit=dev
```

- `npm run check`: JS tests, TypeScript, real-zsh tests and the native runtime harness.
- `npm run test:package`: copies the selected bundle to a temporary directory, validates its resources/signature and runs the WebKit harness against the copied assets.
- The native harness works with Command Line Tools; XCTest is not required.
