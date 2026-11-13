/** Shell edits use Unicode scalar counts; parser source positions use UTF-16. */
export const scalarLength = (text: string) => Array.from(text).length;
type Quote = "'" | '"' | null;

/** Quote data, never shell syntax. Prefix option-looking filenames with ./ at token start. */
export function quoteLiteral(text: string, quote: Quote = null): string {
  if (text.includes("\0")) throw new Error("A shell argument cannot contain NUL");
  if (quote === "'") return text.replace(/'/g, "'\\''");
  if (quote === '"') return text.replace(/[\\"$`]/g, "\\$&");
  if (/^[a-zA-Z0-9_./:@%+,=-]+$/.test(text)) return text;
  return `'${text.replace(/'/g, "'\\''")}'`;
}

/** Map a decoded suffix back to the original token, preserving existing path/option prefixes. */
export function replacementSpan(raw: string, query: string) {
  let decoded = "";
  let quote: Quote = null;
  const positions: { offset: number; quote: Quote }[] = [];
  for (let i = 0; i < raw.length;) {
    const ch = raw[i];
    if ((ch === "'" || ch === '"') && (!quote || quote === ch)) {
      quote = quote ? null : ch;
      i += 1;
      continue;
    }
    let start = i;
    if (ch === "\\" && quote !== "'" && i + 1 < raw.length &&
        (quote !== '"' || /[\\"$`\n]/.test(raw[i + 1]))) {
      i += 1;
      if (raw[i] === "\n") { i += 1; continue; }
    }
    const value = String.fromCodePoint(raw.codePointAt(i)!);
    for (let unit = 0; unit < value.length; unit += 1) positions.push({ offset: start, quote });
    decoded += value;
    i += value.length;
  }
  if (!decoded.endsWith(query)) throw new Error("Completion no longer matches the source token");
  if (!query) return { start: raw.length, quote };
  return { start: positions[decoded.length - query.length].offset, quote: positions[decoded.length - query.length].quote };
}

export function literalReplacement(raw: string, query: string, value: string, file = false) {
  const span = replacementSpan(raw, query);
  const tokenStart = raw.slice(0, span.start).replace(/["']/g, "").length === 0;
  const safeValue = file && tokenStart && value.startsWith("-") ? `./${value}` : value;
  // Close an existing quote because the replaced suffix includes any old closing quote.
  return { deletion: scalarLength(raw.slice(span.start)), insertion: quoteLiteral(safeValue, span.quote) + (span.quote ?? "") };
}
