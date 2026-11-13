import * as EditBufferNotifications from "./editbuffer.js";
import * as Event from "./event.js";
import * as fs from "./filesystem.js";
import * as History from "./history.js";
import * as Keybindings from "./keybindings.js";
import * as Process from "./process.js";
import * as Settings from "./settings.js";
import * as Shell from "./shell.js";
import * as State from "./state.js";
import * as Telemetry from "./telemetry.js";
import * as Types from "./types.js";
import * as WindowPosition from "./position.js";

const lib = {
  EditBufferNotifications,
  Event,
  fs,
  History,
  Keybindings,
  Process,
  Settings,
  Shell,
  State,
  Telemetry,
  Types,
  WindowPosition,
};

export {
  EditBufferNotifications,
  Event,
  fs,
  History,
  Keybindings,
  Process,
  Settings,
  Shell,
  State,
  Telemetry,
  Types,
  WindowPosition,
};

declare global {
  interface Window {
    f: typeof lib;
  }
}

window.f = lib;
