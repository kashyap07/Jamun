import { request } from "./bridge.js";

export async function write(path: string, contents: string) {
  await request("fs.write", { path, contents });
}

export async function append(path: string, contents: string) {
  await request("fs.append", { path, contents });
}

export async function read(path: string) {
  const response = await request<{ contents: string | null }>("fs.read", { path });
  return response.contents;
}

export async function list(path: string) {
  const response = await request<{ fileNames: string[] }>("fs.list", { path });
  return response.fileNames;
}

export async function destinationOfSymbolicLink(path: string) {
  const response = await request<{ destination?: string }>("fs.readlink", { path });
  return response.destination;
}

export async function createDirectory(path: string, recursive: boolean) {
  await request("fs.mkdir", { path, recursive });
}
