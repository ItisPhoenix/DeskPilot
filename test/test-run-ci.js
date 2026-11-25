/**
 * Verifies DeskPilot's CI test plan: suite, repro and integration tests.
 * Coverage rebuilds only the coverage output; there is no release rehearsal.
 */
import assert from "assert";
import path from "path";
import { ciParts, planFor, runParts } from "./run-ci.js";
import { runIfMain } from "./helpers/run-if-main.js";

const script = (part) => path.basename(part.args[0]);
const described = (parts) =>
  parts.map((part) =>
    `${part.name}: ${part.args
      .map((arg) => (path.isAbsolute(arg) ? path.basename(arg) : arg))
      .join(" ")}`
  );
const env = { NODE_V8_COVERAGE: "/c8-tmp", PATH: "/bin" };

function testPlans() {
  const plan = (tests, underCoverage = true) =>
    described(planFor(tests, { underCoverage, env }));

  assert.deepStrictEqual(
    plan(""),
    described(ciParts({ underCoverage: true, env })),
    "empty means the normal CI plan"
  );
  assert.deepStrictEqual(plan("test"), ["suite: run-all-tests.js --no-build --without-timed"]);
  assert.deepStrictEqual(plan("integration"), ["integration: run-all-integration-tests.js --without-timed"]);
  assert.deepStrictEqual(plan("repro"), [
    "repro: run-repro.js --without-timed",
    "coverage build again: tsc -p tsconfig.coverage.json",
  ]);
  assert.deepStrictEqual(plan("repro", false), ["repro: run-repro.js --without-timed"]);
  assert.deepStrictEqual(plan("timed"), [
    "suite, timed: run-all-tests.js --no-build --timed",
    "repro, timed: run-repro.js --timed",
    "integration, timed: run-all-integration-tests.js --timed",
  ]);
  assert.deepStrictEqual(
    plan("files:test/test-a.js,test/repro/test-config-damaged-start.js,integration/d.js"),
    [
      "suite: run-all-tests.js --no-build test-a.js",
      "repro: run-repro.js test-config-damaged-start.js",
      "integration: run-all-integration-tests.js d.js",
    ]
  );
  assert.deepStrictEqual(
    plan("files:repro/test-config-damaged-start.js"),
    ["repro: run-repro.js test-config-damaged-start.js"]
  );

  for (const wrong of ["all", "everything", "docker", "changed:A", "changed:..B", "files:", "files:src/index.ts"]) {
    assert.throws(() => planFor(wrong, { underCoverage: true, env }), /tests/);
  }
  console.log("PASS CI test plans");
}

export default async function run() {
  testPlans();

  const covered = ciParts({ underCoverage: true, passed: [], env });
  assert.deepStrictEqual(covered.map(({ name }) => name), [
    "suite",
    "repro",
    "integration",
    "coverage build again",
  ]);

  for (const part of covered.slice(0, 3)) {
    assert.ok(part.args.includes("--without-timed"));
    assert.strictEqual(part.env, undefined);
  }
  assert.deepStrictEqual(covered.slice(0, 3).map(script), [
    "run-all-tests.js",
    "run-repro.js",
    "run-all-integration-tests.js",
  ]);
  assert.ok(covered[0].args.includes("--no-build"));
  assert.deepStrictEqual(covered.slice(3).map(script), ["tsc"]);
  assert.ok(!("NODE_V8_COVERAGE" in covered[3].env));
  assert.ok(covered.slice(3).every((part) => !part.report));

  const plain = ciParts({ underCoverage: false, passed: [], env: { PATH: "/bin" } });
  assert.deepStrictEqual(plain.map(({ name }) => name), ["suite", "repro", "integration"]);
  assert.ok(!plain[1].args.includes("--skip"));
  console.log("PASS coverage and non-coverage CI plans");

  const onDisk = new Set();
  const files = { exists: (file) => onDisk.has(file), remove: (file) => onDisk.delete(file) };
  const writes = (part) => { if (part.report) onDisk.add(part.report); };
  const ran = [];
  const lines = [];
  const code = await runParts(covered, {
    runPart: async (part) => {
      ran.push(part.name);
      writes(part);
      return part.name === "repro" ? 1 : 0;
    },
    log: (line) => lines.push(line),
    files,
  });
  assert.strictEqual(ran.length, covered.length, "every part runs after a failure");
  assert.strictEqual(code, 1, "a failed part fails the run");
  assert.ok(lines.includes("✗ repro (exit 1)") && lines.includes("✓ suite (exit 0)"));

  assert.strictEqual(
    await runParts(plain, {
      runPart: async (part) => { writes(part); return 0; },
      log: () => {},
      files,
    }),
    0
  );

  onDisk.clear();
  onDisk.add(covered[2].report);
  const closedLines = [];
  const closed = await runParts(covered, {
    runPart: async (part) => {
      if (part.name !== "integration") writes(part);
      return 0;
    },
    log: (line) => closedLines.push(line),
    files,
  });
  assert.strictEqual(closed, 1, "a test part without fresh results fails closed");
  assert.ok(closedLines.some((line) => line.startsWith("✗ integration (exit 0, no results: ") && line.includes("integration/results.json")));
  console.log("PASS CI failure handling and fail-closed result checks");
}

runIfMain(import.meta.url, run);
