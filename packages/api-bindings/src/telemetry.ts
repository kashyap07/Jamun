// jamun is local only. Telemetry calls from the lifted Fig code go nowhere.
export function track(
  _event: string,
  _properties: Record<string, string | boolean | number | null>,
) {}

export function page(
  _category: string,
  _name: string,
  _properties: Record<string, string | boolean | number | null>,
) {}
