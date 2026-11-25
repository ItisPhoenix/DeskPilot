/**
 * Runs what CI runs, one after another: the suite, the repro scripts and the
 * integration tests, without the timed tests in test/timed.txt. Each runner
 * writes its reports in test-results/<suite|repro|integration>/. Every part runs
 * even when one fails; exits 1 if any did.
 *
 *   node test/run-ci.js [options]   # build first: npm run build (or build:coverage)
 *   TESTS=<value> node test/run-ci.js
 *
 * TESTS (planFor): empty for all of the above, or test, integration, repro,
 * timed or files:a.js,b.js. `npm run test:coverage` runs this under c8
 * (test/run-coverage.js).
 */
import { spawn } from 'child_process';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');

// The results.json a test part's runner writes: its default --out.
const report = (folder) => path.join(ROOT, 'test-results', folder, 'results.json');

/** Under coverage: rebuild the coverage output after the tests. */
function rebuildParts({ uncovered }) {
  return [{
    name: 'coverage build again',
    args: [path.join(ROOT, 'node_modules', 'typescript', 'bin', 'tsc'), '-p', path.join(ROOT, 'tsconfig.coverage.json')],
    env: uncovered,
  }];
}

/**
 * What a push run runs, in order: { name, args (node's), env (none:
 * run-ci.js's own), report (a test part's results.json) }.
 */
export function ciParts({ underCoverage, passed = [], env = process.env }) {
  const { NODE_V8_COVERAGE, ...uncovered } = env;
  return [
    { name: 'suite', args: [path.join(__dirname, 'run-all-tests.js'), '--no-build', '--without-timed', ...passed], report: report('suite') },
    { name: 'repro', args: [path.join(__dirname, 'repro', 'run-repro.js'), '--without-timed', ...passed], report: report('repro') },
    {
      name: 'integration',
      args: [path.join(__dirname, 'integration', 'run-all-integration-tests.js'), '--without-timed', ...passed],
      report: report('integration'),
    },
    ...(underCoverage ? rebuildParts({ uncovered }) : []),
  ];
}

const TESTS_VALUES = 'empty (everything but the timed tests), test, integration, repro, timed or files:a.js,b.js';

/** The parts that run named files: each through its folder's runner (a suite file has no folder). */
function filesParts(files) {
  const byFolder = { suite: [], repro: [], integration: [] };
  for (const file of files) {
    const parts = file.replace(/^test\//, '').split('/');
    const folder = parts.length === 1 ? 'suite' : parts[0];
    if (!byFolder[folder] || parts.length > 2 || !/\.js$/.test(file)) {
      throw new Error(`tests: "${file}" isn't a test file in test/, test/repro/ or test/integration/`);
    }
    byFolder[folder].push(parts.at(-1));
  }
  return [
    byFolder.suite.length && { name: 'suite', args: [path.join(__dirname, 'run-all-tests.js'), '--no-build', ...byFolder.suite], report: report('suite') },
    byFolder.repro.length && { name: 'repro', args: [path.join(__dirname, 'repro', 'run-repro.js'), ...byFolder.repro], report: report('repro') },
    byFolder.integration.length && {
      name: 'integration', args: [path.join(__dirname, 'integration', 'run-all-integration-tests.js'), ...byFolder.integration], report: report('integration'),
    },
  ].filter(Boolean);
}

/**
 * The parts an on-demand run's `tests` value asks for, through the runners' own
 * options; empty, the default, is what a push run runs. An unknown value stops
 * with what it can.
 */
export function planFor(tests, { underCoverage, env = process.env }) {
  const value = (tests ?? '').trim();
  const everything = ciParts({ underCoverage, env });
  if (value === '') return everything;
  if (value === 'test') return everything.filter(({ name }) => name === 'suite');
  if (value === 'integration') return everything.filter(({ name }) => name === 'integration');
  if (value === 'repro') return everything.filter(({ name }) => name.startsWith('repro') || name.includes('again'));
  if (value === 'timed') {
    return [
      { name: 'suite, timed', args: [path.join(__dirname, 'run-all-tests.js'), '--no-build', '--timed'], report: report('suite') },
      { name: 'repro, timed', args: [path.join(__dirname, 'repro', 'run-repro.js'), '--timed'], report: report('repro') },
      { name: 'integration, timed', args: [path.join(__dirname, 'integration', 'run-all-integration-tests.js'), '--timed'], report: report('integration') },
    ];
  }
  if (value.startsWith('files:')) {
    const files = value.slice('files:'.length).split(',').map((file) => file.trim()).filter(Boolean);
    if (files.length > 0) return filesParts(files);
  }
  throw new Error(`tests: "${value}" isn't one of: ${TESTS_VALUES}`);
}

const onDisk = { exists: fs.existsSync, remove: (file) => fs.rmSync(file, { force: true }) };

/**
 * Runs every part, even after a failure, prints a line per part; returns 1 if any
 * failed. Fail closed: a test part's report is removed before it runs, and a part
 * that exits 0 without writing it fails ("no results"), so an earlier run's report
 * can't stand in for it. `files`: the disk, or a test's stand-in.
 */
export async function runParts(parts, { runPart, log = console.log, files = onDisk }) {
  const codes = [];
  for (const part of parts) {
    log(`\n########## ${part.name} ##########\n`);
    if (part.report) files.remove(part.report);
    const code = await runPart(part);
    const missing = code === 0 && part.report && !files.exists(part.report);
    codes.push({ name: part.name, code, failed: code !== 0 || missing, note: missing ? `, no results: ${path.relative(ROOT, part.report).split(path.sep).join('/')}` : '' });
  }
  log('\n########## CI parts ##########');
  for (const { name, code, failed, note } of codes) log(`${failed ? '✗' : '✓'} ${name} (exit ${code}${note})`);
  return codes.some(({ failed }) => failed) ? 1 : 0;
}

function spawnPart({ args, env }) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, args, { stdio: 'inherit', cwd: ROOT, env: env ?? process.env });
    child.on('close', (code) => resolve(code));
    child.on('error', (error) => {
      console.error(error.message);
      resolve(1);
    });
  });
}

// Real paths on both sides: started through a symlink or junction, it still runs
if (process.argv[1] && fs.realpathSync.native(process.argv[1]) === fs.realpathSync.native(fileURLToPath(import.meta.url))) {
  const underCoverage = Boolean(process.env.NODE_V8_COVERAGE);
  const passed = process.argv.slice(2);
  let parts;
  try {
    parts = process.env.TESTS ? planFor(process.env.TESTS, { underCoverage }) : ciParts({ underCoverage, passed });
  } catch (error) {
    console.error(error.message);
    process.exit(1);
  }
  process.exit(await runParts(parts, { runPart: spawnPart }));
}
