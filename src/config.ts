import path from "path";
import os from "os";

// Keep DeskPilot's configuration, history and local state together. The
// native launcher sets DESKPILOT_CONFIG_DIR to %LOCALAPPDATA%\DeskPilot.
// Direct source runs retain the upstream isolated-home path for compatibility.
export const USER_HOME = os.homedir();
const DEFAULT_CONFIG_DIR = path.join(USER_HOME, ".claude-server-commander");

export const CONFIG_DIR = process.env.DESKPILOT_CONFIG_DIR || DEFAULT_CONFIG_DIR;
export const CONFIG_FILE = path.join(CONFIG_DIR, "config.json");
export const TOOL_CALL_FILE = path.join(CONFIG_DIR, "deskpilot-tool-call.log");
export const TOOL_CALL_FILE_MAX_SIZE = 1024 * 1024 * 10; // 10 MB

export const DEFAULT_COMMAND_TIMEOUT = 1000; // 1 second

// Longest one process call blocks the MCP request; remaining output is read
// separately with read_process_output.
export const MAX_PROCESS_WAIT_MS = 50000; // 50 seconds
