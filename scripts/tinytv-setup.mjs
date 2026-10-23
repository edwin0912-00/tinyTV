#!/usr/bin/env node
// tinyTV setup helper. Node 18+, no npm packages, no paid APIs.
//   node scripts/tinytv-setup.mjs discover [IP]  find TVs (SSDP/DLNA) and say what each one can do
//   node scripts/tinytv-setup.mjs install    install ffmpeg, yt-dlp, node deps (brew on macOS, apt on Linux)
//   node scripts/tinytv-setup.mjs check      check the tools and the torrent engine
//   node scripts/tinytv-setup.mjs config IP  print a config.json for that TV
// Nothing here changes the TV. Install asks before it runs a package manager.
import dgram from 'node:dgram';
import net from 'node:net';
import tls from 'node:tls';
import os from 'node:os';
import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline/promises';
import { execFileSync, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const HISENSE_MQTT = 36669;

// ---------- discover ----------
function ssdp(seconds = 4) {
  return new Promise((resolve) => {
    const found = new Map();
    const sock = dgram.createSocket({ type: 'udp4', reuseAddr: true });
    sock.on('message', (msg, rinfo) => {
      const h = Object.fromEntries(msg.toString().split('\r\n').slice(1)
        .map((l) => l.split(/:\s*/, 2)).filter((p) => p.length === 2).map(([k, v]) => [k.toLowerCase(), v]));
      if (!h.location) return;
      const e = found.get(rinfo.address) || { ip: rinfo.address, locations: new Set(), st: new Set(), server: h.server || '' };
      e.locations.add(h.location); if (h.st) e.st.add(h.st);
      found.set(rinfo.address, e);
    });
    sock.bind(() => {
      for (const st of ['ssdp:all', 'urn:schemas-upnp-org:device:MediaRenderer:1', 'urn:dial-multiscreen-org:service:dial:1']) {
        const m = `M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: "ssdp:discover"\r\nMX: 2\r\nST: ${st}\r\n\r\n`;
        sock.send(m, 1900, '239.255.255.250');
      }
    });
    setTimeout(() => { sock.close(); resolve([...found.values()]); }, seconds * 1000);
  });
}

async function describe(url) {
  try {
    const r = await fetch(url, { signal: AbortSignal.timeout(4000) });
    const x = await r.text();
    const tag = (t) => (x.match(new RegExp(`<${t}>([^<]*)</${t}>`, 'i')) || [])[1] || '';
    const services = [...x.matchAll(/<serviceType>([^<]+)<\/serviceType>/gi)].map((m) => m[1]);
    return { name: tag('friendlyName'), maker: tag('manufacturer'), model: tag('modelName') || tag('modelNumber'),
             type: tag('deviceType'), services, mac: (x.match(/<(?:\w+:)?(?:X_)?MAC[^>]*>([0-9a-f:.-]{12,17})</i) || [])[1] || '' };
  } catch { return null; }
}

function port(ip, p, ms = 1500) {
  return new Promise((resolve) => {
    const s = net.connect({ host: ip, port: p });
    const done = (ok) => { s.destroy(); resolve(ok); };
    s.setTimeout(ms, () => done(false)); s.on('connect', () => done(true)); s.on('error', () => done(false));
  });
}

// TLS without a client certificate: a Hisense TV that needs the RemoteNOW certificate refuses the handshake.
function tlsProbe(ip, p) {
  return new Promise((resolve) => {
    const s = tls.connect({ host: ip, port: p, rejectUnauthorized: false, timeout: 3000 });
    s.on('secureConnect', () => { s.destroy(); resolve('TLS ok without a client certificate'); });
    s.on('error', (e) => resolve(/handshake|certificate|alert/i.test(e.message) ? 'TLS needs a client certificate' : 'TLS error: ' + e.message));
    s.on('timeout', () => { s.destroy(); resolve('TLS timeout'); });
  });
}

function subnet() {
  const ips = [];
  for (const a of Object.values(os.networkInterfaces()).flat())
    if (a && a.family === 'IPv4' && !a.internal && a.netmask === '255.255.255.0') {
      const p = a.address.split('.').slice(0, 3).join('.');
      for (let i = 1; i < 255; i++) if (`${p}.${i}` !== a.address) ips.push(`${p}.${i}`);
    }
  return ips;
}

async function discover(only) {
  console.log('Searching the network (SSDP, 4 s)…');
  const list = (await ssdp()).filter((d) => !only || d.ip === only);
  const tvs = [];
  for (const d of list) {
    const infos = (await Promise.all([...d.locations].map(describe))).filter(Boolean);
    const services = new Set(infos.flatMap((i) => i.services));
    const st = [...d.st].join(' ');
    const renderer = [...services].some((s) => /AVTransport/i.test(s)) || /MediaRenderer/i.test(st);
    const dial = [...services].some((s) => /dial/i.test(s)) || /dial/i.test(st);
    const info = infos.find((i) => i.name) || {};
    const hisense = /hisense|vidaa/i.test(`${info.maker} ${info.name} ${d.server}`);
    if (!renderer && !dial && !hisense) continue;
    const mqtt = await port(d.ip, HISENSE_MQTT);
    tvs.push({ ip: d.ip, name: info.name || '?', maker: info.maker || '?', model: info.model || '', renderer, dial, hisense, mqtt,
               tls: mqtt ? await tlsProbe(d.ip, HISENSE_MQTT) : '', mac: infos.map((i) => i.mac).find(Boolean) || '' });
  }
  // SSDP is multicast: a firewall or macOS Local Network privacy can hide every answer. Then knock on the Hisense
  // MQTT port across this /24 (one TCP connect per address, nothing is sent).
  if (!tvs.some((t) => t.mqtt)) {
    const seen = new Set(tvs.map((t) => t.ip));
    const ips = only ? [only] : subnet();
    if (!only) console.log(`No Hisense in SSDP answers. Checking port ${HISENSE_MQTT} on ${ips.length} addresses…`);
    const open = (await Promise.all(ips.map(async (ip) => (await port(ip, HISENSE_MQTT, 1200)) ? ip : null))).filter(Boolean);
    for (const ip of open.filter((ip) => !seen.has(ip)))
      tvs.push({ ip, name: 'Hisense VIDAA (port scan)', maker: 'Hisense?', model: '', renderer: false, dial: false, hisense: true, mqtt: true,
                 tls: await tlsProbe(ip, HISENSE_MQTT), mac: '', scanned: true });
  }
  if (!tvs.length) { console.log('No TV or DLNA renderer answered. Is the TV on and on this network?'); return []; }
  for (const t of tvs) {
    console.log(`\n${t.name} (${t.maker} ${t.model}) at ${t.ip}`);
    console.log(`  DLNA renderer (casting video):   ${t.renderer ? 'yes' : t.scanned ? 'unknown (SSDP got no answer; VIDAA TVs usually have one)' : 'no'}`);
    console.log(`  DIAL (YouTube app launch):       ${t.dial ? 'yes' : 'no'}`);
    console.log(`  Hisense MQTT :${HISENSE_MQTT} (remote keys): ${t.mqtt ? 'open - ' + t.tls : 'closed'}`);
    if (t.mac) console.log(`  MAC (Wake-on-LAN):               ${t.mac}`);
    const can = [t.renderer && 'cast video/music/screen', t.mqtt && 'remote control after pairing (docs/hisense-pairing.md)', t.dial && 'open YouTube'].filter(Boolean);
    console.log(`  tinyTV can: ${can.join('; ') || 'nothing yet'}`);
  }
  return tvs;
}

// ---------- install / check ----------
const has = (cmd) => spawnSync(process.platform === 'win32' ? 'where' : 'which', [cmd]).status === 0;
const ver = (cmd, args = ['--version']) => { try { return execFileSync(cmd, args, { encoding: 'utf8' }).split('\n')[0].trim(); } catch { return ''; } };

async function install() {
  const need = ['ffmpeg', 'yt-dlp', 'node', 'python3'].filter((c) => !has(c));
  let cmd = null;
  if (process.platform === 'darwin') {
    if (!has('brew')) { console.log('Install Homebrew first: https://brew.sh'); process.exitCode = 1; return; }
    if (need.length) cmd = ['brew', ['install', ...need.map((n) => n === 'python3' ? 'python' : n)]];
  } else if (process.platform === 'linux') {
    if (!has('apt-get')) { console.log(`Install with your package manager: ${need.join(' ')}`); }
    else if (need.length) cmd = ['sudo', ['apt-get', 'install', '-y', ...need.map((n) => n === 'node' ? 'nodejs' : n)]];
  }
  if (cmd) {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    const a = await rl.question(`Run: ${cmd[0]} ${cmd[1].join(' ')} ? [y/N] `); rl.close();
    if (/^y/i.test(a)) spawnSync(cmd[0], cmd[1], { stdio: 'inherit' });
  } else console.log('ffmpeg, yt-dlp, node and python3 are already installed.');
  console.log('\nInstalling the torrent engine (engine/, webtorrent)…');
  spawnSync('npm', ['install', '--omit=dev'], { cwd: path.join(ROOT, 'engine'), stdio: 'inherit' });
  if (process.platform === 'linux') console.log('\nLinux: the engine, DLNA casting and the phone pages run; the Swift core and the menu bar app are macOS only for now.');
  await check();
}

async function check() {
  let ok = true;
  const row = (name, v, hint) => { console.log(`${v ? '✓' : '✗'} ${name.padEnd(10)} ${v || hint}`); if (!v) ok = false; };
  row('node', ver('node'), 'missing: https://nodejs.org');
  row('ffmpeg', ver('ffmpeg', ['-version']), 'missing (brew install ffmpeg / apt install ffmpeg)');
  row('yt-dlp', ver('yt-dlp'), 'missing (brew install yt-dlp / pipx install yt-dlp)');
  row('python3', ver('python3'), 'missing');
  row('webtorrent', fs.existsSync(path.join(ROOT, 'engine/node_modules/webtorrent')) ? 'engine/node_modules' : '', 'run: node scripts/tinytv-setup.mjs install');
  if (process.platform === 'darwin') {
    const hw = spawnSync('ffmpeg', ['-hide_banner', '-encoders'], { encoding: 'utf8' }).stdout || '';
    console.log(`${/hevc_videotoolbox/.test(hw) ? '✓' : '·'} GPU encode  ${/hevc_videotoolbox/.test(hw) ? 'h264/hevc_videotoolbox' : 'not found (software encode is slower)'}`);
  }
  const engine = await fetch('http://127.0.0.1:8890/state', { signal: AbortSignal.timeout(1500) }).then((r) => r.ok).catch(() => false);
  console.log(`${engine ? '✓' : '·'} engine     ${engine ? 'running on :8890' : 'not running (start: node engine/server.mjs)'}`);
  const cfg = path.join(os.homedir(), 'Library/Application Support/tinyTV/config.json');
  console.log(`${fs.existsSync(cfg) ? '✓' : '·'} config     ${fs.existsSync(cfg) ? cfg : 'none yet (node scripts/tinytv-setup.mjs config <TV-IP>)'}`);
  if (!ok) process.exitCode = 1;
}

// MAC of an address this machine has just talked to (the port knock fills the ARP cache).
function macOf(ip) {
  try {
    const out = execFileSync('arp', ['-n', ip], { encoding: 'utf8' });
    const m = out.match(/([0-9a-f]{1,2}(?::[0-9a-f]{1,2}){5})/i);
    return m ? m[1].split(':').map((x) => x.padStart(2, '0')).join('') : '';
  } catch { return ''; }
}

// config [IP] [--write]: print (or, with --write, create when missing) ~/Library/Application Support/tinyTV/config.json.
// An existing config is never overwritten; a missing tv_mac is the only key it may add.
async function config(ip, write) {
  if (!ip) { const tvs = await discover(); ip = (tvs.find((t) => t.mqtt) || tvs[0])?.ip; }
  if (!ip) { process.exitCode = 1; return; }
  const file = path.join(os.homedir(), 'Library/Application Support/tinyTV/config.json');
  const mac = (await port(ip, HISENSE_MQTT, 1500), macOf(ip));
  if (fs.existsSync(file)) {
    const c = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (write && !c.tv_mac && mac && !c.core) { c.tv_mac = mac; fs.writeFileSync(file, JSON.stringify(c, null, 2) + '\n'); console.log(`config: added tv_mac ${mac}`); }
    else console.log(`config: kept ${file}`);
    return;
  }
  const c = { tv: ip, client_id: 'tinytv_core', tv_mac: mac, tvcast: 'http://127.0.0.1:8890', light_url: '' };
  if (!write) { console.log(`\n${file}:\n${JSON.stringify(c, null, 2)}`); return; }
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(c, null, 2) + '\n');
  console.log(`config: created ${file} (TV ${ip}${mac ? ', MAC ' + mac : ''})`);
}

const args = process.argv.slice(2);
const [cmd, arg] = args.filter((a) => !a.startsWith('--'));
const run = { discover: () => discover(arg), install, check, config: () => config(arg, args.includes('--write')) }[cmd];
if (!run) { console.log('usage: node scripts/tinytv-setup.mjs discover [IP] | install | check | config [TV-IP] [--write]'); process.exitCode = 2; }
else await run();
