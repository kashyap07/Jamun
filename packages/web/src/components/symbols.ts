import type { SuggestionType } from "@jamun/shared/internal";

/**
 * jamun draws generic suggestion icons with SF Symbols instead of Fig's PNG
 * set. The host serves each symbol as an alpha mask at fig://symbol/<name>,
 * and the row tints it with its own text color.
 */

/** Fig icon types (fig://icon?type=...) that have a good SF Symbol. */
const ICON_TYPE_SYMBOLS: Record<string, string> = {
  alert: "exclamationmark.triangle",
  asterisk: "asterisk",
  box: "cube",
  carrot: "return",
  characters: "textformat.abc",
  command: "terminal",
  commandkey: "command",
  commit: "smallcircle.filled.circle",
  cpu: "cpu",
  database: "cylinder",
  file: "doc",
  flag: "flag",
  folder: "folder",
  gear: "gearshape",
  git: "arrow.triangle.branch",
  invite: "envelope",
  option: "flag",
  package: "shippingbox",
  string: "textformat",
  user: "person",
  webhook: "link",
};

const SUGGESTION_TYPE_SYMBOLS: Partial<Record<SuggestionType, string>> = {
  folder: "folder",
  file: "doc",
  subcommand: "terminal",
  option: "flag",
  "auto-execute": "return",
  arg: "cube",
  shortcut: "lightbulb",
  mixin: "arrow.right",
};

export const DEFAULT_SYMBOL = "cube";

export const symbolForSuggestionType = (type: SuggestionType | undefined) =>
  (type && SUGGESTION_TYPE_SYMBOLS[type]) || DEFAULT_SYMBOL;

/** Returns a symbol name for an icon URL, or undefined to keep the image. */
export function symbolForIconUrl(icon: URL): string | undefined {
  if (icon.protocol !== "fig:") return undefined;
  if (icon.hostname === "icon") {
    const type = icon.searchParams.get("type");
    return type ? ICON_TYPE_SYMBOLS[type] : undefined;
  }
  if (icon.hostname === "template") return undefined;
  // fig://path/<file> and the older fig:///<file>: a file or folder icon.
  return icon.pathname.endsWith("/") ? "folder" : "doc";
}

export const symbolUrl = (name: string) => `fig://symbol/${name}`;
