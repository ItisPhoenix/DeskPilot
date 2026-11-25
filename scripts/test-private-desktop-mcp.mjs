import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const localAppData = fs.mkdtempSync(path.join(os.tmpdir(), "deskpilot-mcp-test-"));
const dataDir = path.join(localAppData, "DeskPilot");
fs.mkdirSync(dataDir, { recursive: true });
fs.writeFileSync(path.join(dataDir, "permissions.txt"), "31");

const env = Object.fromEntries(
  Object.entries(process.env).filter(([key, value]) =>
    typeof value === "string" &&
    !/^(CONTROL_PLANE_API_KEY|OPENAI_API_KEY|OPENAI_ADMIN_KEY)$/i.test(key)
  )
);
env.LOCALAPPDATA = localAppData;

const transport = new StdioClientTransport({
  command: process.execPath,
  args: [path.join(root, "managed-launcher.mjs")],
  env,
  stderr: "pipe",
});
const client = new Client({ name: "deskpilot-private-desktop-test", version: "1.0.0" });
const expected = [
  "capture_screen",
  "list_windows",
  "focus_window",
  "mouse_move",
  "mouse_click",
  "mouse_scroll",
  "keyboard_type",
  "keyboard_press",
];

try {
  await client.connect(transport);
  const list = await client.listTools();
  const names = list.tools.map((tool) => tool.name);
  console.log("MCP_LIST", names.length, "DESKTOP", expected.filter((name) => names.includes(name)).length);
  if (!expected.every((name) => names.includes(name))) {
    throw new Error("Missing private desktop tool");
  }

  const capture = await client.callTool({ name: "capture_screen", arguments: {} });
  const image = capture.content.find((item) => item.type === "image");
  if (
    capture.isError ||
    !image ||
    image.mimeType !== "image/jpeg" ||
    !Buffer.from(image.data, "base64").subarray(0, 3).equals(Buffer.from([255, 216, 255]))
  ) {
    throw new Error("MCP screenshot payload invalid");
  }
  console.log("MCP_IMAGE_PASS", image.mimeType, Buffer.from(image.data, "base64").length);

  const invalid = await client.callTool({
    name: "focus_window",
    arguments: { window: "1", pid: 1 },
  });
  if (!invalid.isError || !JSON.stringify(invalid).includes("identity changed")) {
    throw new Error("Native window/PID validation did not reject the invalid target");
  }
  console.log("MCP_NATIVE_INVALID_TARGET_PASS");

  const noLease = await client.callTool({
    name: "keyboard_type",
    arguments: { window: "1", pid: 1, text: "TEST_ONLY" },
  });
  if (!noLease.isError || !JSON.stringify(noLease).includes("lease token")) {
    throw new Error("Input without an explicit foreground lease was not rejected");
  }
  console.log("MCP_FOREGROUND_LEASE_REQUIRED");

  const history = await Promise.all(
    ["capture_screen", "keyboard_type"].map((toolName) =>
      client.callTool({ name: "get_recent_tool_calls", arguments: { maxResults: 1, toolName } })
    )
  );
  const serialized = JSON.stringify(history);
  if (
    serialized.includes("TEST_ONLY") ||
    serialized.includes(image.data.slice(0, 120))
  ) {
    throw new Error("Private desktop data leaked into tool history");
  }
  console.log("MCP_HISTORY_REDACTION_PASS");
  console.log("MCP_ACCEPTANCE_PASS");
} catch (error) {
  console.error("MCP_ACCEPTANCE_FAIL", error.message);
  process.exitCode = 1;
} finally {
  await client.close().catch(() => {});
  fs.rmSync(localAppData, { recursive: true, force: true });
}
