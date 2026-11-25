import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

const stage = path.resolve(process.argv[2] ?? '');
if (!stage) throw new Error('Usage: node scripts/test-release-layout.mjs <stage-directory>');
for (const relative of [
  'DeskPilot.exe',
  'server/dist/index.js',
  'server/managed-launcher.mjs',
  'server/package.json',
  'LICENSE',
  'NOTICE',
  'README.md',
  'PRIVACY.md',
  'SECURITY.md',
  'Uninstall-DeskPilot.ps1',
]) {
  assert.equal(fs.existsSync(path.join(stage, relative)), true, `Release layout is missing ${relative}`);
}
for (const forbidden of ['server/dist/remote-device', 'server/dist/tools/feedback.js', 'server/config.json', 'server/permissions.txt', 'server/runtime-key.dpapi', 'server/tunnel-client.yaml']) {
  assert.equal(fs.existsSync(path.join(stage, forbidden)), false, `Release layout contains forbidden ${forbidden}`);
}

const localAppData = fs.mkdtempSync(path.join(os.tmpdir(), 'deskpilot-release-layout-'));
const dataDir = path.join(localAppData, 'DeskPilot');
const workspace = fs.mkdtempSync(path.join(os.tmpdir(), 'deskpilot-release-workspace-'));
fs.mkdirSync(dataDir, { recursive: true });
fs.writeFileSync(path.join(dataDir, 'permissions.txt'), '0');
fs.writeFileSync(path.join(dataDir, 'config.json'), JSON.stringify({ allowedDirectories: [workspace], telemetryEnabled: false }));
const client = new Client({ name: 'deskpilot-release-layout-test', version: '1.0.0' });
const transport = new StdioClientTransport({
  command: process.execPath,
  args: [path.join(stage, 'server', 'managed-launcher.mjs')],
  env: { ...process.env, LOCALAPPDATA: localAppData },
  stderr: 'pipe',
});
transport.stderr?.resume();
try {
  await client.connect(transport, { timeout: 30_000 });
  const config = await client.callTool({ name: 'get_config', arguments: {} });
  assert.equal(config.isError, undefined);
  assert.equal(JSON.stringify(config).includes(localAppData), false);
  const denied = await client.callTool({ name: 'start_process', arguments: { command: 'hostname', timeout_ms: 1000 } });
  assert.equal(denied.isError, true);
  assert.match(denied.content[0].text, /disabled by local launcher/);
  console.log('RELEASE_LAYOUT_PASS');
} finally {
  await client.close().catch(() => {});
  fs.rmSync(localAppData, { recursive: true, force: true });
  fs.rmSync(workspace, { recursive: true, force: true });
}
