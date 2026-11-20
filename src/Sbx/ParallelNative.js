import { randomBytes, createHash } from 'node:crypto';
import { async } from '../Bsdkrun.Internal/foreign.js';
import { mkdirSync, readFileSync, writeFileSync, rmSync, renameSync } from 'node:fs';
import { join } from 'node:path';
import { request } from 'node:http';

export const lock = path => () => {
  try { mkdirSync(path); }
  catch (error) {
    if (error.code !== 'EEXIST') throw error;
    let pid;
    try { pid = JSON.parse(readFileSync(join(path, 'owner.json'), 'utf8')).pid; } catch {}
    if (!Number.isInteger(pid) || pid <= 0) throw Error('Another branch operation is initializing; retry shortly');
    try { process.kill(pid, 0); throw Error('Another branch operation is running; retry after it finishes'); }
    catch (error) { if (error.code !== 'ESRCH') throw error; }
    rmSync(path, { recursive: true }); mkdirSync(path);
  }
  writeFileSync(join(path, 'owner.json'), JSON.stringify({ pid: process.pid }));
};
export const unlock = path => () => rmSync(path, { recursive: true, force: true });

// This is the same gvproxy HTTP API used by bsdkrun's Docker port reconciler.
// bsdkrun publishes the socket path in the VM directory on every boot.
export const forwardImpl = spec => async(signal => new Promise((resolve, reject) => {
  const socketPath = readFileSync(join(spec.stateDir, 'gvproxy-control'), 'utf8').trim();
  const body = JSON.stringify({ local: `127.0.0.1:${spec.port}`, protocol: 'tcp',
    ...(spec.enabled ? { remote: `${spec.ip}:${spec.guestPort}` } : {}) });
  const req = request({ socketPath, method: 'POST', path: `/services/forwarder/${spec.enabled ? 'expose' : 'unexpose'}`,
    headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) }, signal, timeout: 10000 }, res => {
    res.resume(); res.on('end', () => {
      if (res.statusCode === 200 || !spec.enabled) resolve();
      else reject(Error(`gvproxy rejected branch port ${spec.port} (HTTP ${res.statusCode})`));
    });
  });
  req.on('timeout', () => req.destroy(Error('Branch port forwarding timed out')));
  req.on('error', reject); req.end(body);
}));

export const sha256 = text => createHash('sha256').update(text).digest('hex');

// Readers see a complete manifest or selection, even while another CLI writes.
export const writeJson = path => value => () => {
  const staging = `${path}.${process.pid}.${randomBytes(6).toString('hex')}.tmp`;
  try {
    writeFileSync(staging, JSON.stringify(value, null, 2) + '\n', {mode:0o600});
    renameSync(staging, path);
  } finally { rmSync(staging, {force:true}); }
};
