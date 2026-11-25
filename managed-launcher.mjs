import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const launcherDir = path.dirname(fileURLToPath(import.meta.url));
const serverRoot = existsSync(path.join(launcherDir, "dist", "index.js"))
  ? launcherDir
  : path.join(launcherDir, "server");
const entrypoint = path.join(serverRoot, "dist", "index.js");
const localAppData = process.env.LOCALAPPDATA;

if (!localAppData || !existsSync(entrypoint)) {
  console.error("DeskPilot server installation is incomplete.");
  process.exit(1);
}

// The MCP server receives only the OS variables needed for local process and
// filesystem work. Tunnel/OpenAI credentials, unrelated cloud tokens, Node
// preload injection and proxy credentials are not inherited.
const allowedEnvironment = new Set([
  "PATH", "PATHEXT", "SYSTEMROOT", "SYSTEMDRIVE", "COMSPEC", "PROGRAMDATA",
  "PROGRAMFILES", "PROGRAMFILES(X86)", "PROGRAMW6432", "WINDIR",
  "LOCALAPPDATA", "APPDATA", "USERPROFILE", "HOME", "TEMP", "TMP",
  "USERNAME", "USERDOMAIN", "SESSIONNAME", "PSMODULEPATH",
  "LANG", "LC_ALL", "LC_CTYPE", "TERM", "NO_COLOR", "FORCE_COLOR", "CI",
]);
const env = Object.fromEntries(
  Object.entries(process.env).filter(([name]) => {
    const upper = name.toUpperCase();
    return allowedEnvironment.has(upper) || upper.startsWith("DESKPILOT_") || upper.startsWith("DC_");
  })
);

env.DC_PRIVATE_DESKTOP = "1";
env.DC_MANAGED_POLICY = path.join(localAppData, "DeskPilot", "permissions.txt");
env.DESKPILOT_CONFIG_DIR = path.join(localAppData, "DeskPilot");
env.DESKPILOT_INSTALL_DIR = serverRoot;
delete env.DESKPILOT_TEST_LOCAL_CONFIG_TOKEN;
delete env.DESKPILOT_LOCAL_DIAGNOSTICS;
env.DESKTOP_COMMANDER_DISABLE_TELEMETRY = "1";
env.DESKPILOT_DISABLE_REMOTE_FLAGS = "1";
env.DESKPILOT_ENFORCE_MANAGED_COMMANDS = "1";

const child = spawn(process.execPath, [entrypoint], {
  cwd: serverRoot,
  env,
  stdio: "inherit",
  windowsHide: true,
});

child.on("exit", (code) => process.exit(code ?? 1));
child.on("error", (error) => {
  console.error("DeskPilot server failed to start:", error.message);
  process.exit(1);
});
