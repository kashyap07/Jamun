# Jamun

Command suggestions, right where you type. A native completion popup for **macOS Terminal + zsh**, powered by the Fig completion engine.

**Get started**

Requires Node.js 22.16+, macOS 13+, and Xcode with the macOS 26+ SDK.

```sh
npm ci
npm run build
```

1. Move `build/Jamun.app` to Applications and open it.
2. Choose **Set Up Shell Integration…** from the Jamun menu.
3. Grant **Accessibility** access, then open a new Terminal window.

When updating, install the app and its bundled shell integration together. Existing terminal sessions need restarting.

**Keyboard shortcuts**

| Key | Action |
| --- | --- |
| ↑ / ↓ | Move through suggestions |
| Tab | Complete the shared prefix |
| Enter | Insert the selected suggestion |
| Esc | Dismiss the popup |
| Ctrl+K | Toggle the description |
| Ctrl+R | Toggle history suggestions |

**Make it yours**

Edit `~/.jamun/settings.json`, then choose **Reload Autocomplete**:

```json
{
  "autocomplete.onlyShowOnTab": true,
  "autocomplete.fontSize": 14,
  "autocomplete.width": 360
}
```

- **Enable Autocomplete** pauses or resumes Jamun.
- **Show Diagnostics…** helps troubleshoot missing suggestions.
- Local project specs are disabled by default. Only trust developer specs you control: they run with your account’s privileges.
- Supported: local Terminal.app sessions. Other terminal apps and remote SSH sessions are not supported yet.

**Development**

```sh
npm run check
npm run build
npm run test:package -- build/Jamun.app
```

Setup details, release instructions, and troubleshooting: [development guide](DEVELOPING.md). See also the [protocol](PROTOCOL.md), [validation status](IMPLEMENTATION_STATUS.md), and [upstream notices](THIRD_PARTY_NOTICES.md).

To uninstall, choose **Remove Shell Integration…**, quit Jamun, and delete the app. Settings and logs are retained.
