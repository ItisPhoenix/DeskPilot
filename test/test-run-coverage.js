/**
 * `npm run test:coverage`'s steps (run-coverage.js): the tests under c8, then the
 * table per area, also when the tests failed. A stand-in for `node` records each
 * step and answers with an exit status; nothing runs.
 */
import assert from 'assert';
import fs from 'fs';
import path from 'path';
import { test } from 'node:test';
import { runCoverage } from './run-coverage.js';
import { runIfMain } from './helpers/run-if-main.js';
import { createTempDir } from './helpers/test-env.js';

/** runCoverage with each step's exit status: the steps it ran, by script name, and its exit code. */
function withStatuses(statuses, args = []) {
  const steps = [];
  const node = (argv) => {
    const script = argv.map((arg) => path.basename(arg)).find((name) => /\.js$/.test(name) && name !== 'c8.js') ?? '?';
    const ranUnderC8 = argv.some((arg) => path.basename(arg) === 'c8.js');
    steps.push(ranUnderC8 ? `c8 ${script} ${argv.slice(argv.findIndex((arg) => arg.endsWith(script)) + 1).join(' ')}`.trim() : script);
    return statuses[script] ?? 0;
  };
  const root = createTempDir('dc-run-coverage-steps-');
  try {
    return { code: runCoverage({ node, args, root }), steps };
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
}

export default async function run() {
  const passing = withStatuses({}, ['--without-timed']);
  assert.deepStrictEqual(passing.steps, ['c8 run-ci.js --without-timed', 'coverage-areas.js'],
    'the tests under c8 with the arguments given, then the areas');
  assert.strictEqual(passing.code, 0);

  const testsFail = withStatuses({ 'run-ci.js': 1 });
  assert.strictEqual(testsFail.code, 1, 'failed tests fail it');
  assert.deepStrictEqual(testsFail.steps, ['c8 run-ci.js', 'coverage-areas.js'], 'the areas still print after failed tests');

  assert.strictEqual(withStatuses({ 'coverage-areas.js': 1 }).code, 0, 'the table only reports: it fails nothing');
  console.log('✓ test:coverage: the tests under c8, then the areas; it fails with the tests');
}

runIfMain(import.meta.url, run);

test('an early test exit cannot leave stale test results or coverage', () => {
  const root = createTempDir('dc-run-coverage-stale-');
  try {
    for (const [name, file] of [['coverage', 'lcov.info'], ['test-results/suite', 'results.json']]) {
      fs.mkdirSync(path.join(root, name), { recursive: true });
      fs.writeFileSync(path.join(root, name, file), 'stale');
    }
    fs.mkdirSync(path.join(root, 'dist'));
    fs.writeFileSync(path.join(root, 'dist', 'keep.js'), 'coverage build');
    let calls = 0;
    const node = () => {
      if (calls++ === 0) {
        assert.strictEqual(fs.existsSync(path.join(root, 'test-results')), false, 'old results removed before tests');
        assert.strictEqual(fs.existsSync(path.join(root, 'coverage')), false, 'old coverage removed before tests');
        return 1;
      }
      return 0;
    };
    assert.strictEqual(runCoverage({ root, node }), 1);
    assert.strictEqual(fs.existsSync(path.join(root, 'test-results/suite/results.json')), false);
    assert.strictEqual(fs.existsSync(path.join(root, 'coverage/lcov.info')), false);
    assert.strictEqual(fs.readFileSync(path.join(root, 'dist/keep.js'), 'utf8'), 'coverage build');
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
