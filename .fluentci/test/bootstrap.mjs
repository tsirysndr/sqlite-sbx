// SDK sources are embedded in the pinned FluentCI CLI. Regenerate them rather
// than checking a second copy of FluentCI's SDK into this repository.
import { cpSync, existsSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

const here = new URL('./', import.meta.url);
if (!existsSync(new URL('.sdk/inspection/index.mjs', here))) {
  const version = spawnSync('fluentci', ['--version'], { encoding: 'utf8' });
  if (version.status !== 0 || version.stdout.trim() !== 'fluentci 0.17.8') {
    throw Error('The test SDK is pinned to FluentCI 0.17.8; install that CLI before building it.');
  }
  const scratch = mkdtempSync(join(tmpdir(), 'sqlite-sbx-fluentci-sdk-'));
  try {
    const result = spawnSync('fluentci', ['--check-update=false', 'init', 'test', '--sdk', 'purescript', '--database', join(scratch, 'fluentci.sqlite')], { cwd: scratch, stdio: 'inherit' });
    if (result.error) throw result.error;
    if (result.status !== 0) throw Error('FluentCI SDK scaffolding failed');
    cpSync(join(scratch, '.fluentci/test/.sdk'), new URL('.sdk', here), { recursive: true });
  } finally { rmSync(scratch, { recursive: true, force: true }); }
}
