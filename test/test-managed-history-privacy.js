import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { CONFIG_DIR, TOOL_CALL_FILE } from '../dist/config.js';
import { trackToolCall } from '../dist/utils/trackTools.js';
import { toolHistory } from '../dist/utils/toolHistory.js';
import { runIfMain } from './helpers/run-if-main.js';

async function runTests() {
  const secret = 'DUMMY_PRIVATE_HISTORY_SENTINEL';
  await trackToolCall('write_file', { path: 'private.txt', content: secret });
  toolHistory.addCall('write_file', { path: 'private.txt', content: secret }, {
    content: [{ type: 'text', text: `wrote ${secret}` }],
  }, 1);
  await new Promise((resolve) => setTimeout(resolve, 1100));

  const recent = JSON.stringify(toolHistory.getRecentCalls({ maxResults: 10, toolName: 'write_file' }));
  assert.equal(recent.includes(secret), false, 'managed in-memory history retained private arguments or output');
  for (const file of [TOOL_CALL_FILE, path.join(CONFIG_DIR, 'tool-history.jsonl')]) {
    if (fs.existsSync(file)) assert.equal(fs.readFileSync(file, 'utf8').includes(secret), false, `${file} retained private data`);
  }
  console.log('Managed history privacy passed');
  return true;
}

runIfMain(import.meta.url, runTests);
