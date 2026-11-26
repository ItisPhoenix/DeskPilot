/**
 * Search roots may legitimately contain DeskPilot's own protected paths. No
 * backend may return those paths or their contents: ripgrep files/content,
 * Excel and DOCX content, recursive listings, and the fallback walker.
 *
 * Runs in a test home because it changes config.json; restores it afterwards.
 */
import assert from 'assert';
import fsSync from 'fs';
import fs from 'fs/promises';
import os from 'os';
import path from 'path';
import ExcelJS from 'exceljs';
import { configManager } from '../dist/config-manager.js';
import { searchAndWaitForCompletion } from './helpers/search.js';
import { runIfMain, skip } from './helpers/run-if-main.js';
import { isTestHome } from './helpers/test-env.js';

const MARKER = 'DP_PROTECTED_SEARCH_MARKER';

async function runTests() {
  if (!isTestHome()) {
    return skip('test-search-protected-paths.js changes config.json: run it with node test/run-all-tests.js');
  }

  const found = {
    dirs: await configManager.getValue('allowedDirectories'),
    mode: await configManager.getValue('filesystemAccessMode'),
    policy: process.env.DC_MANAGED_POLICY,
    install: process.env.DESKPILOT_INSTALL_DIR,
  };
  const root = fsSync.mkdtempSync(path.join(os.tmpdir(), 'dp-search-protect-'));
  const protectedDir = path.join(root, 'deskpilot-private');
  await fs.mkdir(protectedDir, { recursive: true });
  await fs.writeFile(path.join(root, 'public.txt'), 'public text');
  const policy = path.join(protectedDir, 'permissions.txt');
  await fs.writeFile(policy, '31');
  await fs.writeFile(path.join(protectedDir, 'private.txt'), MARKER);

  const workbook = new ExcelJS.Workbook();
  workbook.addWorksheet('Sheet1').addRow([MARKER]);
  await workbook.xlsx.writeFile(path.join(protectedDir, 'secret.xlsx'));

  let passed = true;
  try {
    process.env.DC_MANAGED_POLICY = policy;
    process.env.DESKPILOT_INSTALL_DIR = protectedDir;
    await configManager.setValue('allowedDirectories', [root]);
    await configManager.setValue('filesystemAccessMode', 'full');

    for (const args of [
      { path: root, pattern: 'permissions.txt', searchType: 'files' },
      { path: root, pattern: MARKER, searchType: 'content' },
      { path: root, pattern: MARKER, searchType: 'content', filePattern: '*.xlsx' },
    ]) {
      const { finalResult } = await searchAndWaitForCompletion(args);
      assert.ok(!finalResult.isError, `search failed: ${JSON.stringify(finalResult.content?.[0]?.text)}`);
      const text = JSON.stringify(finalResult);
      assert.ok(!text.includes('permissions.txt') && !text.includes('secret.xlsx') && !text.includes(MARKER),
        `protected path or content leaked from ${JSON.stringify(args)}: ${text.slice(0, 500)}`);
    }
    console.log('✓ file, content and Excel searches exclude protected paths and content');

    const { validatePath } = await import('../dist/tools/filesystem.js');
    await assert.rejects(validatePath(policy), /Path not allowed/);

    const { searchManager } = await import('../dist/search-manager.js');
    const session = await searchManager.startSearch({
      rootPath: root, pattern: 'public.txt', searchType: 'files'
    });
    const results = await searchManager.waitForCompletion(session.sessionId);
    assert.ok(results.some(result => result.file.endsWith('public.txt')), 'positive control');
    await configManager.setValue('filesystemAccessMode', 'restricted');
    await configManager.setValue('allowedDirectories', []);
    assert.throws(() => searchManager.readSearchResults(session.sessionId), /permissions changed|not found/);
    assert.ok(!searchManager.listSearchSessions().some(s => s.id === session.sessionId));
    console.log('✓ protected policy path stays denied in full access mode');
  } catch (error) {
    console.error('✗', error.message);
    passed = false;
  } finally {
    if (found.install === undefined) delete process.env.DESKPILOT_INSTALL_DIR;
    else process.env.DESKPILOT_INSTALL_DIR = found.install;
    if (found.policy === undefined) delete process.env.DC_MANAGED_POLICY;
    else process.env.DC_MANAGED_POLICY = found.policy;
    await configManager.setValue('filesystemAccessMode', found.mode);
    await configManager.setValue('allowedDirectories', found.dirs);
    await fs.rm(root, { recursive: true, force: true });
  }
  return passed;
}

await runIfMain(import.meta.url, runTests);
