/** The thread-pool launcher marks only its own serving copy and preserves application arguments. */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { test } from 'node:test';
import ts from 'typescript';
import { EventEmitter } from 'node:events';
import { createRequire } from 'node:module';

const requireBuiltin = createRequire(import.meta.url);

const LAUNCHER_ARGUMENT = '--desktop-commander-threadpool-launcher-pid=';
const ENTRY = path.resolve('fixture-package', 'dist', 'index.js');
const bootstrapSource = fs.readFileSync(new URL('../src/utils/threadpool-size.ts', import.meta.url), 'utf8');

function javascript(source) {
    return ts.transpileModule(source, {
        compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS },
    }).outputText;
}

function bootstrap({ env = {}, args = [], pid = 101, parentPid = 1, binds = true } = {}) {
    const observed = { invocation: null, monitored: false };
    const childProcess = {
        pid, ppid: parentPid, env: { ...env }, argv: ['node', ENTRY, ...args],
        execPath: 'node', execArgv: ['--no-warnings'], exit: () => {},
    };
    const context = vm.createContext({
        exports: {}, process: childProcess,
        require: (name) => {
            if (name === 'child_process') return { spawnSync: (executable, copiedArgs, options) => {
                observed.invocation = { executable, args: [...copiedArgs], options };
                return { status: 0 };
            } };
            if (name === './exit-process.js') return { exitProcess: () => {} };
            if (name === 'net') return {
                createServer: () => ({ on() {}, listen() {}, close() {}, listening: binds }),
                createConnection: () => {
                    observed.monitored = true;
                    const channel = new EventEmitter();
                    channel.unref = channel.resume = channel.destroy = () => {};
                    return channel;
                },
            };
            if (name === 'fs') return { unlinkSync() {} };
            return requireBuiltin(name);
        },
        setInterval: () => { observed.monitored = true; return { unref() {} }; }, clearInterval: () => {},
    });
    vm.runInContext(javascript(bootstrapSource), context);
    context.exports.setThreadpoolSize('16', false);
    return { ...observed, process: childProcess };
}

test('bootstrap appends exactly one marker after the original script arguments', () => {
    const { invocation } = bootstrap({ args: ['serve', 'user value'] });
    assert.deepEqual(invocation.args, ['--no-warnings', ENTRY, 'serve', 'user value',
        `${LAUNCHER_ARGUMENT}101`]);
    assert.equal(invocation.options.env.DESKTOP_COMMANDER_THREADPOOL_LAUNCHER_PID, '101');
    assert.equal(invocation.options.stdio, 'inherit');
});

test('an unrelated inherited launcher marker still configures the Windows pool', () => {
    const observed = bootstrap({ env: { DESKTOP_COMMANDER_THREADPOOL_LAUNCHER_PID: '999' } });
    assert.notEqual(observed.invocation, null);
    assert.equal(observed.process.env.UV_THREADPOOL_SIZE, '16');
    assert.equal(observed.monitored, false);
    assert.equal(observed.invocation.options.env.DESKTOP_COMMANDER_THREADPOOL_LAUNCHER_PID, '101');
});

test('the child consumes only its exact trailing marker and removes inherited launcher identity', () => {
    const marker = `${LAUNCHER_ARGUMENT}101`;
    const observed = bootstrap({ pid: 102, parentPid: 101,
        env: { DESKTOP_COMMANDER_THREADPOOL_LAUNCHER_PID: '101',
            DESKTOP_COMMANDER_THREADPOOL_LAUNCHER_CHANNEL: 'lifetime-fixture' },
        args: ['serve', marker, marker] });
    assert.deepEqual(observed.process.argv.slice(2), ['serve', marker]);
    assert.equal(observed.process.env.DESKTOP_COMMANDER_THREADPOOL_LAUNCHER_PID, undefined);
    assert.equal(observed.process.env.DESKTOP_COMMANDER_THREADPOOL_LAUNCHER_CHANNEL, undefined);
    assert.equal(observed.monitored, true);
});

test('a nonmatching or nontrailing application argument survives child bootstrap', () => {
    for (const args of [[`${LAUNCHER_ARGUMENT}999`], [`${LAUNCHER_ARGUMENT}101`, 'user value']]) {
        const observed = bootstrap({ env: { DESKTOP_COMMANDER_THREADPOOL_LAUNCHER_PID: '101' }, args });
        assert.deepEqual(observed.process.argv.slice(2), args);
    }
});

test('without launcher environment even an exact-looking application argument survives', () => {
    const args = [`${LAUNCHER_ARGUMENT}101`];
    assert.deepEqual(bootstrap({ env: { UV_THREADPOOL_SIZE: '16' }, args }).process.argv.slice(2), args);
});

test('an unavailable lifetime endpoint falls back without starting a copy', () => {
    const observed = bootstrap({ binds: false });
    assert.equal(observed.invocation, null);
    assert.equal(observed.process.env.UV_THREADPOOL_SIZE, '16');
    assert.equal(observed.monitored, false);
});

test('an unrelated PID-only marker remains unrelated even with its matching application argument', () => {
    const args = [`${LAUNCHER_ARGUMENT}999`];
    const observed = bootstrap({ env: { DESKTOP_COMMANDER_THREADPOOL_LAUNCHER_PID: '999' }, args });
    assert.notEqual(observed.invocation, null);
    assert.deepEqual(observed.process.argv.slice(2), args);
    assert.equal(observed.monitored, false);
});

test('an inherited endpoint needs a matching trailing launcher marker to identify a copy', () => {
    const args = [`${LAUNCHER_ARGUMENT}101`];
    const observed = bootstrap({ env: { DESKTOP_COMMANDER_THREADPOOL_LAUNCHER_PID: '999',
        DESKTOP_COMMANDER_THREADPOOL_LAUNCHER_CHANNEL: 'lifetime-fixture' }, args });
    assert.notEqual(observed.invocation, null);
    assert.deepEqual(observed.process.argv.slice(2), args);
    assert.equal(observed.monitored, false);
});

test('an inherited endpoint without a launcher PID does not identify a copy', () => {
    const observed = bootstrap({ env: { DESKTOP_COMMANDER_THREADPOOL_LAUNCHER_CHANNEL: 'lifetime-fixture' } });
    assert.notEqual(observed.invocation, null);
    assert.equal(observed.monitored, false);
});
