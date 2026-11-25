import assert from 'node:assert/strict';
import * as desktop from '../dist/tools/private-desktop.js';
import { runIfMain } from './helpers/run-if-main.js';

async function runTests() {
  assert.equal(typeof desktop.validateForegroundLease, 'function', 'foreground lease validator must be exported for regression coverage');
  assert.equal(typeof desktop.privateDesktopNativeScript, 'string', 'native script contract must be inspectable');

  const lease = {
    token: 'test-token',
    window: '123',
    pid: 456,
    processCreated: '789',
    expiresAt: 10_000,
  };
  assert.equal(desktop.validateForegroundLease(lease, { window: '123', pid: 456 }, 9_999), null);
  assert.match(desktop.validateForegroundLease(lease, { window: '123', pid: 456 }, 10_000) ?? '', /expired/i);
  assert.match(desktop.validateForegroundLease(lease, { window: '124', pid: 456 }, 9_999) ?? '', /window/i);
  assert.match(desktop.validateForegroundLease(lease, { window: '123', pid: 457 }, 9_999) ?? '', /PID/i);
  assert.match(desktop.validateForegroundLease({ ...lease, processCreated: '0' }, { window: '123', pid: 456 }, 9_999) ?? '', /process/i);
  assert.match(desktop.validateForegroundLease({ ...lease, token: '' }, { window: '123', pid: 456 }, 9_999) ?? '', /token/i);

  assert.equal(desktop.privateDesktopNativeScript.includes('ActivateForeground'), false, 'input must never silently regain focus');
  assert.match(desktop.privateDesktopNativeScript, /GetProcessTimes/, 'native target validation must bind the process incarnation');
  assert.match(desktop.privateDesktopNativeScript, /lease\.token/, 'native input must require the foreground lease token');
  console.log('Private desktop foreground lease passed');
  return true;
}

runIfMain(import.meta.url, runTests);
