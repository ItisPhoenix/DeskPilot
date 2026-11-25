import assert from 'node:assert/strict';
import { runIfMain } from './helpers/run-if-main.js';

async function runTests() {
  const { scanText } = await import('../scripts/secret-scanner.mjs');
  assert.equal(typeof scanText, 'function');
  assert.ok(scanText('OPENAI_API_KEY="sk-' + 'A'.repeat(30) + '"').some((finding) => finding.kind === 'openai-key'));
  assert.ok(scanText('tunnel_' + 'a1b2c3d4'.repeat(4)).some((finding) => finding.kind === 'tunnel-id'));
  assert.ok(scanText('path=C:\\' + 'Users\\private-account\\file.txt').some((finding) => finding.kind === 'personal-path'));
  assert.equal(scanText('OPENAI_API_KEY="DUMMY_TEST_ONLY"').some((finding) => finding.kind === 'openai-key' || finding.kind === 'generic-secret'), false);
  console.log('Secret scanner policy passed');
  return true;
}

runIfMain(import.meta.url, runTests);
