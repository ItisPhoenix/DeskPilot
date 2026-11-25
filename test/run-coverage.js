/**
 * `npm run test:coverage` after its coverage build: runs test/run-ci.js under c8
 * (.c8rc.json), then prints the coverage table per src/ area. Exits 1 when the
 * tests fail; the table is informational.
 */
import { spawnSync } from 'child_process';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { ROOT } from './helpers/node-test-runner.js';

/** Runs the tests under c8 and prints their coverage by area; returns the test exit code. */
export function runCoverage({ node, args = [], root = ROOT }) {
  // A test command can stop before writing any results; old files must not survive as this run's output.
  const directory = path.resolve(root);
  for (const name of ['test-results', 'coverage']) {
    const target = path.join(directory, name);
    if (path.dirname(target) !== directory) throw new Error('Coverage output must stay inside its checkout.');
    fs.rmSync(target, { recursive: true, force: true });
  }
  const tests = node([
    path.join(ROOT, 'node_modules', 'c8', 'bin', 'c8.js'),
    process.execPath, path.join(ROOT, 'test', 'run-ci.js'), ...args,
  ]);
  node([path.join(ROOT, 'test', 'coverage-areas.js')]);
  return tests === 0 ? 0 : 1;
}

// Real paths on both sides: started through a symlink or junction, it still runs
if (process.argv[1] && fs.realpathSync.native(process.argv[1]) === fs.realpathSync.native(fileURLToPath(import.meta.url))) {
  const node = (args) => spawnSync(process.execPath, args, { cwd: ROOT, stdio: 'inherit' }).status;
  process.exit(runCoverage({ node, args: process.argv.slice(2) }));
}
