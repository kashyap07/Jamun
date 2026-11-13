<img src="assets/icon/jamun.png" width="128" alt="Jamun app icon">

# Jamun

Command suggestions with a nice completion popup for **zsh on macOS**, Powered Fig completion engine.

<img src="assets/screenshot.png" width="720" alt="Jamun suggesting gh subcommands in Terminal">

Works in macOS terminal and VSCode, haven't tested elsewhere.

**Install**

Requires Node.js 22.16+, macOS 13+, and Xcode with the macOS 26+ SDK.

```sh
npm ci
npm run build
```

1. Move `build/Jamun.app` to Applications and open it.
2. Choose **Set Up Shell Integration…** from the Jamun menu.
3. Grant **Accessibility** access, then open a new terminal window.

**Keys**

| Key | Action |
| --- | --- |
| ↑ / ↓ | Move through suggestions |
| Tab | Complete the shared prefix |
| Enter | Insert the selected suggestion |
| Esc | Dismiss the popup |
| Ctrl+K | Toggle the description |
| Ctrl+R | Toggle history suggestions |

**Settings**

Edit `~/.jamun/settings.json`, then choose **Reload Autocomplete** from the menu:

```json
{
  "autocomplete.onlyShowOnTab": true,
  "autocomplete.fontSize": 14,
  "autocomplete.width": 360
}
```

**Good to know**

- No suggestions? Choose **Show Diagnostics…** from the menu.
- Other terminal apps work only if they expose the caret through Accessibility. Remote SSH sessions are not supported yet.
- To uninstall, choose **Remove Shell Integration…**, quit Jamun, and delete the app.

**Development**

```sh
npm run check
npm run build
```

More in the [development guide](DEVELOPING.md), [protocol](PROTOCOL.md), and [validation status](IMPLEMENTATION_STATUS.md).

**License**

[MIT](LICENSE). Includes code from the Fig autocomplete engine and other projects under their own licenses: see the [upstream notices](THIRD_PARTY_NOTICES.md).
