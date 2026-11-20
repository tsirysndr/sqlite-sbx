// Before the first PureScript build: apply the setup module's typed environment
// only to npm's child process. The compiled CI code validates and exports it
// to GitHub after npm ci has built the project. No release/test policy here.
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
const output = readFileSync(process.argv[2], 'utf8');
process.stdout.write(output);
const lines = output.trimEnd().split('\n');
let result;
for (let i = 0; i < lines.length; i++) {
  try { result = JSON.parse(lines.slice(i).join('\n')); break; } catch {}
}
if (!Array.isArray(result?.environment) || !result.environment.length) throw Error('Missing setup environment');
const environment = Object.fromEntries(result.environment.map(({ name, value }) => {
  if (typeof name !== 'string' || !/^[A-Za-z_][A-Za-z0-9_]*$/.test(name) || typeof value !== 'string' || value.includes('\0')) throw Error('Invalid setup environment');
  return [name, value];
}));
const child = spawnSync('npm', ['ci'], { env: { ...process.env, ...environment }, stdio: 'inherit' });
if (child.error) throw child.error;
process.exitCode = child.status ?? 1;
