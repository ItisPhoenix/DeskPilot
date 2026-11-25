import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const localAppData = fs.mkdtempSync(path.join(os.tmpdir(), "deskpilot-policy-test-"));
const dataDir = path.join(localAppData, "DeskPilot");
const workspace = fs.mkdtempSync(path.join(os.tmpdir(), "deskpilot-workspace-test-"));
const policyFile = path.join(dataDir, "permissions.txt");
fs.mkdirSync(dataDir, { recursive: true });
fs.writeFileSync(policyFile, "0");
fs.writeFileSync(path.join(dataDir, "config.json"), JSON.stringify({
  allowedDirectories: [workspace, dataDir],
  telemetryEnabled: false,
  pendingWelcomeOnboarding: false,
  welcomeOnboardingEligible: false,
}));

const secrets = {
  CONTROL_PLANE_API_KEY: "DUMMY_TEST_ONLY_CONTROL",
  OPENAI_API_KEY: "DUMMY_TEST_ONLY_OPENAI",
  OPENAI_ADMIN_KEY: "DUMMY_TEST_ONLY_ADMIN",
  CONTROL_PLANE_TUNNEL_ID: "DUMMY_TEST_ONLY_TUNNEL",
  TUNNEL_CLIENT_PROFILE: "DUMMY_TEST_ONLY_PROFILE",
  TUNNEL_CLIENT_PROFILE_FILE: "DUMMY_TEST_ONLY_PROFILE_FILE",
};
const client = new Client({ name: "deskpilot-policy-test", version: "1.0.0" });
const transport = new StdioClientTransport({
  command: process.execPath,
  args: [path.join(root, "managed-launcher.mjs")],
  env: {
    ...process.env,
    LOCALAPPDATA: localAppData,
    DESKPILOT_LOCAL_DIAGNOSTICS: '1',
    DESKPILOT_TEST_LOCAL_CONFIG_TOKEN: 'must-not-reach-managed-server',
    ...secrets,
  },
});

try {
  await client.connect(transport);

  for (const [name, args] of [
    ["start_process", { command: "hostname", timeout_ms: 3000 }],
    ["capture_screen", {}],
    ["keyboard_type", { window: "1", pid: 1, text: "test" }],
    ["list_directory", { path: workspace }],
  ]) {
    const result = await client.callTool({ name, arguments: args });
    if (!result.isError || !result.content[0].text.includes("disabled by local launcher")) {
      throw new Error("Default-deny policy failed for " + name);
    }
    console.log("DENIED_BY_DEFAULT", name);
  }

  const publicConfig = await client.callTool({ name: "get_config", arguments: {} });
  const configText = JSON.stringify(publicConfig);
  if (publicConfig.isError || configText.includes(localAppData) || configText.includes("systemInfo")) {
    throw new Error("Managed get_config exposed local host details");
  }
  console.log("REDACTED_CONFIG_PASS");

  fs.writeFileSync(policyFile, "1");
  const allowed = await client.callTool({
    name: "start_process",
    arguments: { command: "hostname", timeout_ms: 3000 },
  });
  if (allowed.isError || !JSON.stringify(allowed).toLowerCase().includes(os.hostname().toLowerCase())) {
    throw new Error("Explicit terminal permission did not work");
  }
  console.log("EXPLICIT_PERMISSION_PASS");

  const dynamic = await client.callTool({
    name: "start_process",
    arguments: { command: "$c='hostname'; & $c", shell: "powershell", timeout_ms: 3000 },
  });
  if (!dynamic.isError || !JSON.stringify(dynamic).includes("cannot validate")) {
    throw new Error("Managed mode executed a runtime-selected command");
  }
  console.log("RUNTIME_SELECTED_COMMAND_DENIED");

  fs.unlinkSync(policyFile);
  const missing = await client.callTool({
    name: "start_process",
    arguments: { command: "hostname", timeout_ms: 3000 },
  });
  if (!missing.isError || !missing.content[0].text.includes("disabled by local launcher")) {
    throw new Error("Missing policy was not fail-closed");
  }
  console.log("MISSING_POLICY_FAIL_CLOSED");

  fs.writeFileSync(policyFile, "2");
  const policyWrite = await client.callTool({
    name: "write_file",
    arguments: { path: policyFile, content: "31" },
  });
  if (!policyWrite.isError) throw new Error("Files permission overwrote the launcher policy");
  const terminalAfterWrite = await client.callTool({
    name: "start_process",
    arguments: { command: "hostname", timeout_ms: 3000 },
  });
  if (!terminalAfterWrite.isError) throw new Error("Files permission escalated into Terminal");
  console.log("POLICY_WRITE_DENIED");

  const workspaceWrite = await client.callTool({
    name: "write_file",
    arguments: { path: path.join(workspace, "allowed.txt"), content: "ok" },
  });
  if (workspaceWrite.isError) throw new Error("Explicit workspace write was denied");
  console.log("WORKSPACE_WRITE_PASS");

  fs.writeFileSync(policyFile, "1");
  const checks = Object.keys(secrets).map((name) => `if defined ${name} echo LEAKED_${name}`).join(" & ");
  const envProbe = await client.callTool({
    name: "start_process",
    arguments: {
      command: `cmd /d /c "echo PROBE_OK & ${checks} & if defined NODE_OPTIONS echo LEAKED_NODE_OPTIONS"`,
      timeout_ms: 3000,
    },
  });
  const probeText = JSON.stringify(envProbe);
  if (envProbe.isError || !probeText.includes("PROBE_OK") || probeText.includes("LEAKED_")) {
    throw new Error("Managed environment isolation probe failed: " + probeText);
  }
  console.log("RUNTIME_CREDENTIALS_NOT_FORWARDED");

  fs.writeFileSync(policyFile, "31");
  const mutation = await client.callTool({
    name: "set_config_value",
    arguments: { key: "allowedDirectories", value: [workspace] },
  });
  if (!mutation.isError) throw new Error("Managed MCP caller mutated local configuration");
  console.log("REMOTE_CONFIG_MUTATION_DENIED");
} finally {
  await client.close().catch(() => {});
  fs.rmSync(localAppData, { recursive: true, force: true });
  fs.rmSync(workspace, { recursive: true, force: true });
}
