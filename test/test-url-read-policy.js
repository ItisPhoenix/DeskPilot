import assert from 'node:assert/strict';
import { readFileFromUrl } from '../dist/tools/filesystem.js';
import { runIfMain } from './helpers/run-if-main.js';

async function runTests() {
  for (const url of [
    'http://127.0.0.1:8080/api/status',
    'http://localhost:8080/ui',
    'http://169.254.169.254/latest/meta-data/',
    'https://user:password@127.0.0.1:9/private',
    'file:///C:/Windows/win.ini',
  ]) {
    await assert.rejects(readFileFromUrl(url), /URL reads are disabled by DeskPilot policy/, `${url} must be rejected before any fetch`);
  }
  console.log('URL read SSRF policy passed');
  return true;
}

runIfMain(import.meta.url, runTests);
