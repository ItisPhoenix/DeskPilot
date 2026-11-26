/**
 * Restricted Access is the default and an empty allowlist denies everything.
 * Full Filesystem Access is a local-only opt-in that reaches ordinary files
 * everywhere, but never DeskPilot's own configuration or installation paths.
 *
 * Runs in a test home because it changes config.json and restores it.
 */
import assert from 'assert';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { runIfMain, skip } from './helpers/run-if-main.js';
import { isTestHome } from './helpers/test-env.js';

const { configManager } = await import('../dist/config-manager.js');
const { validatePath, moveFile } = await import('../dist/tools/filesystem.js');
const { CONFIG_DIR } = await import('../dist/config.js');

const outside = path.join(os.tmpdir(), 'dp-filesystem-mode-test.txt');

async function runTests() {
  if (!isTestHome()) {
    return skip('test-filesystem-access-mode.js changes config.json: run it with node test/run-all-tests.js');
  }
  const found = {
    mode: await configManager.getValue('filesystemAccessMode'),
    dirs: await configManager.getValue('allowedDirectories'),
  };
  let passed = true;
  try {
    await configManager.setValue('filesystemAccessMode', 'restricted');
    await configManager.setValue('allowedDirectories', []);
    await assert.rejects(validatePath(outside), /Path not allowed/);
    console.log('✓ restricted mode with an empty allowlist denies paths');

    await configManager.setValue('filesystemAccessMode', 'full');
    assert.strictEqual(await validatePath(outside), path.resolve(outside));
    console.log('✓ full mode allows ordinary paths outside any allowlist');

    await assert.rejects(validatePath(path.join(CONFIG_DIR, 'config.json')), /Path not allowed/);
    console.log('✓ full mode still protects DeskPilot configuration');

    const guarded = fs.mkdtempSync(path.join(os.tmpdir(), 'dp-move-guard-'));
    const policy = path.join(guarded, 'policy.txt');
    fs.writeFileSync(policy, '0');
    const previousPolicy = process.env.DC_MANAGED_POLICY;
    process.env.DC_MANAGED_POLICY = policy;
    try {
      await assert.rejects(moveFile(guarded, path.join(guarded, 'moved')), /contains DeskPilot configuration/);
      console.log('✓ move_file refuses a parent of a protected policy file');
    } finally {
      if (previousPolicy === undefined) delete process.env.DC_MANAGED_POLICY;
      else process.env.DC_MANAGED_POLICY = previousPolicy;
      fs.rmSync(guarded, { recursive: true, force: true });
    }

    await configManager.setValue('filesystemAccessMode', 'restricted');
    await assert.rejects(validatePath(outside), /Path not allowed/);
    console.log('✓ switching back to restricted restores the deny');
  } catch (error) {
    console.error('✗', error.message);
    passed = false;
  } finally {
    await configManager.setValue('filesystemAccessMode', found.mode);
    await configManager.setValue('allowedDirectories', found.dirs);
  }
  return passed;
}

await runIfMain(import.meta.url, runTests);
