import { test, expect } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
const { version } = JSON.parse(readFileSync('package.json', 'utf8'));

const run = args => spawnSync(process.execPath, ['bin/sqlite-sbx.js', ...args], {
  encoding: 'utf8', timeout: 10000,
  env: { ...process.env, BSDKRUN_BIN: '/nonexistent/bsdkrun', BSDKRUN_NO_AUTO_INSTALL: '1' },
});

test('version and help work without a VM runtime', () => {
  const result = run(['--version']);
  expect(result.status, result.stderr).toBe(0);
  expect(result.stdout.trim()).toBe(`sqlite-sbx ${version}`);
  const help = run(['--help']);
  expect(help.status, help.stderr).toBe(0);
  for (const command of ['start', 'stop', 'branch', 'checkout', 'destroy']) expect(help.stdout).toContain(command);
});

test('invalid options fail during parsing before touching the runtime', () => {
  const result = run(['start', '--port', 'not-a-port']);
  expect(result.status).not.toBe(0);
  expect(result.stdout + result.stderr).toContain('not-a-port');
  expect(result.stdout + result.stderr).not.toContain('ENOENT');
});
