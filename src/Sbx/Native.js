import * as SDK from "@bsdkrun/sdk";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { createInterface } from "node:readline";
import { spawn, execFile } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync, rmSync, chmodSync, readdirSync } from "node:fs";
import { dirname } from "node:path";
import { homedir } from "node:os";
import { join, delimiter } from "node:path";
import { fileURLToPath } from "node:url";
import { async } from "../Bsdkrun.Internal/foreign.js";

export const confirmImpl = question => async(signal => new Promise(resolve => {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  rl.question(question, answer => { rl.close(); resolve(/^y(es)?$/i.test(answer.trim())); });
  signal.addEventListener("abort", () => { rl.close(); resolve(false); });
}));

export const spawnInheritImpl = cmd => args => env => cwd => async(signal => new Promise((resolve, reject) => {
  const child = spawn(cmd, args, { stdio: "inherit", env: { ...process.env, ...env }, cwd: cwd ?? undefined });
  signal.addEventListener("abort", () => child.kill());
  child.on("error", reject);
  child.on("exit", (code, sig) => resolve(code ?? (sig ? 128 : 1)));
}));

export const isTty = () => Boolean(process.stdin.isTTY && process.stdout.isTTY);
export const nodeVersion = () => process.version;
export const nodePath = () => process.execPath;
export const configDir = tool => () => {
  const dir = join(process.env.XDG_CONFIG_HOME || join(homedir(), ".config"), tool);
  mkdirSync(dir, { recursive: true });
  return dir;
};
// output/Sbx.Native/foreign.js -> the package root.
export const toolRoot = () => fileURLToPath(new URL("../../", import.meta.url));
export const cwd = () => process.cwd();
export const pathJoin = a => b => join(a, b);
export const readJson = path => () => {
  try { return JSON.parse(readFileSync(path, "utf8")); } catch { return null; }
};
export const writeJson = path => value => () => writeFileSync(path, JSON.stringify(value, null, 2) + "\n");
export const writeText = path => text => () => writeFileSync(path, text);
export const removeFile = path => () => rmSync(path, { force: true });
export const fileExists = path => () => existsSync(path);
export const encodeURIComponent = s => globalThis.encodeURIComponent(s);
export const writeStdout = bytes => () => { process.stdout.write(bytes); };
export const writeStderr = bytes => () => { process.stderr.write(bytes); };
export const findExecutable = name => () => {
  for (const dir of (process.env.PATH || "").split(delimiter)) {
    if (dir && existsSync(join(dir, name))) return join(dir, name);
  }
  return null;
};
export const captureImpl = cmd => args => async(signal => new Promise(resolve => {
  execFile(cmd, args, { signal, maxBuffer: 16 * 1024 * 1024 }, (err, stdout, stderr) =>
    resolve({ stdout: String(stdout ?? ""), stderr: String(stderr ?? err?.message ?? ""), exitCode: err ? (typeof err.code === "number" ? err.code : 1) : 0 }));
}));
export const fetchTextImpl = url => async(async signal => {
  const res = await fetch(url, { signal, headers: { "user-agent": "db-sbx" } });
  if (!res.ok) throw new Error(`GET ${url}: ${res.status} ${res.statusText}`);
  return res.text();
});
export const downloadImpl = url => dest => async(async signal => {
  const res = await fetch(url, { signal, headers: { "user-agent": "db-sbx" } });
  if (!res.ok) throw new Error(`GET ${url}: ${res.status} ${res.statusText}`);
  mkdirSync(dirname(dest), { recursive: true });
  writeFileSync(dest, Buffer.from(await res.arrayBuffer()));
  chmodSync(dest, 0o755);
});
export const homeDir = () => homedir();
export const mkdirp = dir => () => { mkdirSync(dir, { recursive: true }); };
export const platform = () => ({
  os: process.platform === "darwin" ? "macos" : process.platform === "win32" ? "win" : "linux",
  arch: process.arch === "arm64" ? "arm64" : process.arch === "x64" ? "amd64" : process.arch,
});
export const listDir = dir => () => { try { return readdirSync(dir); } catch { return []; } };

// gvproxy processes holding `port` whose spawning bsdkrun (the pid in their
// socket directory) is gone: bsdkrun does not reap them when a machine stops
// or exits, and the stale forward then blocks the next boot. Returns the pids
// killed.
export const reapOrphanGvproxies = port => () => {
  const run = (cmd, args) => { try { return execFileSync(cmd, args, { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }); } catch { return ""; } };
  const alive = pid => { try { process.kill(pid, 0); return true; } catch (e) { return e.code !== "ESRCH"; } };
  const killed = [];
  for (const pid of run("lsof", ["-nP", `-iTCP:${port}`, "-sTCP:LISTEN", "-t"]).split(/\s+/).filter(Boolean)) {
    const m = /gvproxy.*bsdkrun-net-(\d+)/.exec(run("ps", ["-o", "command=", "-p", pid]));
    if (!m || alive(Number(m[1]))) continue;
    try { process.kill(Number(pid)); killed.push(Number(pid)); } catch {}
  }
  return killed;
};

// Colour only on a terminal, and not when NO_COLOR asks for plain output.
export const colorOutput = () => Boolean(process.stdout.isTTY) && !process.env.NO_COLOR;
export const ansi = code => text => `\x1b[${code}m${text}\x1b[0m`;

export const sha256 = text => createHash("sha256").update(text).digest("hex");

// Generic SDK bridge: keeps preflight library paths, binary resolution,
// cancellation and output forwarding identical to other SDK operations.
export const runBsdkrunImpl = args => async(async signal => {
  const result = await SDK.runCli(args, {
    signal,
    onStdout: chunk => process.stdout.write(chunk),
    onStderr: chunk => process.stderr.write(chunk),
  });
  return result.exitCode;
});
