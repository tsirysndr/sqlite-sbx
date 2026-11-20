import './bootstrap.mjs';
import { mkdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';

function command(program, args) {
  const result = spawnSync(program, args, { stdio: 'inherit' });
  if (result.error) throw result.error;
  if (result.status !== 0) throw Error(`${program} failed with exit status ${result.status}`);
}
command('npm', ['ci', '--no-audit', '--no-fund']);
command('spago', ['build']);
mkdirSync('dist', { recursive: true });
const { buildPlugin } = await import('@fluentci/inspection');
await buildPlugin({ sdk: 'purescript', runtime: 'component' });
