import { test, expect } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { Status, Checkout } from '../output/Sbx.Cli/index.js';
import { mkdirSync } from 'node:fs';
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Just, Nothing } from '../output/Data.Maybe/index.js';
import { run, selectPort } from '../output/Sbx.Parallel/index.js';
import { instanceName, volumeName, validName } from '../output/Sbx.Identity/index.js';
import { script } from '../output/Sbx.BsdServer/index.js';
import { writeJson, forward, lock, unlock } from '../output/Sbx.ParallelNative/index.js';
import { profile } from '../output/Sbx.Sqlite/index.js';
import { promise } from './support/aff.mjs';

test('automatic ports skip stopped reservations and listeners, explicit collisions fail', async () => {
  const choose = selectPort([5432, 5433])(n => PromiseAff(n !== 5434));
  expect(await promise(choose(Nothing.value)(5432))).toBe(5435);
  await expect(promise(choose(new Just(5433))(5432))).rejects.toThrow('reserved');
  await expect(promise(choose(new Just(5434))(5432))).rejects.toThrow('in use');
  for (const n of [0, -1, 65536]) await expect(promise(choose(new Just(n))(5432))).rejects.toThrow('between');
  await expect(promise(selectPort([65535])(n => PromiseAff(true))(Nothing.value)(65535))).rejects.toThrow('No free');
});
// Pure Aff construction, without adding another FFI or subprocess.
import { applicativeAff } from '../output/Effect.Aff/index.js';
const PromiseAff = value => applicativeAff.pure(value);

test('runtime identities share one pool and cannot collide through punctuation or nesting', () => {
  const a = instanceName('test-sbx')('feature-a'), b = instanceName('test-sbx')('feature_a');
  expect(a).not.toBe(b); expect(volumeName(a)).toBe('test-sbx');
  expect(instanceName(a)('nested')).toBe(instanceName('test-sbx')('nested'));
  for (const name of ['../escape', 'a/b', '-bad', '.bad', 'main', 'ls', 'mirror', 'c0bad', 'a'.repeat(65)]) expect(validName(name)).toBe(false);
  expect(validName('feature-1.2_test')).toBe(true);
});

test('branch metadata lock rejects overlap and reclaims a dead owner', () => {
  const dir = mkdtempSync(join(tmpdir(), 'sbx-lock-')), path = join(dir, 'lock');
  try {
    lock(path)(); expect(() => lock(path)()).toThrow('running'); unlock(path)();
    lock(path)(); writeFileSync(join(path, 'owner.json'), JSON.stringify({pid: 2147483647}));
    lock(path)(); unlock(path)();
  } finally { rmSync(dir, {recursive:true,force:true}); }
});

test('BSD start scripts have valid syntax and separate data, ports, PID files and sockets', () => {
  for (const os of ['freebsd','netbsd']) for (const product of ['PostgreSQL','MariaDB']) {
    const p = {...profile, product, tool:'test-sbx.branch-fork'};
    const st = {os,port:15433,user:'example',password:'never-log-this',db:'db',branch:'fork'};
    for (const action of ['start','stop','status']) {
      const body = script(p)(st)(action), parsed = spawnSync('/bin/sh', ['-n'], {input:body,encoding:'utf8'});
      expect(parsed.status, parsed.stderr).toBe(0);
      if (action === 'start') { expect(body).toContain('/mnt/test-sbx.branch-fork'); expect(body).toContain('15433'); expect(body).not.toContain(st.password); }
    }
    if (product === 'PostgreSQL') expect(script(p)(st)('start')).toContain("sed -n '2p'");
    else expect(script(p)(st)('stop')).toContain('ps -ww');
  }
});

test('BSD port forwards use the current VM socket and bind only loopback', async () => {
  const { createServer } = await import('node:http');
  const dir = mkdtempSync(join(tmpdir(), 'sbx-forward-')), socket = join(dir, 'control.sock');
  const requests = [], server = createServer((req,res) => { let text=''; req.on('data', chunk => text+=chunk); req.on('end',()=>{ requests.push({path:req.url,...JSON.parse(text)}); res.end(); }); });
  try {
    await new Promise(resolve => server.listen(socket,resolve));
    writeFileSync(join(dir,'gvproxy-control'),socket);
    await promise(forward({stateDir:dir,ip:'192.168.127.2',port:15433,guestPort:15433,enabled:true}));
    await promise(forward({stateDir:dir,ip:'192.168.127.2',port:15433,guestPort:15433,enabled:false}));
    expect(requests).toEqual([
      {path:'/services/forwarder/expose',local:'127.0.0.1:15433',remote:'192.168.127.2:15433',protocol:'tcp'},
      {path:'/services/forwarder/unexpose',local:'127.0.0.1:15433',protocol:'tcp'},
    ]);
  } finally { await new Promise(resolve => server.close(resolve)); rmSync(dir,{recursive:true,force:true}); }
});

test('a missing selected branch fails closed; checkout can recover the selection', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'sbx-selection-')), saved = process.env.XDG_CONFIG_HOME;
  const local = {...profile, tool:'selection-test'};
  const calls = [], fake = p => cmd => { calls.push(p.tool); return applicativeAff.pure(0); };
  try {
    process.env.XDG_CONFIG_HOME = dir;
    const config = join(dir, local.tool); mkdirSync(config);
    writeJson(join(config, 'active.json'))('removed')();
    await expect(promise(run(fake)(local)(Status.value))).rejects.toThrow('Selected branch is missing');
    expect(calls).toEqual([]);
    await promise(run(fake)(local)(new Checkout({name:'main',create:false})));
    expect(calls).toEqual([local.tool]);
    expect(() => readFileSync(join(config,'active.json'))).toThrow();
  } finally {
    if (saved === undefined) delete process.env.XDG_CONFIG_HOME; else process.env.XDG_CONFIG_HOME = saved;
    rmSync(dir,{recursive:true,force:true});
  }
});
