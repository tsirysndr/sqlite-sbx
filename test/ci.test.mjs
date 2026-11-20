import { test, expect } from 'bun:test';
import { mkdtempSync, readFileSync, rmSync, writeFileSync, chmodSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Left, Right } from '../output/Data.Either/index.js';
import { decode, persist } from '../output/Ci.Environment/index.js';
import { targets, verifyBinary, verifyVersion } from '../output/Ci.Release/index.js';
import { install, verifyDriver } from '../output/Ci.Install/index.js';
import { redact } from '../output/Ci.E2E/index.js';
import { command } from '../output/Ci.Native/index.js';
import { promise } from './support/aff.mjs';

test('PureScript validates the complete setup environment before exporting', async () => {
  const environment = [{ name: 'PATH', value: '/managed/bin:/usr/bin' }, { name: 'BUN_INSTALL', value: '/managed/bun\nextra' }];
  const output = 'tool setup progress\n' + JSON.stringify({ environment }, null, 2) + '\n';
  expect(decode(output)).toBeInstanceOf(Right);
  expect(decode(output).value0).toEqual(environment);
  const dir = mkdtempSync(join(tmpdir(), 'sqlite-sbx-env-test-'));
  try {
    const file = join(dir, 'github-env');
    await promise(persist(output)(file));
    const saved = readFileSync(file, 'utf8');
    expect(saved).toContain('PATH<<fluentci_');
    expect(saved).toContain(environment[1].value);
    const invalid = JSON.stringify({ environment: [environment[0], { name: 'BAD\nINJECTED', value: 'x' }] });
    await expect(promise(persist(invalid)(file))).rejects.toThrow();
    expect(readFileSync(file, 'utf8')).toBe(saved);
    for (const value of ['{"environment":[{"value":"missing-name"}]}', 'logs only', '{"environment":[]}', '{"environment":[{"name":"PATH","value":"\\u0000"}]}']) {
      expect(decode(value)).toBeInstanceOf(Left);
    }
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('PureScript release guards reject mismatched tag and embedded version', () => {
  expect(verifyVersion('v0.1.0')('0.1.0')('sqlite-sbx 0.1.0\n')).toBeInstanceOf(Right);
  expect(verifyVersion('v0.2.0')('0.1.0')('sqlite-sbx 0.1.0')).toBeInstanceOf(Left);
  expect(verifyVersion('v0.1.0')('0.1.0')('sqlite-sbx 0.0.1')).toBeInstanceOf(Left);
});

test('PureScript checks executable headers for all three release targets', () => {
  expect(targets).toHaveLength(3);
  const mac = Buffer.alloc(32); mac.writeUInt32LE(0xfeedfacf); mac.writeUInt32LE(0x0100000c, 4);
  expect(verifyBinary([...mac])('darwin-aarch64')).toBeInstanceOf(Right);
  const elf = Buffer.alloc(32); Buffer.from('7f454c460201', 'hex').copy(elf); elf.writeUInt16LE(62, 18);
  expect(verifyBinary([...elf])('linux-x86_64')).toBeInstanceOf(Right);
  expect(verifyBinary([...elf])('linux-arm64')).toBeInstanceOf(Left);
  elf.writeUInt16LE(183, 18);
  expect(verifyBinary([...elf])('linux-arm64')).toBeInstanceOf(Right);
  expect(verifyBinary([...mac])('linux-x86_64')).toBeInstanceOf(Left);
  expect(verifyBinary([1, 2])('linux-arm64')).toBeInstanceOf(Left);
});

test('PureScript E2E logging redacts every password argument', () => {
  expect(redact(['start', '--password', 'secret', '--port', '9494', '--password', 'other'])).toEqual(['start', '--password', '<redacted>', '--port', '9494', '--password', '<redacted>']);
});


test('installer rejects malformed versions before touching the host', async () => {
  await expect(promise(install('latest; unsafe'))).rejects.toThrow('Expected a bsdkrun release');
});

test('CI requires native overlay storage on ext4 and rejects VFS', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'sqlite-sbx-driver-test-'));
  const savedPath = process.env.PATH;
  const savedDriver = process.env.SBX_TEST_DRIVER;
  const savedFs = process.env.SBX_TEST_FS;
  try {
    const runtime = join(dir, 'bsdkrun');
    const docker = join(dir, 'docker');
    writeFileSync(runtime, '#!/usr/bin/env node\nconsole.log(process.argv.includes("exec") ? (process.env.SBX_TEST_FS || "ext2/ext3") : JSON.stringify({socket:"/fake/docker.sock"}));\n');
    writeFileSync(docker, '#!/usr/bin/env node\nconsole.log(process.env.SBX_TEST_DRIVER);\n');
    chmodSync(runtime, 0o755); chmodSync(docker, 0o755);
    process.env.PATH = dir + ':' + savedPath;
    process.env.SBX_TEST_DRIVER = 'overlayfs';
    await promise(verifyDriver(runtime));
    process.env.SBX_TEST_DRIVER = 'overlay2';
    await promise(verifyDriver(runtime));
    process.env.SBX_TEST_DRIVER = 'vfs';
    await expect(promise(verifyDriver(runtime))).rejects.toThrow('VFS is not allowed');
    process.env.SBX_TEST_DRIVER = 'overlayfs';
    process.env.SBX_TEST_FS = 'virtiofs';
    await expect(promise(verifyDriver(runtime))).rejects.toThrow('must remain ext4');
  } finally {
    process.env.PATH = savedPath;
    if (savedFs === undefined) delete process.env.SBX_TEST_FS; else process.env.SBX_TEST_FS = savedFs;
    if (savedDriver === undefined) delete process.env.SBX_TEST_DRIVER; else process.env.SBX_TEST_DRIVER = savedDriver;
    rmSync(dir, { recursive: true, force: true });
  }
});


test('process output is streamed as well as captured', async () => {
  const streamed = [];
  const result = await promise(command({program:process.execPath,args:['-e','console.log("stdout-progress"); console.error("stderr-progress")'],env:{},cwd:'',timeout:5000,output:chunk=>()=>streamed.push(chunk)}));
  expect(streamed.join('')).toContain('stdout-progress');
  expect(streamed.join('')).toContain('stderr-progress');
  expect(result.stdout).toContain('stdout-progress');
  expect(result.stderr).toContain('stderr-progress');
});

test('process timeout settles even when a detached descendant holds output pipes', async () => {
  const started = Date.now();
  const source = 'const {spawn}=require("node:child_process"); spawn(process.execPath,["-e","setTimeout(()=>{},1500)"],{detached:true,stdio:"inherit"}).unref();';
  await expect(promise(command({program:process.execPath,args:['-e',source],env:{},cwd:'',timeout:250,output:()=>()=>{}}))).rejects.toThrow('timed out');
  expect(Date.now()-started).toBeLessThan(1200);
});
