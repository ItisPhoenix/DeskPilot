# Tests

Every suite test is a Node script: it **passes when its process exits with 0**. The runners start each file through Node's test runner (`node:test`) in its own process, one after another, from the file's folder, with its own temporary home. A file does not need to use `node:test`; one that does also gets each of its tests reported.

## Running them

| Command | What it runs |
|---|---|
| `npm test` | builds, then every `test/test*.js` and `test/*.test.js`, less the excluded ones |
| `node test/run-all-tests.js test-a.js test-b.js` | the named suite files (add `--no-build` when `dist/` is fresh) |
| `node test/repro/run-repro.js [names]` | the repro scripts in `test/repro/`, each stopped after 180 s by default |
| `npm run test:integration` | `test/integration/` |
| `npm run test:ci` | suite, repro and integration tests, without the timed tests |
| `npm run test:coverage` | the CI test plan under c8, followed by the coverage table |
| `npm run test:managed` | managed-launcher policy and private-desktop MCP checks |

The suite, repro and integration runners take these options:

- `--shard <i>/<n>`: the i-th of n parts of the files.
- `--skip <name>`: leave that file out (any number of times).
- `--out <dir>`: where the reports go.
- `--timed` and `--without-timed`: only, or without, the timed tests in `test/timed.txt`.

`run-all-tests.js` also takes `--no-build`. Changed-test selection, Docker runners and AI-review runners are not part of the DeskPilot source-first tree.

## Writing a test

- **Usual shape:** export the test's function and run it through `runIfMain(import.meta.url, run)` (`helpers/run-if-main.js`). The file exits with 0 when the function returns, and 1 when it throws or returns `false`.
- **Skipping a check:** when something the check needs is missing on the machine (Python, PowerShell, a drive letter), end it with `return skip('why')`. The file still passes, and the runner lists the skip in its summary and reports.
- **Files under `dist/`:** tests import the built code, so build first (`npm test` does).
- **The server:** a test that needs it starts it through `helpers/mcp-client.js`.
- **Temporary folders:** make them with `createTempDir()` (`helpers/test-env.js`). It gives the real path; macOS's temporary folder may be behind a link.

## Tests that measure time

A busy machine makes everything slower, so a check that involves time must hold up under load:

- A wait for something to happen gets a deadline a loaded machine still meets and returns as soon as the thing happens.
- A check whose point is a time compares against something measured in the same run, or makes the guarded operation take much longer than the limit.
- A check that races a time limit set by the product itself is a timed test. Its file goes into `test/timed.txt`; timed tests run one after another on a quiet machine, and every other run leaves them out.

## Test lists

A new test runs without being added anywhere:

- the suite runs every `test/test*.js` and `test/*.test.js`;
- the repro runner runs every `test/repro/test-*.js`;
- the integration runner runs every non-runner `.js` file in `test/integration/`;
- `test/test-powershell-tests.js` runs every `test/*.test.ps1`, with Windows PowerShell on Windows and `pwsh` elsewhere.

A runner given no names that finds no test file in its folder fails rather than passing with nothing run.

Two lists are read by `readTestList` (`helpers/node-test-runner.js`). Each entry is one test per line, `<name>  # <reason>`: a suite file by its name, the others as `repro/<name>` or `integration/<name>`. A line without a reason, a missing file, or a file no runner finds stops the run.

- **`test/timed.txt`:** the timed tests described above.
- **`test/excluded.txt`:** tests left out of normal discovery, with the reason on each line. `test/excluded.txt` lists no test now.

## Reports

Each runner writes in `test-results/suite/`, `test-results/repro/` or `test-results/integration/`:

| File | What |
|---|---|
| `junit.xml` | JUnit XML: a testcase per file; a failed file's last output lines in its `<failure>`; a skipped testcase per skipped check; the tests of `node:test` files |
| `results.json` | the same facts as JSON: each file's result, exit code, time, skipped checks and, on failure, its last output lines; plus excluded tests and reasons |
| `results.tap` | `node:test`'s TAP report |

## Coverage

`npm run test:coverage` writes `coverage/`: the HTML report, `lcov.info`, `coverage-final.json`, `coverage-summary.json`, `cobertura-coverage.xml` and a text summary.

- **Counted:** every JavaScript-producing file under `src/`, as configured by `.c8rc.json`.
- **Not counted:** `dist/`, `node_modules/`, `scripts/` and `test/`.
- **Type-only files:** `.c8rc.json` excludes TypeScript files that compile to no JavaScript.
- **Source mapping:** the coverage build uses `tsconfig.coverage.json`; c8 follows the test processes and maps `dist/` back to `src/`.
- **By area:** `test/coverage-areas.js` prints totals per folder under `src/`, plus `src/*` and one overall total.

The test tooling has its own tests, including `test/test-coverage-areas.js`, `test/test-run-coverage.js`, `test/test-run-ci.js`, `test/test-node-test-runner.js`, `test/test-runner-scripts.js` and `test/test-test-lists.js`.

## CI

`.github/workflows/tests.yml` runs the DeskPilot source-first Windows validation: `npm run test:ci`, managed-launcher checks, Rust formatting/checks/lint/build, dependency audits and the native launcher self-test. The release workflow builds the Windows archive and installer from `dist/`, `node_modules/`, the managed launcher and the approved DeskPilot assets.
