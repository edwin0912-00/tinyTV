// TV Cast - tiny magnet->TV streamer with buffer gauges.
// Watches the clipboard for a magnet link, streams it at original quality,
// casts to a DLNA TV if one is found, and reports buffer fill for Mac + TV.
import http from 'node:http';
import os from 'node:os';
import fs from 'node:fs';
import path from 'node:path';
import dgram from 'node:dgram';
import { execFile, spawn } from 'node:child_process';
import WebTorrent from 'webtorrent';

const PORT = Number(process.env.PORT || 8890);
// Owner (tinyTV): downloads live in ~/Downloads/Torrent so they can be found, kept or deleted.
const TMP = process.env.TVCAST_DIR || path.join(os.homedir(), 'Downloads', 'Torrent');
// Owner: the external SSD is the main store; the internal folder is the fallback when it is not mounted.
const SSD = process.env.TVCAST_EXTERNAL || '';   // optional external disk
function storeDir() {
  try { fs.accessSync(SSD, fs.constants.W_OK); const d = path.join(SSD, 'Torrent'); fs.mkdirSync(d, { recursive: true }); return d; }
  catch { return TMP; }
}
fs.mkdirSync(TMP, { recursive: true });

const client = new WebTorrent({ dht: true, lsd: true, webSeeds: true });
const VIDEO_RE = /\.(mp4|mkv|m4v|webm|avi|mov|ts|m2ts)$/i;

// Big public tracker list bolted onto every torrent — webtorrent otherwise
// finds very few peers on ordinary magnets. Dramatically widens the swarm.
const TRACKERS = [
  'udp://tracker.opentrackr.org:1337/announce',
  'udp://open.tracker.cl:1337/announce',
  'udp://open.demonii.com:1337/announce',
  'udp://tracker.torrent.eu.org:451/announce',
  'udp://exodus.desync.com:6969/announce',
  'udp://tracker.openbittorrent.com:6969/announce',
  'udp://explodie.org:6969/announce',
  'udp://tracker.dler.org:6969/announce',
  'udp://opentracker.i2p.rocks:6969/announce',
  'udp://tracker.tiny-vps.com:6969/announce',
  'udp://tracker.moeking.me:6969/announce',
  'udp://p4p.arenabg.com:1337/announce',
  'udp://tracker.theoks.net:6969/announce',
  'udp://movies.zsw.ca:6969/announce',
  'http://tracker.openbittorrent.com:80/announce',
  'https://tracker.tamersunion.org:443/announce',
  'wss://tracker.openwebtorrent.com',
  'wss://tracker.btorrent.xyz',
];

// never let a torrent/client error take the whole app down
client.on('error', (e) => { state.error = String(e && e.message || e); });
process.on('uncaughtException', (e) => { state.error = String(e && e.message || e); });
process.on('unhandledRejection', (e) => { state.error = String(e && e.message || e); });

// ---- shared state the UI polls ----
const state = {
  lanIP: lanIP(),
  host: null,        // stable bonjour name, e.g. My-Mac.local
  port: PORT,
  playURL: null,     // stable URL to save on the TV / open on Xbox
  ipURL: null,       // fallback by current IP
  magnet: null,
  name: null,
  fileName: null,
  fileBytes: 0,
  durationSec: 0,
  progress: 0,          // 0..1 whole file
  downloadedBytes: 0,
  downSpeed: 0,
  peers: 0,
  playheadByte: 0,      // last byte the player asked for
  macAheadBytes: 0,     // contiguous downloaded ahead of playhead
  macAheadSec: 0,
  tv: { found: false, name: null, casting: false, posSec: 0, aheadSec: 0 },
  error: null,
};

// ---- pick + track the active video file ----
let activeTorrent = null;
let activeFile = null;
let fileStartByte = 0;

// ---- background downloads (tinyTV list: "На фоні" / "Стоп і видалити") ----
// A torrent marked background keeps downloading when a new magnet comes; the list survives engine restarts.
const BG_FILE = path.join(TMP, '.background.json');
const background = new Map();   // infoHash -> {magnet, path}
try { for (const [h, v] of Object.entries(JSON.parse(fs.readFileSync(BG_FILE, 'utf8'))))
  background.set(h, typeof v === 'string' ? { magnet: v, path: TMP } : v); } catch {}
const saveBg = () => { try { fs.writeFileSync(BG_FILE, JSON.stringify(Object.fromEntries(background))); } catch {} };
// Map of downloaded pieces per torrent, saved every 30 s: re-adding uses it instead of re-hashing the whole file
// (skipVerify would mark every piece as present and the TV would get zeros for what was never downloaded).
const BITS = path.join(TMP, '.bits'); try { fs.mkdirSync(BITS, { recursive: true }); } catch {}
function savedBits(h) { try { return h ? new Uint8Array(fs.readFileSync(path.join(BITS, h.toLowerCase()))) : undefined; } catch { return undefined; } }
setInterval(() => { for (const t of client.torrents) { try { if (t.bitfield && t.bitfield.buffer) fs.writeFileSync(path.join(BITS, t.infoHash), Buffer.from(t.bitfield.buffer)); } catch {}
  // Metadata too: after a restart the torrent is back at once (name, size, done) without waiting for peers.
  try { const m = path.join(BITS, t.infoHash + '.torrent'); if (t.torrentFile && !fs.existsSync(m)) fs.writeFileSync(m, t.torrentFile); } catch {} } }, 30e3);
function savedMeta(h) { try { return fs.readFileSync(path.join(BITS, h.toLowerCase() + '.torrent')); } catch { return null; } }
// Owner: checking files must not take the server down. Background torrents come back 10 s after start, one every
// 5 s, trusting what is on disk (skipVerify) - a full re-hash of a 28 GB file blocked HTTP for minutes.
setTimeout(() => { let k = 0; for (const [h, b] of background) { setTimeout(() => { try {
  if (client.torrents.find(t => t.infoHash === h)) return;
  const t = client.add(savedMeta(h) || b.magnet, { path: fs.existsSync(b.path) ? b.path : storeDir(), announce: TRACKERS, bitfield: savedBits(h) });
  t.on('ready', () => { const v = t.files.filter(f => VIDEO_RE.test(f.name)); const big = (v.length ? v : t.files).sort((a, b) => b.length - a.length)[0];
    t.files.forEach(f => (f === big ? f.select() : f.deselect())); }); } catch {} }, 5000 * k++); } }, 10000);

// tinyTV: download in order from where the TV plays. The next ~2 min are critical (fetched first, in order),
// the rest of the file from the playhead on gets a higher priority than what lies behind it.
let prioPiece = -1, throttled = -1, lastAhead = 0;
// Nobody watching (no /ahead for 15 s): background downloads go at full speed again.
setInterval(() => { if (throttled !== -1 && Date.now() - lastAhead > 15000) { throttled = -1; try { client.throttleDownload(-1); } catch {} } }, 5000);
function prioritize(byte) {
  const t = activeTorrent; if (!t || !activeFile || !t.pieceLength) return;
  const pl = t.pieceLength, start = Math.floor((fileStartByte + Math.max(0, byte)) / pl);
  const last = Math.ceil((fileStartByte + activeFile.length) / pl) - 1;
  if (Math.abs(start - prioPiece) < 2) return;
  prioPiece = start;
  const bps = bytesPerSec() || 8e6, win = Math.max(16, Math.ceil(bps * 120 / pl));
  try { t.select(start, last, 1); } catch {}
  try { t.critical(start, Math.min(last, start + win)); } catch {}
}

// Owner: clean up what was watched. Seen to 90 % and not continued for 10 min -> files go, unless "На фоні".
const watched = { hash: null, sec: 0, at: 0 };
setInterval(() => {
  const t = activeTorrent;
  if (!t || watched.hash !== t.infoHash || background.has(t.infoHash) || !state.durationSec) return;
  if (watched.sec >= 0.9 * state.durationSec && Date.now() - watched.at > 10 * 60e3) {
    activeTorrent = null; activeFile = null; state.name = ''; state.fileName = null; state.fileBytes = 0; watched.hash = null;
    log('remove watched', t.infoHash);
    try { const r = client.remove(t, { destroyStore: true }); if (r && r.catch) r.catch(() => {}); } catch {}
  }
}, 30e3);

const paused = new Set();
function listTorrents() {
  return client.torrents.map(t => {
    const sel = t.files ? t.files.filter(f => VIDEO_RE.test(f.name)).sort((a, b) => b.length - a.length)[0] : null;
    // No metadata yet (just restarted, few peers) but the file is complete on disk: it is done, show it so.
    if (!sel && t.name) { try { const b = background.get(t.infoHash), st = fs.statSync(path.join((b && b.path) || storeDir(), t.name));
      if (st.isFile() && st.size > 0) return { hash: t.infoHash, name: t.name, size: st.size, progress: 1, down: 0, up: 0, peers: t.numPeers,
        active: t === activeTorrent, paused: paused.has(t.infoHash), background: background.has(t.infoHash), done: true, magnet: t.magnetURI, eta: -1 }; } catch {} }
    return { hash: t.infoHash, name: t.name || 'отримую метадані…', size: sel ? sel.length : (t.length || 0),
      progress: sel ? sel.progress : t.progress, down: t.downloadSpeed, up: t.uploadSpeed, peers: t.numPeers,
      active: t === activeTorrent, paused: paused.has(t.infoHash), background: background.has(t.infoHash), done: t.done, magnet: t.magnetURI,
      eta: t.downloadSpeed > 0 && sel ? Math.round(sel.length * (1 - sel.progress) / t.downloadSpeed) : -1 };
  });
}

function lanIP() {
  const ifs = os.networkInterfaces();
  for (const name of ['en0', 'en1', ...Object.keys(ifs)]) {
    for (const a of ifs[name] || []) {
      if (a.family === 'IPv4' && !a.internal && !a.address.startsWith('169.254')) return a.address;
    }
  }
  return '127.0.0.1';
}

function streamURL() {
  return `http://${state.lanIP}:${PORT}/stream`;
}

// Primary URL = numeric IP (resolves on ANY device: TV, Xbox, Windows, phone).
// .local is kept only as a secondary option for Apple devices that do mDNS.
state.ipURL = `http://${state.lanIP}:${PORT}/play`;
state.playURL = state.ipURL;
// A router reboot hands out new addresses (2026-10-21: .42 -> .40 -> .36): follow the current one.
setInterval(() => { const ip = lanIP(); if (ip && ip !== state.lanIP) { console.log("tinytv: LAN address " + state.lanIP + " -> " + ip); state.lanIP = ip; state.ipURL = `http://${ip}:${PORT}/play`; state.playURL = state.ipURL; } }, 30000);
execFile('scutil', ['--get', 'LocalHostName'], { timeout: 3000 }, (err, out) => {
  const h = (out || '').trim();
  state.host = h ? `http://${h}.local:${PORT}/play` : null;
});

function infoHashOf(magnet) {
  const m = /btih:([0-9a-fA-F]{40})/.exec(magnet) || /btih:([a-z2-7]{32})/i.exec(magnet);
  return m ? m[1].toLowerCase() : null;
}

function log(...a) { console.log(new Date().toISOString().slice(11, 19), 'tinytv:', ...a); }

// "2x18" -> the file whose name says S02E18 / 2x18 / "Сезон 2 ... Серія 18"; null when none matches.
let wantEp = null;
function episodeFile(files, ep) {
  const m = /^(\d+)x(\d+)$/.exec(ep || ''); if (!m || !files.length) return null;
  const s = +m[1], e = +m[2];
  const res = [new RegExp(`s0*${s}[ ._-]*e0*${e}(?!\\d)`, 'i'), new RegExp(`(^|[^\\d])0*${s}x0*${e}(?!\\d)`, 'i')];
  for (const re of res) { const f = files.find(x => re.test(x.path || x.name)); if (f) return f; }
  const inSeason = files.filter(x => new RegExp(`(s|season|сезон)[ ._-]*0*${s}(?!\\d)`, 'i').test(x.path || x.name));
  return inSeason.find(x => new RegExp(`(e|ep|episode|серія|серия)[ ._-]*0*${e}(?!\\d)`, 'i').test(x.name)) || null;
}
async function addMagnet(magnet) {
  log('add', infoHashOf(magnet), 'active', activeTorrent && activeTorrent.infoHash);
  // drop previous
  const ih = infoHashOf(magnet);
  // The previous one goes unless the owner kept it on in the background (or it is this very torrent).
  if (activeTorrent && activeTorrent.infoHash !== ih && !background.has(activeTorrent.infoHash)) { log('remove previous', activeTorrent.infoHash); try { await client.remove(activeTorrent, { destroyStore: true }); } catch {} }
  // Already held (a background download or a repeat): make it the active one instead of removing and re-adding.
  let held = ih ? client.torrents.find(t => t.infoHash === ih) : null;
  // Held but still without metadata (an earlier bare magnet, no working tracker): drop it (files stay) and add this
  // magnet, which may carry the trackers that have the peers.
  if (held && !(held.files && held.files.length)) {
    log('re-add without metadata', ih);
    await new Promise(r => { setTimeout(r, 3000); try { const p = client.remove(held, { destroyStore: false }, () => r()); if (p && p.then) p.then(r, r); } catch { r(); } });
    held = null;
  }
  if (held) {
    activeTorrent = null; activeFile = null; fileStartByte = 0; prioPiece = -1;
    Object.assign(state, { magnet, name: held.name || 'отримую метадані…', fileName: null, fileBytes: 0, durationSec: 0, error: null,
      playheadByte: 0, macAheadBytes: 0, macAheadSec: 0 });
    // Metadata already there (files listed) = ready; waiting for a 'ready' event that has fired would hang.
    if (held.ready || (held.files && held.files.length)) onReady(held); else held.once('ready', () => onReady(held));
    return;
  }
  activeTorrent = null; activeFile = null; fileStartByte = 0;
  Object.assign(state, {
    magnet, name: 'отримую метадані…', fileName: null, fileBytes: 0,
    durationSec: 0, progress: 0, downloadedBytes: 0, downSpeed: 0, peers: 0,
    playheadByte: 0, macAheadBytes: 0, macAheadSec: 0, error: null,
  });
  state.tv.casting = false; state.tv.posSec = 0; state.tv.aheadSec = 0;

  let torrent;
  // Files already on disk for this torrent: trust them (a full re-hash blocks the server for minutes).
  try { torrent = client.add(magnet, { path: storeDir(), announce: TRACKERS, bitfield: savedBits(infoHashOf(magnet)) }); }
  catch (e) { state.error = String(e && e.message || e); return; }
  torrent.on('error', (e) => { state.error = String(e && e.message || e); log('torrent error', state.error); });
  torrent.on('metadata', () => {}); // ensure listener set early
  torrent.on('ready', () => onReady(torrent));
}

function onReady(torrent) {
  {
    activeTorrent = torrent; prioPiece = -1;
    state.name = torrent.name;
    // The asked episode in a season pack (tinyTV sends ep=2x18), else the largest video file. Owner 2026-10-23: S2E18 was
    // asked, the pack's biggest file (a double finale s03e23) played.
    const vids = torrent.files.filter(f => VIDEO_RE.test(f.name));
    const hit = episodeFile(vids, wantEp);
    // An episode was asked and this pack has several videos but not that one: say so, never play another episode.
    if (wantEp && !hit && vids.length > 1) {
      state.error = `У роздачі немає серії ${wantEp.replace(/^(\d+)x(\d+)$/, (_, s, e) => 'S' + s.padStart(2, '0') + 'E' + e.padStart(2, '0'))}`;
      state.fileName = null; log('no episode', wantEp, torrent.infoHash); return;
    }
    activeFile = hit || (vids.length ? vids : torrent.files).sort((a, b) => b.length - a.length)[0];
    // compute byte offset of this file within the torrent (files are contiguous)
    let acc = 0;
    for (const f of torrent.files) { if (f === activeFile) { fileStartByte = acc; break; } acc += f.length; }
    // stream this file, deprioritize the rest
    torrent.files.forEach(f => (f === activeFile ? f.select() : f.deselect()));
    state.fileName = activeFile.name;
    state.fileBytes = activeFile.length;
    probeDuration();
    // if a TV is already known, start casting
    if (state.tv.found) castToTV();
  }
}

// duration via ffprobe over HTTP /probe: ffprobe issues Range requests and
// pulls the tail (moov atom) itself, without disturbing the player's playhead.
// One ffprobe at a time: the 1 s timer called this while the duration stayed unknown, each call started its own
// ffprobe and 40-try chain, and 600+ processes filled the user's limit (sshd, yt-dlp failed; 2026-10-22).
let probing = false;
function probeDuration(tries = 0) {
  if (!activeFile || state.durationSec || tries > 40 || (probing && tries === 0)) return;
  probing = true;
  const src = `http://127.0.0.1:${PORT}/probe`;
  execFile('ffprobe', ['-v', 'error', '-show_entries', 'format=duration',
    '-of', 'default=nw=1:nk=1', src], { timeout: 15000 }, (err, out) => {
    const d = parseFloat((out || '').trim());
    if (d > 0 || tries >= 40) { probing = false; if (d > 0) state.durationSec = d; }
    else setTimeout(() => probeDuration(tries + 1), 4000);
  });
}

function bytesPerSec() {
  return state.durationSec > 0 ? state.fileBytes / state.durationSec : 0;
}

// contiguous downloaded bytes from a given byte offset within the active file
function aheadFrom(playheadByte) {
  const t = activeTorrent;
  if (!t || !activeFile) return 0;
  const pieceLen = t.pieceLength;
  const absStart = fileStartByte + Math.min(playheadByte, activeFile.length);
  const fileEndAbs = fileStartByte + activeFile.length;
  let piece = Math.floor(absStart / pieceLen);
  const lastPiece = Math.ceil(fileEndAbs / pieceLen) - 1;
  let contiguousEnd = absStart;
  for (; piece <= lastPiece; piece++) {
    const has = t.bitfield && t.bitfield.get(piece);
    if (!has) break;
    contiguousEnd = Math.min((piece + 1) * pieceLen, fileEndAbs);
  }
  return Math.max(0, contiguousEnd - absStart);
}

// ---- refresh derived numbers ----
setInterval(() => {
  const t = activeTorrent;
  if (t) {
    state.progress = t.progress;
    state.downloadedBytes = t.downloaded;
    state.downSpeed = t.downloadSpeed;
    state.peers = t.numPeers;
    state.macAheadBytes = aheadFrom(state.playheadByte);
    const bps = bytesPerSec();
    state.macAheadSec = bps ? state.macAheadBytes / bps : 0;
    if (state.tv.casting && bps) {
      // TV buffer estimate: contiguous-from-start seconds minus TV playhead
      const contiguousFromStartSec = aheadFrom(0) / bps;
      state.tv.aheadSec = Math.max(0, contiguousFromStartSec - state.tv.posSec);
    }
  }
  if (!state.durationSec) probeDuration();
}, 1000);

// ---- clipboard watcher ----
let lastClip = '', seenClip = null;
// tinyTV: react only when the clipboard itself changes. Comparing with the last *added* magnet made an old magnet
// left in the clipboard replace (and delete) every torrent tinyTV added.
// Clipboard magnets only with TVCAST_CLIPBOARD=1 (macOS).
if (process.env.TVCAST_CLIPBOARD === '1' && process.platform === 'darwin') setInterval(() => {
  execFile('pbpaste', { timeout: 2000 }, (err, out) => {
    if (err || out == null) return;
    const first = seenClip === null; if (out === seenClip) return; seenClip = out;
    const m = out.match(/magnet:\?xt=urn:btih:[^\s"'<>]+/i);
    if (!first && m && m[0] !== lastClip) { lastClip = m[0]; log('clipboard magnet'); addMagnet(m[0]); }
  });
}, 1000);

// ================= DLNA (UPnP AV) =================
let renderer = null; // {location, controlURL, serviceType, name}

function ssdpSearch() {
  const sock = dgram.createSocket({ type: 'udp4', reuseAddr: true });
  const msg = Buffer.from(
    'M-SEARCH * HTTP/1.1\r\nHOST:239.255.255.250:1900\r\n' +
    'MAN:"ssdp:discover"\r\nMX:2\r\n' +
    'ST:urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n');
  sock.on('message', (buf) => {
    const txt = buf.toString();
    const loc = /location:\s*(\S+)/i.exec(txt);
    if (loc && !renderer) fetchDeviceDesc(loc[1]);
  });
  sock.bind(() => { try { sock.setBroadcast(true); sock.send(msg, 1900, '239.255.255.250'); } catch {} });
  setTimeout(() => { try { sock.close(); } catch {} }, 3000);
}

function fetchDeviceDesc(location) {
  http.get(location, (res) => {
    let xml = ''; res.on('data', d => xml += d); res.on('end', () => {
      // find AVTransport service control URL
      const svc = /<service>[\s\S]*?AVTransport[\s\S]*?<\/service>/i.exec(xml);
      if (!svc) return;
      const ctrl = /<controlURL>([^<]+)<\/controlURL>/i.exec(svc[0]);
      const type = /<serviceType>([^<]+)<\/serviceType>/i.exec(svc[0]);
      const nm = /<friendlyName>([^<]+)<\/friendlyName>/i.exec(xml);
      if (!ctrl || !type) return;
      const base = new URL(location);
      const controlURL = new URL(ctrl[1], base).toString();
      renderer = { location, controlURL, serviceType: type[1], name: nm ? nm[1] : 'ТВ' };
      state.tv.found = true; state.tv.name = renderer.name;
      if (activeFile) castToTV();
    });
  }).on('error', () => {});
}

function soap(action, body, cb) {
  if (!renderer) return cb && cb(new Error('no renderer'));
  const payload = `<?xml version="1.0"?>` +
    `<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" ` +
    `s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>` +
    `<u:${action} xmlns:u="${renderer.serviceType}">${body}</u:${action}>` +
    `</s:Body></s:Envelope>`;
  const u = new URL(renderer.controlURL);
  const req = http.request({
    host: u.hostname, port: u.port || 80, path: u.pathname + u.search, method: 'POST',
    headers: {
      'Content-Type': 'text/xml; charset="utf-8"',
      'SOAPACTION': `"${renderer.serviceType}#${action}"`,
      'Content-Length': Buffer.byteLength(payload),
    },
  }, (res) => { let d = ''; res.on('data', c => d += c); res.on('end', () => cb && cb(null, d)); });
  req.on('error', e => cb && cb(e));
  req.write(payload); req.end();
}

function castToTV() {
  if (!renderer || !activeFile) return;
  const url = streamURL();
  const meta = '';
  soap('SetAVTransportURI',
    `<InstanceID>0</InstanceID><CurrentURI>${url}</CurrentURI><CurrentURIMetaData>${meta}</CurrentURIMetaData>`,
    (err) => {
      if (err) return;
      soap('Play', `<InstanceID>0</InstanceID><Speed>1</Speed>`, () => {
        state.tv.casting = true;
      });
    });
}

function hmsToSec(s) {
  const m = /(\d+):(\d+):(\d+)/.exec(s || '');
  return m ? (+m[1]) * 3600 + (+m[2]) * 60 + (+m[3]) : 0;
}

setInterval(() => {
  if (!renderer) { ssdpSearch(); return; }
  if (!state.tv.casting) return;
  soap('GetPositionInfo', `<InstanceID>0</InstanceID>`, (err, xml) => {
    if (err) return;
    const rel = /<RelTime>([^<]+)<\/RelTime>/i.exec(xml || '');
    if (rel) state.tv.posSec = hmsToSec(rel[1]);
  });
}, 4000);
ssdpSearch();

// ---- pointer relay: tinyTV POSTs trackpad deltas, /play pages get them over SSE ----
// POST /pointer body: lines "m dx dy" (move, Mac points) or "c" (click). GET /pointer -> {clients}.
const pointerClients = new Set();
state.pointerClients = 0;
function pointerBroadcast(line) {
  for (const r of pointerClients) r.write(`data: ${line}\n\n`);
}
setInterval(() => { for (const r of pointerClients) r.write(': ping\n\n'); }, 15000);

// ================= HTTP server =================
const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  if (url.pathname === '/pointer/events') {
    res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-store', Connection: 'keep-alive' });
    res.write('retry: 1000\n\n');
    pointerClients.add(res); state.pointerClients = pointerClients.size;
    req.on('close', () => { pointerClients.delete(res); state.pointerClients = pointerClients.size; });
    return;
  }
  if (url.pathname === '/pointer') {
    if (req.method !== 'POST') {
      res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
      res.end(JSON.stringify({ clients: pointerClients.size })); return;
    }
    let body = '';
    req.on('data', c => { body += c; if (body.length > 4000) req.destroy(); });
    req.on('end', () => {
      for (const l of body.split('\n')) if (/^(m -?\d+(\.\d+)? -?\d+(\.\d+)?|c)$/.test(l.trim())) pointerBroadcast(l.trim());
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ clients: pointerClients.size }));
    });
    return;
  }
  if (url.pathname === '/') {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(UI); return;
  }
  if (url.pathname === '/state') {
    res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
    res.end(JSON.stringify(state)); return;
  }
  // tinyTV asks every second with the TV's own second: ahead = contiguous seconds downloaded past it.
  if (url.pathname === '/ahead') {
    const bps = bytesPerSec(), sec = Math.max(0, Number(url.searchParams.get('sec')) || 0), byte = Math.floor(sec * bps);
    watched.sec = Math.max(sec, activeTorrent && watched.hash === activeTorrent.infoHash ? watched.sec : 0);
    watched.hash = activeTorrent ? activeTorrent.infoHash : null; watched.at = Date.now();
    if (bps) prioritize(byte);
    // Plenty ahead: slow the download (piece hashing runs on this one thread and starved the TV's reads -> jerks).
    const ahead = bps ? aheadFrom(byte) / bps : 0;
    // While the TV watches, never full speed: at 37 MB/s piece hashing took 80-130 % CPU on this one thread and the TV's
    // reads waited (playback at 1/3 speed with a growing buffer). 3x the film's rate while the buffer is short, 2x after.
    const cap = bps ? Math.max(bps * (ahead < 120 ? 3 : 2), 4e6) : -1;
    lastAhead = Date.now();
    if (cap !== throttled) { throttled = cap; try { client.throttleDownload(cap); } catch {} }
    res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
    res.end(JSON.stringify({ hash: activeTorrent ? activeTorrent.infoHash : null, name: state.fileName, aheadSec: bps ? aheadFrom(byte) / bps : 0, bps, down: activeTorrent ? activeTorrent.downloadSpeed : 0,
      peers: activeTorrent ? activeTorrent.numPeers : 0, progress: activeTorrent ? activeTorrent.progress : 0, fileBytes: state.fileBytes, durationSec: state.durationSec }));
    return;
  }
  // tinyTV: download in the background without touching what plays ("↓ Скачати"). It is kept like "На фоні".
  if (url.pathname === '/fetch' && req.method === 'POST') {
    let body = ''; req.on('data', c => { body += c; if (body.length > 5000) req.destroy(); });
    req.on('end', () => {
      const m = (body.match(/magnet:\?xt=urn:btih:[^\s"'<>]+/i) || [])[0];
      if (!m) { res.writeHead(400); res.end('no magnet'); return; }
      const ih = infoHashOf(m);
      if (!client.torrents.find(t => t.infoHash === ih)) {
        try { const t = client.add(m, { path: storeDir(), announce: TRACKERS });
          t.on('ready', () => { const v = t.files.filter(f => VIDEO_RE.test(f.name)); const big = (v.length ? v : t.files).sort((a, b) => b.length - a.length)[0];
            t.files.forEach(f => (f === big ? f.select() : f.deselect())); background.set(t.infoHash, { magnet: t.magnetURI, path: t.path }); saveBg(); });
          background.set(ih, { magnet: m, path: storeDir() }); saveBg();
        } catch (e) { res.writeHead(500); res.end(String(e)); return; }
      }
      res.writeHead(200); res.end('fetching');
    });
    return;
  }
  if (url.pathname === '/list') {
    const dir = storeDir(); let free = 0; try { const st = fs.statfsSync(dir); free = st.bavail * st.bsize; } catch {}
    res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
    res.end(JSON.stringify({ folder: dir, free, torrents: listTorrents() })); return;
  }
  if (url.pathname === '/background' && req.method === 'POST') {
    const t = client.torrents.find(x => x.infoHash === url.searchParams.get('hash'));
    if (!t) { res.writeHead(404); res.end('no torrent'); return; }
    if (url.searchParams.get('on') === '0') background.delete(t.infoHash); else background.set(t.infoHash, { magnet: t.magnetURI, path: t.path });
    saveBg(); res.writeHead(200); res.end('ok'); return;
  }
  // Owner: pause / resume a download from the tinyTV list (not the one the TV plays). In memory until a restart.
  if (url.pathname === '/pause' && req.method === 'POST') {
    const t = client.torrents.find(x => x.infoHash === url.searchParams.get('hash'));
    if (!t) { res.writeHead(404); res.end('no torrent'); return; }
    if (url.searchParams.get('on') === '0') {
      paused.delete(t.infoHash); t.resume();
      const v = (t.files || []).filter(f => VIDEO_RE.test(f.name)); const big = (v.length ? v : (t.files || [])).sort((x, y) => y.length - x.length)[0];
      if (big) big.select();
    } else {
      if (t === activeTorrent) { res.writeHead(409); res.end('playing'); return; }
      paused.add(t.infoHash); t.pause(); (t.files || []).forEach(f => f.deselect()); (t.wires || []).slice().forEach(w => { try { w.destroy(); } catch {} });
    }
    res.writeHead(200); res.end('ok'); return;
  }
  if (url.pathname === '/remove' && req.method === 'POST') {
    const t = client.torrents.find(x => x.infoHash === url.searchParams.get('hash'));
    if (!t) { res.writeHead(404); res.end('no torrent'); return; }
    background.delete(t.infoHash); saveBg(); log('remove by request', t.infoHash);
    if (t === activeTorrent) { activeTorrent = null; activeFile = null; state.name = ''; state.fileName = null; state.fileBytes = 0; }
    try { const r = client.remove(t, { destroyStore: url.searchParams.get('files') !== '0' }); if (r && r.catch) r.catch(() => {}); } catch {}
    res.writeHead(200); res.end('removed'); return;
  }
  if (url.pathname === '/add') {
    let body = '';
    req.on('data', c => { body += c; if (body.length > 5000) req.destroy(); });
    req.on('end', () => {
      const file = url.searchParams.get('file');
      if (file && /\.torrent$/i.test(file) && fs.existsSync(file)) {
        lastClip = file; addMagnet(file); res.writeHead(200); res.end('added-file'); return;
      }
      wantEp = url.searchParams.get('ep');
      const raw = url.searchParams.get('magnet') || body || '';
      const m = raw.match(/magnet:\?xt=urn:btih:[^\s"'<>]+/i);
      if (m) { lastClip = m[0]; addMagnet(m[0]); res.writeHead(200); res.end('added'); }
      else { res.writeHead(400); res.end('no magnet'); }
    });
    return;
  }
  if (url.pathname === '/cast') { castToTV(); res.writeHead(200); res.end('ok'); return; }
  if (url.pathname === '/stream') { serveStream(req, res, true); return; }
  if (url.pathname === '/probe') { serveStream(req, res, false); return; }
  if (url.pathname === '/mp4') { serveTranscode(req, res); return; }
  if (url.pathname === '/play') {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(PLAYER); return;
  }
  res.writeHead(404); res.end('not found');
});

// On-the-fly transcode to universal H.264/AAC fragmented MP4 so ANY browser
// (Xbox Edge, phone, laptop) can play the source, even MKV / HEVC.
function serveTranscode(req, res) {
  if (!activeFile) { res.writeHead(503); res.end('no file'); return; }
  const src = `http://127.0.0.1:${PORT}/probe`;
  const args = [
    '-hide_banner', '-loglevel', 'error',
    '-i', src,
    '-map', '0:v:0', '-map', '0:a:0?',
    '-c:v', 'h264_videotoolbox', '-b:v', '8M',
    '-c:a', 'aac', '-ac', '2', '-b:a', '192k',
    '-movflags', 'frag_keyframe+empty_moov+default_base_moof',
    '-f', 'mp4', 'pipe:1',
  ];
  const ff = spawn('ffmpeg', args, { stdio: ['ignore', 'pipe', 'pipe'] });
  res.writeHead(200, { 'Content-Type': 'video/mp4', 'Cache-Control': 'no-store' });
  ff.stdout.pipe(res);
  ff.stderr.on('data', d => { const s = String(d); if (/error|fail/i.test(s)) state.error = s.slice(0, 200); });
  const kill = () => { try { ff.kill('SIGKILL'); } catch {} };
  req.on('close', kill); res.on('close', kill); ff.on('error', kill);
}

function serveStream(req, res, trackPlayhead) {
  if (!activeFile) { res.writeHead(503); res.end('no file'); return; }
  const total = activeFile.length;
  const range = req.headers.range;
  let start = 0, end = total - 1;
  if (range) {
    const m = /bytes=(\d+)-(\d*)/.exec(range);
    if (m) { start = parseInt(m[1], 10); if (m[2]) end = parseInt(m[2], 10); }
  }
  if (trackPlayhead) { state.playheadByte = start; prioritize(start); } // track where the real player reads
  const headers = {
    'Content-Type': mime(activeFile.name),
    'Accept-Ranges': 'bytes',
    'Content-Length': end - start + 1,
    'transferMode.dlna.org': 'Streaming',
    'contentFeatures.dlna.org': 'DLNA.ORG_OP=01;DLNA.ORG_FLAGS=01700000000000000000000000000000',
  };
  if (range) { headers['Content-Range'] = `bytes ${start}-${end}/${total}`; res.writeHead(206, headers); }
  else res.writeHead(200, headers);
  const stream = activeFile.createReadStream({ start, end });
  stream.on('error', () => { try { res.destroy(); } catch {} });
  stream.pipe(res);
  req.on('close', () => { try { stream.destroy(); } catch {} });
}

function mime(name) {
  if (/\.mkv$/i.test(name)) return 'video/x-matroska';
  if (/\.webm$/i.test(name)) return 'video/webm';
  if (/\.avi$/i.test(name)) return 'video/x-msvideo';
  if (/\.(ts|m2ts)$/i.test(name)) return 'video/mp2t';
  return 'video/mp4';
}

server.listen(PORT, '0.0.0.0', () => {
  console.log(`\n  TV Cast працює:  http://${state.lanIP}:${PORT}`);
  console.log(`  Потік для ТВ:    ${streamURL()}`);
  console.log(`  Скопіюй магніт у буфер — епка підхопить сама.\n`);
  // Only auto-open the browser when run standalone; the native app embeds us.
  if (!process.env.TVCAST_EMBED) execFile('open', [`http://127.0.0.1:${PORT}`]);
});

// ---- UI (single page, no external assets) ----
const UI = /* html */ `<!doctype html><html lang="uk"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>TV Cast</title>
<style>
:root{--bg:#0f1115;--card:#171a21;--line:#252a34;--txt:#e7ebf0;--dim:#8b93a1;
--green:#31c46b;--yellow:#e8b73a;--red:#e5484d;--accent:#6ea8ff}
*{box-sizing:border-box}body{margin:0;font:14px/1.5 -apple-system,system-ui,sans-serif;
background:var(--bg);color:var(--txt);-webkit-font-smoothing:antialiased}
.wrap{max-width:560px;margin:0 auto;padding:22px 18px 40px}
h1{font-size:16px;font-weight:600;margin:0 0 2px;letter-spacing:.2px}
.sub{color:var(--dim);font-size:12px;margin-bottom:18px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px;margin-bottom:12px}
.name{font-weight:600;font-size:14px;word-break:break-word}
.meta{color:var(--dim);font-size:12px;margin-top:2px}
.row{display:flex;justify-content:space-between;align-items:baseline;margin:14px 0 6px}
.row .lab{font-size:12px;color:var(--dim);text-transform:uppercase;letter-spacing:.5px}
.row .val{font-variant-numeric:tabular-nums;font-weight:600}
.bar{height:12px;border-radius:6px;background:#0b0d11;overflow:hidden;border:1px solid var(--line)}
.fill{height:100%;width:0;transition:width .5s ease,background .3s}
.dual{position:relative}
.fill2{position:absolute;top:0;left:0;height:100%;opacity:.35}
.pill{display:inline-block;font-size:11px;padding:2px 8px;border-radius:20px;margin-left:8px}
.on{background:rgba(49,196,107,.15);color:var(--green)}
.off{background:rgba(139,147,161,.15);color:var(--dim)}
.warn{background:rgba(232,183,58,.15);color:var(--yellow)}
.empty{color:var(--dim);text-align:center;padding:26px 10px}
.url{font-size:12px;color:var(--accent);word-break:break-all;margin-top:8px}
kbd{background:#0b0d11;border:1px solid var(--line);border-radius:4px;padding:1px 5px;font-size:11px}
</style></head><body><div class="wrap">
<h1>TV Cast</h1>
<div class="sub" id="sub">чекаю магніт у буфері обміну…</div>
<div id="content"></div>
</div>
<script>
const $=s=>document.querySelector(s);
function fmtB(b){if(!b)return'0';const u=['Б','КБ','МБ','ГБ','ТБ'];let i=0;while(b>=1024&&i<4){b/=1024;i++}return b.toFixed(b<10&&i>0?1:0)+' '+u[i]}
function fmtT(s){s=Math.max(0,Math.round(s));const m=Math.floor(s/60),ss=s%60;return m?m+'хв '+ss+'с':ss+'с'}
function color(sec){return sec>=30?'var(--green)':sec>=8?'var(--yellow)':'var(--red)'}
function bar(pct,col,pct2){return '<div class="bar dual">'+(pct2!=null?'<div class="fill2" style="width:'+Math.min(100,pct2)+'%;background:'+col+'"></div>':'')+'<div class="fill" style="width:'+Math.min(100,pct)+'%;background:'+col+'"></div></div>'}
async function tick(){
 let s;try{s=await (await fetch('/state',{cache:'no-store'})).json()}catch(e){return}
 if(!s.magnet){$('#sub').textContent='чекаю магніт у буфері обміну…';
   $('#content').innerHTML='<div class="card empty">Скопіюй <kbd>magnet:?…</kbd> будь-де на цьому Маку.<br>Епка підхопить його автоматично.</div>';return}
 $('#sub').innerHTML='потік: <span class="url">'+('http://'+s.lanIP+':'+s.port+'/stream')+'</span>';
 const macPct=(s.progress*100);
 const aheadPctOfFile = s.fileBytes? (s.macAheadBytes/s.fileBytes*100):0;
 const macCol=color(s.macAheadSec);
 // TV panel
 const tv=s.tv;let tvBlock;
 if(tv.found){
   const tvCol=color(tv.aheadSec);
   tvBlock='<div class="card"><div class="name">📺 '+(tv.name||'ТВ')+
     '<span class="pill '+(tv.casting?'on':'warn')+'">'+(tv.casting?'стрімить':'знайдено')+'</span></div>'+
     '<div class="row"><span class="lab">Запас на ТВ (оцінка)</span><span class="val" style="color:'+tvCol+'">'+fmtT(tv.aheadSec)+'</span></div>'+
     bar(Math.min(100,tv.aheadSec/60*100),tvCol)+
     '<div class="meta" style="margin-top:8px">позиція відтворення: '+fmtT(tv.posSec)+'</div></div>';
 }else{
   tvBlock='<div class="card"><div class="name">📺 ТВ<span class="pill off">не знайдено</span></div>'+
     '<div class="meta" style="margin-top:8px">Увімкни ТВ і DLNA (Content Sharing / Play To) у налаштуваннях VIDAA, або відкрий потік вручну:</div>'+
     '<div class="url">'+('http://'+s.lanIP+':'+s.port+'/stream')+'</div></div>';
 }
 $('#content').innerHTML=
  '<div class="card"><div class="name">'+(s.fileName||s.name||'…')+'</div>'+
   '<div class="meta">'+fmtB(s.fileBytes)+(s.durationSec?' · '+fmtT(s.durationSec):'')+' · '+s.peers+' пірів · '+fmtB(s.downSpeed)+'/с</div>'+
   '<div class="row"><span class="lab">Завантажено на Mac</span><span class="val">'+macPct.toFixed(0)+'%</span></div>'+
   bar(macPct, macPct>=100?'var(--green)':'var(--accent)')+
   '<div class="row"><span class="lab">Буфер попереду (Mac)</span><span class="val" style="color:'+macCol+'">'+fmtT(s.macAheadSec)+'</span></div>'+
   bar(Math.min(100,s.macAheadSec/60*100),macCol,aheadPctOfFile)+
   '<div class="meta" style="margin-top:8px">'+fmtB(s.downloadedBytes)+' завантажено · буфер попереду '+fmtB(s.macAheadBytes)+'</div>'+
  '</div>'+ tvBlock;
}
setInterval(tick,1000);tick();
</script></body></html>`;

// Player page opened on Xbox / any browser. Plays the universal /mp4 transcode,
// so it works even when the source is MKV or HEVC.
const PLAYER = `<!doctype html><html lang="uk"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>TV Cast — плеєр</title>
<style>html,body{margin:0;height:100%;background:#000;overflow:hidden}
video{width:100vw;height:100vh;object-fit:contain;background:#000}
#msg{position:fixed;inset:0;display:flex;align-items:center;justify-content:center;
color:#888;font:16px -apple-system,system-ui,sans-serif;pointer-events:none}</style></head>
<body><div id="msg">чекаю потік — скопіюй магніт на Маку…</div>
<video id="v" controls autoplay playsinline></video>
<script>
var v=document.getElementById('v'),m=document.getElementById('msg'),started=false;
function show(t){m.style.display='flex';m.textContent=t}
v.addEventListener('playing',function(){m.style.display='none'});
v.addEventListener('waiting',function(){show('буферизація…')});
v.addEventListener('error',function(){started=false;show('чекаю потік — скопіюй магніт на Маку…')});
function check(){
  fetch('/state',{cache:'no-store'}).then(function(r){return r.json()}).then(function(s){
    if(s.fileName && !started){started=true;show('запускаю…');v.src='/mp4?t='+Date.now();v.load();v.play().catch(function(){});}
    else if(!s.fileName && !started){show('чекаю потік — скопіюй магніт на Маку…');}
  }).catch(function(){});
}
setInterval(check,3000);check();
// Real pointer driven from the Mac trackpad via tinyTV (SSE from /pointer/events).
(function(){
  if(!window.EventSource)return;
  var c=document.createElement('div'),x=innerWidth/2,y=innerHeight/2,dirty=false,hideT=0;
  c.style.cssText='position:fixed;left:0;top:0;width:28px;height:28px;margin:-14px 0 0 -14px;border-radius:50%;'+
    'background:rgba(255,255,255,.9);box-shadow:0 0 0 3px rgba(0,0,0,.45),0 2px 10px rgba(0,0,0,.6);'+
    'pointer-events:none;z-index:2147483647;opacity:0;transition:opacity .3s,transform .12s;will-change:transform';
  document.body.appendChild(c);
  function paint(){dirty=false;c.style.transform='translate3d('+x+'px,'+y+'px,0)';}
  function wake(){c.style.opacity='1';clearTimeout(hideT);hideT=setTimeout(function(){c.style.opacity='0'},3000);}
  function click(){
    var el=document.elementFromPoint(x,y);
    c.style.transform+=' scale(.7)';setTimeout(paint,120);
    if(!el)return;
    if(el.tagName==='VIDEO'){if(el.paused){el.play().catch(function(){})}else{el.pause()}return;}
    el.click();
  }
  var es=new EventSource('/pointer/events');
  es.onmessage=function(e){
    var p=e.data.split(' ');wake();
    if(p[0]==='m'){var g=innerWidth/1280*1.6;
      x=Math.max(0,Math.min(innerWidth-1,x+parseFloat(p[1])*g));
      y=Math.max(0,Math.min(innerHeight-1,y+parseFloat(p[2])*g));
      if(!dirty){dirty=true;(window.requestAnimationFrame||setTimeout)(paint,16);}}
    else if(p[0]==='c')click();
  };
  paint();
})();
</script></body></html>`;
