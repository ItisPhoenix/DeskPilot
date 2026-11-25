import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { runIfMain } from './helpers/run-if-main.js';

async function runTests() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'deskpilot-version-test-'));
  try {
    fs.mkdirSync(path.join(dir, 'src'), { recursive: true });
    fs.mkdirSync(path.join(dir, 'launcher'), { recursive: true });
    fs.writeFileSync(path.join(dir, 'package.json'), JSON.stringify({ name: 'deskpilot', version: '1.0.0' }));
    fs.writeFileSync(path.join(dir, 'package-lock.json'), JSON.stringify({ version: '1.0.0', packages: { '': { version: '1.0.0' } } }));
    fs.writeFileSync(path.join(dir, 'src/version.ts'), "export const VERSION = '1.0.0';\n");
    fs.writeFileSync(path.join(dir, 'launcher/Cargo.toml'), '[package]\nname = "deskpilot-launcher"\nversion = "1.0.0"\n');
    fs.writeFileSync(path.join(dir, 'launcher/build.rs'), ' FILEVERSION 1,0,0,0\n PRODUCTVERSION 1,0,0,0\n "FileVersion", "1.0.0.0"\n "ProductVersion", "1.0.0"\n');
    const result = spawnSync(process.execPath, [fileURLToPath(new URL('../scripts/sync-version.js', import.meta.url)), '--bump', '--minor'], { cwd: dir, encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(JSON.parse(fs.readFileSync(path.join(dir, 'package.json'), 'utf8')).version, '1.1.0');
    assert.match(fs.readFileSync(path.join(dir, 'src/version.ts'), 'utf8'), /1\.1\.0/);
    assert.match(fs.readFileSync(path.join(dir, 'launcher/Cargo.toml'), 'utf8'), /version = "1\.1\.0"/);
    const resource = fs.readFileSync(path.join(dir, 'launcher/build.rs'), 'utf8');
    assert.match(resource, /FILEVERSION 1,1,0,0/);
    assert.match(resource, /PRODUCTVERSION 1,1,0,0/);
    assert.match(resource, /"FileVersion", "1\.1\.0\.0"/);
    assert.match(resource, /"ProductVersion", "1\.1\.0"/);
    console.log('Version synchronization passed');
    return true;
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

runIfMain(import.meta.url, runTests);
