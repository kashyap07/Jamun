Jamun itself is released under the MIT license in `LICENSE`. It includes code adapted from the Fig/Amazon autocomplete engine and uses the published `@withfig/autocomplete` specification package.

| Component | Provenance | Notices |
|---|---|---|
| Autocomplete engine, shell parser, shared utilities, API wrappers | Existing imported sources attributed to Amazon Web Services | `packages/LICENSE.fig.MIT`, `packages/LICENSE.fig.APACHE`; retain source copyright headers |
| Completion specs and icons | npm `@withfig/autocomplete`, pinned at `2.692.3` in the lockfile | License distributed with that package, copied into the app during packaging |
| Fuzzysort | Existing vendored implementation | `packages/fuzzysort/LICENSE` |
| Other dependencies | Exact versions and integrity hashes in `package-lock.json` | Their distributed package licenses |

- The original imported engine's upstream Git commit was not recorded in this checkout. It is **unknown**, not inferred from the spec package version. Record it when the original import source is recovered.
- Jamun compatibility and security adaptations are concentrated in `packages/api-bindings`, `host`, `shell`, and the insertion/spec-loading boundaries.
- Keep upstream source headers and these notices when updating or redistributing the application.
