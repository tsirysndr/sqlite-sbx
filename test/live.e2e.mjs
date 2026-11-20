// Explicit opt-in; npm test only selects *.test.mjs.
import { test } from 'bun:test';
import { spawn } from 'node:child_process';

test('real SQLite/libSQL server, forwarding, persistence, ZFS branches and cleanup', async () => {
  // Separate process gives the PureScript runner ownership of SIGINT/SIGTERM
  // and lets its Aff finalizers remove the temporary sandbox on interruption.
  await new Promise((resolve, reject) => {
    const child = spawn(process.execPath, ['bin/ci.js', 'e2e'], { stdio: 'inherit', env: process.env });
    const interrupt = () => child.kill('SIGTERM');
    process.on('SIGINT', interrupt); process.on('SIGTERM', interrupt);
    const cleanup = () => { process.off('SIGINT', interrupt); process.off('SIGTERM', interrupt); };
    child.on('error', error => { cleanup(); reject(error); });
    child.on('close', code => { cleanup(); code === 0 ? resolve() : reject(Error(`Live E2E failed (${code})`)); });
  });
}, 1800000);
