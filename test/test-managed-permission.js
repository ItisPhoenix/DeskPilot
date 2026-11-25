import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { managedPermission } from '../dist/utils/managed-permission.js';
import { createTestEnv } from './helpers/test-env.js';
import { runIfMain } from './helpers/run-if-main.js';

const terminal = ['start_process', 'read_process_output', 'interact_with_process', 'force_terminate', 'list_sessions', 'list_processes', 'kill_process'];
const files = ['read_file', 'read_multiple_files', 'write_file', 'write_pdf', 'create_directory', 'list_directory', 'move_file', 'start_search', 'get_more_search_results', 'stop_search', 'list_searches', 'get_file_info', 'edit_block'];
const screen = ['capture_screen', 'list_windows'];
const mouse = ['focus_window', 'mouse_move', 'mouse_click', 'mouse_scroll'];
const keyboard = ['keyboard_type', 'keyboard_press'];
const all = [...terminal, ...files, ...screen, ...mouse, ...keyboard];

function withPolicy(value, fn) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'deskpilot-permission-unit-'));
  const file = path.join(dir, 'permissions.txt');
  if (value !== undefined) fs.writeFileSync(file, value);
  const saved = process.env.DC_MANAGED_POLICY;
  process.env.DC_MANAGED_POLICY = file;
  try {
    return fn(file);
  } finally {
    if (saved === undefined) delete process.env.DC_MANAGED_POLICY;
    else process.env.DC_MANAGED_POLICY = saved;
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

async function runTests() {
  const fixture = createTestEnv();
  try {
    if (process.platform === 'win32') {
      assert.equal(typeof fixture.env.LOCALAPPDATA, 'string', 'test LOCALAPPDATA must be explicit');
      assert.ok(fixture.env.LOCALAPPDATA.startsWith(fixture.home), 'test LOCALAPPDATA must stay under the isolated test home');
    }
  } finally {
    fixture.cleanup();
  }

  const saved = process.env.DC_MANAGED_POLICY;
  delete process.env.DC_MANAGED_POLICY;
  try {
    for (const name of all) assert.equal(managedPermission(name), false, `${name} must be denied without a managed policy`);
    assert.equal(managedPermission('get_config'), true);
    assert.equal(managedPermission('not_a_tool'), false);
  } finally {
    if (saved === undefined) delete process.env.DC_MANAGED_POLICY;
    else process.env.DC_MANAGED_POLICY = saved;
  }

  for (const [mask, permitted] of [[1, terminal], [2, files], [4, screen], [8, mouse], [16, keyboard], [31, all]]) {
    withPolicy(String(mask), () => {
      for (const name of all) {
        assert.equal(managedPermission(name), permitted.includes(name), `mask ${mask} unexpected result for ${name}`);
      }
    });
  }

  for (const malformed of ['', '32', '-1', '1.0', ' 1', '1\n2', 'abc']) {
    withPolicy(malformed, () => {
      for (const name of all) assert.equal(managedPermission(name), false, `malformed policy ${JSON.stringify(malformed)} allowed ${name}`);
    });
  }

  const savedLocalToken = process.env.DESKPILOT_TEST_LOCAL_CONFIG_TOKEN;
  delete process.env.DESKPILOT_TEST_LOCAL_CONFIG_TOKEN;
  try {
    withPolicy('31', () => {
      assert.equal(managedPermission('set_config_value'), false, 'managed MCP callers must not mutate local configuration');
      assert.equal(managedPermission('give_feedback_to_desktop_commander'), false, 'removed feedback tool must stay denied');
    });
    process.env.DESKPILOT_TEST_LOCAL_CONFIG_TOKEN = 'local-test-capability';
    withPolicy('31', () => assert.equal(managedPermission('set_config_value'), true, 'explicit local test capability must allow configuration fixtures'));
  } finally {
    if (savedLocalToken === undefined) delete process.env.DESKPILOT_TEST_LOCAL_CONFIG_TOKEN;
    else process.env.DESKPILOT_TEST_LOCAL_CONFIG_TOKEN = savedLocalToken;
  }

  withPolicy('1', (file) => {
    fs.writeFileSync(file, '2');
    assert.equal(managedPermission('start_process'), false, 'policy changes must apply to the next call');
    assert.equal(managedPermission('read_file'), true);
  });

  withPolicy(undefined, () => {
    for (const name of all) assert.equal(managedPermission(name), false, `missing policy allowed ${name}`);
  });

  console.log('Managed permission matrix passed');
  return true;
}

runIfMain(import.meta.url, runTests);
