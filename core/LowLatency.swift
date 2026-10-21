// TV page: one bookmark in the TV Browser, http://<the core host LAN IP>:8895/ (core only).
// Why: DLNA buffers ~8 s and the TV ignores URLs sent over MQTT (both measured 2026-10-20). The page:
//   - plays the screen with low delay: the relay's MPEG-TS is remuxed (copy, no re-encode) by ffmpeg into
//     fragmented MP4, sent over a WebSocket on the same port (/ws) and fed to Media Source Extensions at the live edge;
//   - opens any link: it asks /cmd every second and goes where the core tells it;
//   - plays a direct video (an HDRezka page resolved by Rezka.swift) full screen in its own <video>.
import Foundation
import Network
import CryptoKit

final class TVPage: @unchecked Sendable {
    static let shared = TVPage()
    static let httpPort: NWEndpoint.Port = 8895
    private let q = DispatchQueue(label: "tinytv.tvpage")
    private var http: NWListener?
    private var pending: [String: Any] = [:]       // the next command for the page
    private var lastPoll = Date.distantPast
    private var lastReport = ""
    private var players: [ObjectIdentifier: Player] = [:]
    private var ff: Process?, ffIn: FileHandle?, tapID: Int?
    private let feedQ = DispatchQueue(label: "tinytv.tvpage.feed")
    private var out = Data(), moof: Data?
    private var initSeg = Data(), codecs = "", hevc = false
    private var ffmpeg: String?

    private final class Player { let c: NWConnection; var inFlight = 0; var needKey = true; init(_ c: NWConnection) { self.c = c } }

    /// The page is on the TV right now (it polls every second).
    var open: Bool { q.sync { Date().timeIntervalSince(lastPoll) < 3 } }
    var report: String { q.sync { lastReport } }

    /// Called on the main thread when the core starts (PhoneServer.start).
    func start() {
        ffmpeg = Thread.isMainThread ? MainActor.assumeIsolated { Caster.tool("ffmpeg") } : nil
        listenHTTP()
    }

    /// A busy port fails the listener after start (once: a test server held 8895): try again every 5 s.
    private func listenHTTP() {
        let p = NWParameters.tcp; p.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: p, on: TVPage.httpPort) else { NSLog("tinyTV page: cannot listen on 8895"); return }
        l.newConnectionHandler = { [weak self] c in self?.serveHTTP(c) }
        l.stateUpdateHandler = { [weak self] st in
            if case .failed(let e) = st {
                NSLog("tinyTV page: 8895 %@, retry in 5 s", "\(e)"); l.cancel()
                self?.q.asyncAfter(deadline: .now() + 5) { self?.listenHTTP() }
            }
        }
        l.start(queue: q); http = l
    }

    // MARK: commands (any thread)

    func go(_ url: String) { set(["url": url]) }
    func play(_ url: String, title: String) { set(["play": url, "title": title]) }
    func screen() { set(["screen": true]) }
    func idle() { set(["idle": true]) }
    private func set(_ c: [String: Any]) { q.async { self.pending = c; self.pending["id"] = UUID().uuidString } }

    /// A link from the phone or the Mac while the page is on the TV. HDRezka: resolve here and play full screen;
    /// if that fails, at least open the page itself in the TV Browser. Returns false for links the page doesn't take.
    @MainActor func take(_ link: String) -> Bool {
#if PROVIDER_HDREZKA
        guard open, Rezka.handles(link) else { return false }
        set(["status": "HDRezka…"])
        Rezka.shared.resolve(link) { [weak self] r in
            switch r {
            case .success(let v): self?.play(v.url, title: v.title)
            case .failure(let e): NSLog("tinyTV page: rezka failed (%@), opening the page", e.localizedDescription); self?.go(link)
            }
        }
        return true
#else
        return false
#endif
    }

    // MARK: HTTP :8895

    private static func allowed(_ e: NWEndpoint) -> Bool {
        guard case .hostPort(let h, _) = e else { return false }
        let s = "\(h)".split(separator: "%").first.map(String.init) ?? ""
        if s == "127.0.0.1" || s == "::1" || s.hasPrefix("192.168.") || s.hasPrefix("10.") { return true }
        let o = s.split(separator: ".").compactMap { Int($0) }
        return o.count == 4 && o[0] == 100 && (64...127).contains(o[1])
    }

    private func serveHTTP(_ c: NWConnection) {
        guard TVPage.allowed(c.endpoint) else { c.cancel(); return }
        c.start(queue: q)
        var buf = Data()
        func read() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] d, _, done, err in
                guard let self else { return }
                if let d { buf.append(d) }
                if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                    let head = String(decoding: buf[buf.startIndex..<end.lowerBound], as: UTF8.self)
                    let len = head.components(separatedBy: "\r\n").compactMap { l -> Int? in
                        let p = l.split(separator: ":", maxSplits: 1)
                        return p.count == 2 && p[0].lowercased() == "content-length" ? Int(p[1].trimmingCharacters(in: .whitespaces)) : nil
                    }.first ?? 0
                    if buf.count - end.upperBound >= len {
                        return self.route(head, buf.subdata(in: end.upperBound..<end.upperBound + len), c)
                    }
                }
                if done || err != nil || buf.count > 200_000 { c.cancel(); return }
                read()
            }
        }
        read()
    }

    private func route(_ head: String, _ body: Data, _ c: NWConnection) {
        let line = head.split(separator: "\r\n").first?.split(separator: " ") ?? []
        let method = line.first.map(String.init) ?? "", path = line.count > 1 ? String(line[1].split(separator: "?").first ?? "") : ""
        switch (method, path) {
        case ("GET", "/"), ("GET", "/index.html"):
            reply(c, "text/html; charset=utf-8", Data(TVPage.html.utf8))
        case ("GET", "/cmd"):
            lastPoll = Date()
            var cmd = pending; pending = [:]
            cmd["live"] = LiveRelay.shared.video
            reply(c, "application/json", (try? JSONSerialization.data(withJSONObject: cmd)) ?? Data("{}".utf8))
        case ("GET", "/ws"):
            upgrade(head, c)
        case ("POST", "/report"):
            lastReport = String(decoding: body.prefix(4000), as: UTF8.self)
            NSLog("tinyTV page report: %@", lastReport)
            reply(c, "application/json", Data("{}".utf8))
        default:
            c.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                   completion: .contentProcessed { _ in c.cancel() })
        }
    }

    private func reply(_ c: NWConnection, _ type: String, _ body: Data) {
        let h = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        c.send(content: Data(h.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }

    // MARK: WebSocket /ws -> MSE
    // On the page's own port: a browser (the app's browser pane, measured) may refuse WebSocket to another port.
    // Hand-made RFC 6455 server side: one handshake, then unmasked server frames; client frames are read and dropped.

    private func upgrade(_ head: String, _ c: NWConnection) {
        let key = head.components(separatedBy: "\r\n").compactMap { l -> String? in
            let p = l.split(separator: ":", maxSplits: 1)
            return p.count == 2 && p[0].lowercased() == "sec-websocket-key" ? p[1].trimmingCharacters(in: .whitespaces) : nil
        }.first ?? ""
        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        let h = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        c.send(content: Data(h.utf8), completion: .contentProcessed { _ in })
        let p = Player(c)
        players[ObjectIdentifier(c)] = p
        c.stateUpdateHandler = { [weak self] st in
            switch st { case .failed, .cancelled: self?.q.async { self?.drop(p) }; default: break }
        }
        func read() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] d, _, done, err in
                // A close frame (opcode 8) or a dead socket ends the player.
                if done || err != nil || (d?.first.map { $0 & 0x0f == 8 } ?? false) { c.cancel(); self?.q.async { self?.drop(p) }; return }
                read()
            }
        }
        read()
        ready(p)
    }

    private static func frame(_ op: UInt8, _ d: Data) -> Data {
        var f = Data([0x80 | op])
        if d.count < 126 { f.append(UInt8(d.count)) }
        else if d.count < 65536 { f.append(126); f.append(UInt8(d.count >> 8)); f.append(UInt8(d.count & 0xff)) }
        else { f.append(127); for i in (0..<8).reversed() { f.append(UInt8((d.count >> (8 * i)) & 0xff)) } }
        return f + d
    }

    private func ready(_ p: Player) {
        NSLog("tinyTV page: player connected (%d)", players.count)
        if !initSeg.isEmpty { sendInit(p) }
        if ff == nil { startRemux() }
    }

    private func drop(_ p: Player) {
        guard players.removeValue(forKey: ObjectIdentifier(p.c)) != nil else { return }
        NSLog("tinyTV page: player gone (%d left)", players.count)
        if players.isEmpty { stopRemux() }
    }

    private func sendInit(_ p: Player) {
        send(p, text: "{\"codecs\":\"\(codecs)\"}")
        send(p, initSeg)
    }

    private func send(_ p: Player, text: String) {
        p.c.send(content: TVPage.frame(1, Data(text.utf8)), completion: .contentProcessed { _ in })
    }

    private func send(_ p: Player, _ d: Data) {
        p.inFlight += d.count
        p.c.send(content: TVPage.frame(2, d), completion: .contentProcessed { [weak self] err in
                     self?.q.async { p.inFlight -= d.count; if err != nil { p.c.cancel() } }
                 })
    }

    /// ffmpeg copies the relay's H.264/HEVC + AAC into fragments of <= 100 ms (a new one at every keyframe).
    private func startRemux() {
        guard let tool = ffmpeg else { NSLog("tinyTV page: ffmpeg missing"); return }
        // No video in the relay (nothing sent yet, or audio-only mode): check again in 1 s, start nothing.
        guard LiveRelay.shared.video else {
            q.asyncAfter(deadline: .now() + 1) { [weak self] in if let self, self.ff == nil, !self.players.isEmpty { self.startRemux() } }
            return
        }
        let p = Process(); p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin",
                       "-fflags", "+nobuffer", "-flags", "low_delay", "-probesize", "500000", "-analyzeduration", "500000",
                       "-f", "mpegts", "-i", "pipe:0", "-map", "0:v:0", "-map", "0:a:0?", "-c:v", "copy",
                       // Audio is re-encoded: copied ADTS AAC has no config yet when empty_moov writes the header,
                       // and Chrome then fails the first append (measured: CHUNK_DEMUXER_ERROR_APPEND_FAILED).
                       "-c:a", "aac", "-b:a", "160k",
                       "-f", "mp4", "-movflags", "+frag_keyframe+empty_moov+default_base_moof", "-frag_duration", "100000",
                       "-flush_packets", "1", "pipe:1"]
        let i = Pipe(), o = Pipe(), e = Pipe()
        p.standardInput = i; p.standardOutput = o; p.standardError = e
        e.fileHandleForReading.readabilityHandler = { h in
            let s = String(decoding: h.availableData, as: UTF8.self); if !s.isEmpty { NSLog("tinyTV page ffmpeg: %@", s) }
        }
        o.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { h.readabilityHandler = nil; return }
            self?.q.async { self?.parse(d) }
        }
        p.terminationHandler = { [weak self] pr in
            NSLog("tinyTV page: remux ended %d", pr.terminationStatus)
            self?.q.async {
                guard let self, self.ff === pr else { return }
                self.ff = nil; self.ffIn = nil; if let t = self.tapID { LiveRelay.shared.untap(t) }; self.tapID = nil
                // The stream ended or restarted (another preset): start over while players are connected.
                if !self.players.isEmpty { self.q.asyncAfter(deadline: .now() + 1) { if self.ff == nil, !self.players.isEmpty { self.startRemux() } } }
            }
        }
        out = Data(); moof = nil; initSeg = Data(); codecs = ""
        players.values.forEach { $0.needKey = true }
        do { try p.run() } catch { NSLog("tinyTV page: ffmpeg failed %@", error.localizedDescription); return }
        ff = p; ffIn = i.fileHandleForWriting
        let fh = i.fileHandleForWriting, fq = feedQ
        // The relay calls the tap on its own queue: hand the bytes to a writer queue so the relay never blocks.
        tapID = LiveRelay.shared.tap { d in
            fq.async { if let d { try? fh.write(contentsOf: d) } else { try? fh.close() } }
        }
        if tapID == nil {
            NSLog("tinyTV page: no live stream yet, retry in 1 s")
            p.terminate()
        }
    }

    private func stopRemux() {
        if let t = tapID { LiveRelay.shared.untap(t) }; tapID = nil
        let p = ff; ff = nil
        if let p, p.isRunning { p.terminate() }
        let fh = ffIn; ffIn = nil
        feedQ.async { try? fh?.close() }
    }

    /// Splits ffmpeg's output into MP4 boxes: ftyp + moov = init, then moof + mdat = one fragment.
    private func parse(_ d: Data) {
        out.append(d)
        while out.count >= 8 {
            let b = out.startIndex
            let size = Int(out[b]) << 24 | Int(out[b + 1]) << 16 | Int(out[b + 2]) << 8 | Int(out[b + 3])
            guard size >= 8 else { out = Data(); return }   // largesize never comes from this muxer
            guard out.count >= size else { return }
            let box = out.subdata(in: b..<b + size)
            let type = String(decoding: box[box.startIndex + 4..<box.startIndex + 8], as: UTF8.self)
            out = out.subdata(in: b + size..<out.endIndex)
            switch type {
            case "ftyp": initSeg = box
            case "moov":
                initSeg.append(box); codecs = TVPage.codecs(box); hevc = codecs.hasPrefix("hvc1") || codecs.hasPrefix("hev1")
                NSLog("tinyTV page: init %d B, codecs %@", initSeg.count, codecs)
                players.values.forEach { sendInit($0) }
            case "moof": moof = box
            case "mdat":
                guard let m = moof else { continue }
                moof = nil
                let frag = m + box, key = TVPage.startsWithKey(box, hevc: hevc)
                for p in players.values {
                    if p.needKey { guard key else { continue }; p.needKey = false }
                    // A slow TV must not build a queue (that is delay): skip to the next keyframe instead.
                    if p.inFlight > 3_000_000 { p.needKey = true; continue }
                    send(p, frag)
                }
            default: break
            }
        }
    }

    /// MSE codec string from the init segment: avcC carries profile/compatibility/level, hvcC profile and level.
    static func codecs(_ moov: Data) -> String {
        var v = "avc1.640028"
        if let r = moov.range(of: Data("avcC".utf8)), r.upperBound + 4 <= moov.endIndex {
            let a = moov[r.upperBound + 1], b = moov[r.upperBound + 2], c = moov[r.upperBound + 3]
            v = String(format: "avc1.%02X%02X%02X", a, b, c)
        } else if let r = moov.range(of: Data("hvcC".utf8)), r.upperBound + 13 <= moov.endIndex {
            let profile = Int(moov[r.upperBound + 1] & 0x1f), level = Int(moov[r.upperBound + 12])
            let tag = moov.range(of: Data("hev1".utf8)) != nil ? "hev1" : "hvc1"
            v = "\(tag).\(profile).\(profile == 2 ? 4 : 6).L\(level).B0"
        }
        return moov.range(of: Data("mp4a".utf8)) != nil ? v + ", mp4a.40.2" : v
    }

    /// The first video NAL units of the fragment (video is track 1, so its data comes first in mdat).
    static func startsWithKey(_ mdat: Data, hevc: Bool) -> Bool {
        var i = mdat.startIndex + 8
        for _ in 0..<8 {
            guard i + 5 <= mdat.endIndex else { return false }
            let len = Int(mdat[i]) << 24 | Int(mdat[i + 1]) << 16 | Int(mdat[i + 2]) << 8 | Int(mdat[i + 3])
            let h = mdat[i + 4]
            if hevc {
                let t = Int(h >> 1) & 0x3f
                if (16...21).contains(t) { return true }
                if t < 16 { return false }
            } else {
                let t = Int(h) & 0x1f
                if t == 5 { return true }
                if t >= 1 && t <= 4 { return false }
            }
            guard len > 0 else { return false }
            i += 4 + len
        }
        return false
    }

    // MARK: the page (old browser engine: plain ES5)

    static let html = #"""
<!doctype html>
<html><head><meta charset="utf-8"><title>tinyTV</title>
<style>
html,body{margin:0;height:100%;background:#000;color:#e8e8ea;font-family:sans-serif;overflow:hidden}
video{position:fixed;left:0;top:0;width:100%;height:100%;background:#000;object-fit:contain;display:none}
#idle{position:fixed;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:18px}
#idle h1{font-size:64px;margin:0;font-weight:600;letter-spacing:.02em}
#idle p{font-size:28px;margin:0;color:#9a9ba3}
#st{position:fixed;right:24px;bottom:18px;font-size:22px;color:#9a9ba3;background:rgba(0,0,0,.55);padding:6px 12px;border-radius:10px;display:none}
</style></head><body>
<div id="idle"><h1>tinyTV</h1><p id="msg">Ready. Send a link or the screen from tinyTV.</p></div>
<video id="v" playsinline></video>
<div id="st"></div>
<script>
var v = document.getElementById('v'), st = document.getElementById('st'), msg = document.getElementById('msg');
var mode = 'idle', ws = null, ms = null, sb = null, queue = [], codecs = '', lastId = '', stTimer = 0;
function status(t, keep) { st.textContent = t; st.style.display = t ? 'block' : 'none'; clearTimeout(stTimer); if (!keep) stTimer = setTimeout(function () { st.style.display = 'none'; }, 4000); }
function report(o) { try { var x = new XMLHttpRequest(); x.open('POST', '/report', true); x.setRequestHeader('Content-Type', 'text/plain'); x.send(JSON.stringify(o)); } catch (e) {} }
function show(on) { v.style.display = on ? 'block' : 'none'; document.getElementById('idle').style.display = on ? 'none' : 'flex'; }
function stopAll() {
  if (ws) { ws.onclose = null; try { ws.close(); } catch (e) {} ws = null; }
  sb = null; queue = []; ms = null;
  try { v.pause(); v.removeAttribute('src'); v.load(); } catch (e) {}
  show(false); mode = 'idle';
}
function playNow() {
  var p = v.play();
  if (p && p['catch']) p['catch'](function () { v.muted = true; v.play(); status('Press OK for sound', true); });
}
document.addEventListener('keydown', function () { if (v.muted) { v.muted = false; status(''); } });

// Screen: fMP4 fragments over WebSocket into MSE, held at the live edge.
function screen() {
  stopAll(); mode = 'screen'; show(true); status('Connecting…', true);
  ws = new WebSocket('ws://' + location.host + '/ws'); ws.binaryType = 'arraybuffer';
  ws.onmessage = function (e) {
    if (typeof e.data === 'string') { var m = JSON.parse(e.data); if (m.codecs) { codecs = m.codecs; openMSE(); } return; }
    queue.push(e.data); pump();
  };
  ws.onclose = function () { if (mode === 'screen') setTimeout(screen, 1000); };
}
function openMSE() {
  var MS = window.MediaSource || window.WebKitMediaSource; queue = [];
  ms = new MS(); v.src = URL.createObjectURL(ms);
  ms.addEventListener('sourceopen', function () {
    var t = 'video/mp4; codecs="' + codecs + '"';
    try { sb = ms.addSourceBuffer(t); } catch (e) { report({error: 'addSourceBuffer ' + t + ' ' + e}); status('Not supported: ' + codecs, true); return; }
    sb.addEventListener('updateend', pump);
    pump(); playNow(); status('Live · ' + codecs);
  });
}
function pump() {
  if (!sb || sb.updating || !queue.length) return;
  try { sb.appendBuffer(queue.shift()); } catch (e) {
    // QuotaExceeded: drop what was played.
    try { if (v.buffered.length && v.currentTime - v.buffered.start(0) > 2) sb.remove(v.buffered.start(0), v.currentTime - 1); } catch (e2) {}
  }
}
var lastTrim = 0;
setInterval(function () {
  if (mode !== 'screen' || !v.buffered.length) return;
  var end = v.buffered.end(v.buffered.length - 1), lag = end - v.currentTime;
  if (lag > 0.5 || v.currentTime < v.buffered.start(0)) v.currentTime = Math.max(v.buffered.start(0), end - 0.12);
  if (v.paused) playNow();
  if (sb && !sb.updating && v.currentTime - v.buffered.start(0) > 20 && Date.now() - lastTrim > 5000) { lastTrim = Date.now(); try { sb.remove(0, v.currentTime - 10); } catch (e) {} }
  if (st.style.display === 'block' && st.textContent.indexOf('Live') === 0) st.textContent = 'Live · ' + codecs + ' · buffer ' + lag.toFixed(2) + ' s';
}, 250);

// A direct video (HDRezka stream) full screen.
function playURL(u, title) {
  stopAll(); mode = 'video'; show(true); v.muted = false; v.src = u; playNow(); status(title || '');
  v.onerror = function () { report({error: 'video ' + (v.error && v.error.code), url: u}); status('Cannot play this video', true); };
}

// Commands from the core.
function poll() {
  var x = new XMLHttpRequest(); x.open('GET', '/cmd?' + Date.now(), true); x.timeout = 4000;
  x.onload = function () {
    var c; try { c = JSON.parse(x.responseText); } catch (e) { return; }
    if (c.id && c.id !== lastId) {
      lastId = c.id;
      if (c.url) { location.href = c.url; return; }
      if (c.play) playURL(c.play, c.title);
      if (c.screen) screen();
      if (c.idle) stopAll();
      if (c.status) status(c.status);
    }
    if (mode === 'screen' && c.live === false) { msg.textContent = 'The screen stream stopped.'; stopAll(); }
  };
  x.send();
}
setInterval(poll, 1000); poll();
report({ua: navigator.userAgent, mse: !!(window.MediaSource || window.WebKitMediaSource), ws: !!window.WebSocket,
  avc: !!(window.MediaSource && MediaSource.isTypeSupported('video/mp4; codecs="avc1.640028, mp4a.40.2"')),
  hevc: !!(window.MediaSource && MediaSource.isTypeSupported('video/mp4; codecs="hvc1.1.6.L120.B0"')),
  size: innerWidth + 'x' + innerHeight, installApp: typeof window.Hisense_installApp});
</script></body></html>
"""#
}
