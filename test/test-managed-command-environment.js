import assert from 'node:assert/strict';
import { getCommandEnvironment } from '../dist/utils/shell.js';
import { runIfMain } from './helpers/run-if-main.js';

async function runTests() {
  const names = [
    'NODE_OPTIONS', 'NODE_PATH', 'CONTROL_PLANE_API_KEY', 'OPENAI_API_KEY',
    'OPENAI_ADMIN_KEY', 'GITHUB_TOKEN', 'GH_TOKEN', 'AWS_SECRET_ACCESS_KEY',
    'AZURE_CLIENT_SECRET', 'GOOGLE_APPLICATION_CREDENTIALS',
  ];
  const saved = Object.fromEntries(names.map((name) => [name, process.env[name]]));
  try {
    for (const name of names) process.env[name] = 'DUMMY_SECRET_MUST_NOT_LEAK';
    const env = getCommandEnvironment();
    for (const name of names) assert.equal(env[name], undefined, `${name} must not be inherited by managed commands`);
    if (process.env.PATH) assert.equal(env.PATH, process.env.PATH, 'PATH must remain available');
    if (process.env.SystemRoot) assert.equal(env.SystemRoot, process.env.SystemRoot, 'SystemRoot must remain available');
  } finally {
    for (const name of names) {
      if (saved[name] === undefined) delete process.env[name];
      else process.env[name] = saved[name];
    }
  }
  console.log('Managed command environment passed');
  return true;
}

runIfMain(import.meta.url, runTests);
