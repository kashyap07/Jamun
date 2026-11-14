import { request } from "./bridge.js";

type FrameResult = { isAbove?: boolean; isClipped?: boolean };

export async function isValidFrame(frame: {
  width: number;
  height: number;
  anchorX: number;
}) {
  return request<FrameResult>("window.position", {
    width: frame.width,
    height: frame.height,
    anchorX: frame.anchorX,
    anchorY: 0,
    dryrun: true,
  });
}

export async function setFrame(frame: {
  width: number;
  height: number;
  anchorX: number;
  offsetFromBaseline: number | undefined;
  /** place the popup above the caret when it fits there */
  preferAbove?: boolean;
}) {
  return request<FrameResult>("window.position", {
    width: frame.width,
    height: frame.height,
    anchorX: frame.anchorX,
    anchorY: frame.offsetFromBaseline ?? 0,
    preferAbove: frame.preferAbove ?? false,
    dryrun: false,
  });
}

export async function dragWindow() {
  /* not supported */
}
