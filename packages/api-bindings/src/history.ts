import { request } from "./bridge.js";

export type Param = string | number | Uint8Array | null;

export async function query(
  sql: string,
  params?: Param[],
): Promise<Array<Record<string, unknown>>> {
  const response = await request<{ rows: Array<Record<string, unknown>> }>(
    "history.query",
    { sql, params: (params ?? []).map((p) => (p instanceof Uint8Array ? null : p)) },
  );
  return response.rows ?? [];
}
