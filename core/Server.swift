// Phone remote: a tiny HTTP server on 127.0.0.1:8891 (published over Tailscale HTTPS).
// GET / -> phone.html, GET /api/state -> JSON, POST /api/<command> with a JSON body.
// It shares the app's single MQTT client: a second client with the same id would kick it off the TV.
import Foundation
import Network

final class PhoneServer {
    static let port: NWEndpoint.Port = 8891
    private var listener: NWListener?
    private let q = DispatchQueue(label: "tinytv.http")

    func start() {
        let p = NWParameters.tcp
        p.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: PhoneServer.port)
        p.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: p) else { NSLog("tinyTV http: cannot listen on 8891"); return }
        l.newConnectionHandler = { [weak self] c in self?.serve(c) }
        l.start(queue: q)
        listener = l
        if TV.config["core"] == nil { TVPage.shared.start() }   // the TV page lives where the streams are (the core host)
    }

    private func serve(_ c: NWConnection) {
        c.start(queue: q)
        var buf = Data()
        func read() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] d, _, done, err in
                guard let self else { return }
                if let d { buf.append(d) }
                if let up = Upload(buf) { self.upload(up, c); return }
                if let req = Request(buf) { self.handle(req, c); return }
                if done || err != nil || buf.count > 1_000_000 { c.cancel(); return }
                read()
            }
        }
        read()
    }

    private func handle(_ r: Request, _ c: NWConnection) {
        // Shared Now Playing script for the phone pages (lock screen, Apple Watch).
        if r.method == "GET", r.path == "/np.js" {
            let js = Bundle.main.url(forResource: "np", withExtension: "js").flatMap { try? Data(contentsOf: $0) }
            return reply(c, 200, "text/javascript; charset=utf-8", js ?? Data())
        }
        // Silent MP3 as long as what the TV plays: iOS shows Now Playing progress from the playing audio element.
        if r.method == "GET", r.path.hasPrefix("/silence/"), let secs = Int(r.path.dropFirst(9).split(separator: ".").first ?? ""),
           (1...6 * 3600).contains(secs) {
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/tinyTV")
            let out = dir.appendingPathComponent("silence-\(secs).mp3")
            DispatchQueue.global().async {
                if !FileManager.default.fileExists(atPath: out.path), let ff = [NSHomeDirectory() + "/tinyTV/tools/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg"]
                    .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
                    let p = Process(); p.executableURL = URL(fileURLWithPath: ff)
                    p.arguments = ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "anullsrc=r=8000:cl=mono", "-t", String(secs),
                                   "-c:a", "libmp3lame", "-b:a", "8k", out.path]
                    try? p.run(); p.waitUntilExit()
                }
                let d = (try? Data(contentsOf: out)) ?? Data()
                self.reply(c, d.isEmpty ? 404 : 200, "audio/mpeg", d)
            }
            return
        }
        // HLS of what the core host buffers, for the phone's own player (and AirPlay from there): /watch/<id>/<file>.
        if r.method == "GET", r.path.hasPrefix("/watch/") {
            let parts = r.path.split(separator: "/").map(String.init)
            guard parts.count == 3, parts[1].allSatisfy({ $0.isLetter || $0.isNumber }), !parts[2].contains(".."),
                  let d = try? Data(contentsOf: PhoneWatch.dir.appendingPathComponent(parts[1]).appendingPathComponent(parts[2])) else {
                return reply(c, 404, "text/plain", Data("not found".utf8)) }
            let type = parts[2].hasSuffix(".m3u8") ? "application/vnd.apple.mpegurl" : parts[2].hasSuffix(".m4s") ? "video/iso.segment" : "video/mp4"
            return reply(c, 200, type, d)
        }
        if r.method == "GET", r.path == "/kino" || r.path == "/kino/" {
            let html = Bundle.main.url(forResource: "kino", withExtension: "html").flatMap { try? Data(contentsOf: $0) }
            return reply(c, 200, "text/html; charset=utf-8", html ?? Data("missing kino.html".utf8))
        }
        if r.method == "GET", r.path == "/" || r.path == "/index.html" {
            let html = Bundle.main.url(forResource: "phone", withExtension: "html").flatMap { try? Data(contentsOf: $0) }
            return reply(c, 200, "text/html; charset=utf-8", html ?? Data("missing phone.html".utf8))
        }
        if r.method == "GET", r.path == "/manifest.json" {
            let m = ##"{"name":"tinyTV","short_name":"tinyTV","display":"standalone","background_color":"#0e0f13","theme_color":"#0e0f13","start_url":"/"}"##
            return reply(c, 200, "application/manifest+json", Data(m.utf8))
        }
        guard r.path.hasPrefix("/api/") else { return reply(c, 404, "text/plain", Data("not found".utf8)) }
        let cmd = String(r.path.dropFirst(5))
        // Off the main thread: a folder scan can block (see files(_:)), and commands must never wait behind it.
        // Page version = phone.html modification time: an open page (home-screen app) reloads itself when it changes.
        // Kino talks to HDRezka through WebKit: async, never on a blocked main thread.
        if cmd.hasPrefix("kino/") {
            let body = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:]
            Task { @MainActor in
                let res = await Kino.shared.handle(cmd, body)
                let d = (try? JSONSerialization.data(withJSONObject: res)) ?? Data("{}".utf8)
                self.reply(c, 200, "application/json", d)
            }
            return
        }
        if r.method == "GET", cmd == "version" {
            // Any of the served pages: the remote, Kino (also inside the Mac panel) and np.js reload on a new build.
            let t = [("phone", "html"), ("kino", "html"), ("np", "js")].compactMap { n, e -> Double? in
                guard let u = Bundle.main.url(forResource: n, withExtension: e),
                      let a = try? FileManager.default.attributesOfItem(atPath: u.path), let d = a[.modificationDate] as? Date else { return nil }
                return d.timeIntervalSince1970
            }.max() ?? 0
            return reply(c, 200, "application/json", Data("{\"v\":\(Int(t))}".utf8))
        }
        if r.method == "GET", cmd == "files" { return PhoneServer.files { self.reply(c, 200, "application/json", $0) } }
        let body = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:]
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let tv = TV.shared
                var ok = true
                switch (r.method, cmd) {
                case ("GET", "state"): break
                case ("POST", "key"): if let k = body["key"] as? String, k.hasPrefix("KEY_") { tv.key(k) } else { ok = false }
                case ("POST", "power"): tv.power()
                case ("POST", "volume"): if let v = body["v"] as? Double { tv.volume = max(0, min(100, v)) } else { ok = false }
                case ("POST", "open"):
                    // With the TV page open, an HDRezka page plays there full screen (LowLatency.swift).
                    if let u = body["url"] as? String { if !TVPage.shared.take(u) { tv.open(u) } } else { ok = false }
                case ("POST", "page/open"): if let u = body["url"] as? String, u.hasPrefix("http") { TVPage.shared.go(u) } else { ok = false }
                case ("POST", "page/screen"): TVPage.shared.screen()
                case ("POST", "page/idle"): TVPage.shared.idle()
                case ("GET", "page"):
                    let o: [String: Any] = ["open": TVPage.shared.open, "report": TVPage.shared.report]
                    return self.reply(c, 200, "application/json", (try? JSONSerialization.data(withJSONObject: o)) ?? Data("{}".utf8))
                case ("POST", "type"): if let t = body["text"] as? String { tv.type(t) } else { ok = false }
                case ("POST", "picture"):
                    if let id = body["id"] as? Int, let v = body["v"] as? Double { tv.setPicture(id, v) } else { ok = false }
                case ("POST", "launch"):
                    if let id = body["id"] as? String, let a = tv.apps.first(where: { $0.id == id }) { tv.launch(a) } else { ok = false }
                case ("POST", "source"):
                    if let id = body["id"] as? String, let s = tv.sources.first(where: { $0.id == id }) { tv.source(s) } else { ok = false }
                case ("POST", "shortcut"):
                    if let n = body["name"] as? String, let u = body["url"] as? String, !n.isEmpty, !u.isEmpty {
                        tv.shortcuts.append(Shortcut(name: n, url: u))
                    } else { ok = false }
                case ("POST", "shortcut/delete"):
                    if let id = body["id"] as? String { tv.shortcuts.removeAll { $0.id.uuidString == id } } else { ok = false }
                case ("POST", "refresh"): tv.refresh()
                case ("POST", "cast/pause"):
                    // {"play": true|false} sets the state (Apple Watch, lock screen); no body toggles (panel button).
                    if let p = body["play"] as? Bool { Caster.shared.setPlaying(p) } else { Caster.shared.togglePause() }
                case ("POST", "cast/stop"): Caster.shared.stop()
                case ("POST", "airplay"): if let on = body["on"] as? Bool { Caster.shared.airplay(on) } else { ok = false }
                case ("POST", "sound"):
                    var s2 = Caster.shared.sound
                    if let p = body["preset"] as? String, p == "custom" || SoundSettings.presets[p] != nil { s2.preset = p }
                    if let c = body["custom"] as? [Double], c.count == 5 { s2.custom = c.map { max(-12, min(8, $0)) } }
                    Caster.shared.sound = s2
                case ("POST", "settings"):
                    var v = Caster.shared.video
                    if let m = body["mode"] as? String, ["auto", "original", "encode"].contains(m) { v.mode = m }
                    if let h = body["height"] as? Int, [2160, 1440, 1080, 720].contains(h) { v.height = h }
                    if let hdr = body["hdr"] as? Bool { v.hdr = hdr }
                    if let b = body["mbps"] as? Double { v.mbps = max(4, min(40, b)) }
                    Caster.shared.video = v
                case ("POST", "screen"):
                    if let f = body["from"] as? String, ["mac", "mac-extend", "mac-audio", "core", "core-audio"].contains(f) {
                        Caster.shared.tv = tv; Caster.shared.startScreen(f, window: (body["window"] as? Int).map { UInt32($0) })
                    } else { ok = false }
                case ("POST", "screen/preset"):
                    if let id = body["id"] as? String, ScreenPreset.all.contains(where: { $0.id == id }) { Caster.shared.screenPreset = id } else { ok = false }
                case ("POST", "screen/latency"):
                    if let l = body["s"] as? Double, (0...30).contains(l) { Caster.shared.screenLatency = l } else { ok = false }
                case ("POST", "movie"): if let on = body["on"] as? Bool { Caster.shared.movieLight = on } else { ok = false }
                case ("POST", "cast/audio"): if let i = body["i"] as? Int { Caster.shared.setTrack(i) } else { ok = false }
                case ("POST", "cast/seek"): if let t = body["t"] as? Double { Caster.shared.seek(t) } else { ok = false }
                case ("POST", "cast/file"):
                    // Only files inside the movie folders, never an arbitrary path from the network.
                    if let path = body["path"] as? String, PhoneServer.movieRoots.contains(where: { path.hasPrefix($0.path + "/") }),
                       !path.contains("/../") {
                        Caster.shared.tv = tv; Caster.shared.file(path)
                    } else { ok = false }
                default: return self.reply(c, 404, "text/plain", Data("unknown command".utf8))
                }
                guard ok else { return self.reply(c, 400, "text/plain", Data("bad request".utf8)) }
                self.reply(c, 200, "application/json", tv.stateJSON())
            }
        }
    }

    /// POST /api/upload (X-Name header): a file dropped on the Mac remote streams to ~/Movies/tinyTV, then casts.
    private func upload(_ up: Upload, _ c: NWConnection) {
        let dir = PhoneServer.movieRoots[0].appendingPathComponent("tinyTV")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = (up.name.removingPercentEncoding ?? up.name).replacingOccurrences(of: "/", with: "_")
        let dst = dir.appendingPathComponent(name.hasPrefix(".") || name.isEmpty ? "upload.mkv" : name)
        FileManager.default.createFile(atPath: dst.path, contents: nil)
        guard let fh = try? FileHandle(forWritingTo: dst) else { return reply(c, 400, "text/plain", Data("can't write".utf8)) }
        var left = up.length - up.head.count
        fh.write(up.head)
        func done() {
            try? fh.close()
            guard left <= 0 else { try? FileManager.default.removeItem(at: dst); c.cancel(); return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Caster.shared.tv = TV.shared; Caster.shared.file(dst.path)
                    self.reply(c, 200, "application/json", TV.shared.stateJSON())
                }
            }
        }
        func read() {
            guard left > 0 else { return done() }
            c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { d, _, end, err in
                if let d { fh.write(d); left -= d.count }
                if left <= 0 { return done() }
                if end || err != nil { return done() }
                read()
            }
        }
        read()
    }

    static let movieRoots = ["Movies", "Downloads"].map { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent($0) }

    /// Measured 2026-10-20: on the core host (lid closed) open() inside ~/Movies blocked forever, likely a privacy prompt
    /// nobody can answer, and the scan ran on the main thread, so every phone and Mac command hung behind it.
    /// Now one scan runs at a time on its own queue; a caller gets the last list after 3 s at most.
    private static let scanQ = DispatchQueue(label: "tinytv.files")
    private static let scanLock = NSLock()
    private static var scanning = false
    private static var lastList = Data("[]".utf8)

    static func files(_ done: @escaping @Sendable (Data) -> Void) {
        scanLock.lock()
        if scanning { let l = lastList; scanLock.unlock(); return done(l) }
        scanning = true; scanLock.unlock()
        let once = Once()
        let finish: @Sendable (Data) -> Void = { d in if once.first() { done(d) } }
        scanQ.async {
            let d = movies()
            scanLock.lock(); lastList = d; scanning = false; scanLock.unlock()
            finish(d)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { scanLock.lock(); let l = lastList; scanLock.unlock(); finish(l) }
    }

    /// Newest 80 videos under the movie folders (3 levels deep).
    static func movies() -> Data {
        let exts: Set<String> = ["mp4", "m4v", "mkv", "webm", "mov", "avi", "ts", "m2ts", "mpg", "wmv"]
        var found: [(URL, Date, Int)] = []
        for root in movieRoots {
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let u as URL in e {
                if e.level > 3 { e.skipDescendants(); continue }
                // Media libraries (Apple TV, Music, Photos) are privacy-protected: opening them can wait for a prompt.
                if e.level == 1, ["TV", "Music", "Photos Library.photoslibrary"].contains(u.lastPathComponent) { e.skipDescendants(); continue }
                guard exts.contains(u.pathExtension.lowercased()),
                      let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
                found.append((u, v.contentModificationDate ?? .distantPast, v.fileSize ?? 0))
            }
        }
        let list = found.sorted { $0.1 > $1.1 }.prefix(80).map {
            ["path": $0.0.path, "name": $0.0.deletingPathExtension().lastPathComponent, "mb": $0.2 / 1_000_000,
             "folder": $0.0.deletingLastPathComponent().lastPathComponent] as [String: Any]
        }
        return (try? JSONSerialization.data(withJSONObject: list)) ?? Data("[]".utf8)
    }

    private func reply(_ c: NWConnection, _ code: Int, _ type: String, _ body: Data) {
        let status = [200: "OK", 400: "Bad Request", 404: "Not Found"][code] ?? "OK"
        var h = "HTTP/1.1 \(code) \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
        h += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        c.send(content: Data(h.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }
}

/// One HTTP/1.1 request, parsed once headers and the full Content-Length body have arrived.
private struct Request {
    let method: String, path: String, body: Data
    init?(_ d: Data) {
        guard let end = d.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: d[d.startIndex..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let line = head.first?.split(separator: " ") ?? []
        guard line.count >= 2 else { return nil }
        let len = head.dropFirst().compactMap { h -> Int? in
            let p = h.split(separator: ":", maxSplits: 1)
            return p.count == 2 && p[0].lowercased() == "content-length" ? Int(p[1].trimmingCharacters(in: .whitespaces)) : nil
        }.first ?? 0
        guard d.count - end.upperBound >= len else { return nil }
        method = String(line[0]); path = String(line[1].split(separator: "?").first ?? "/")
        body = d.subdata(in: end.upperBound..<end.upperBound + len)
    }
}

/// Headers of an upload; the body streams to disk instead of memory.
private struct Upload {
    let name: String, length: Int, head: Data
    init?(_ d: Data) {
        guard let end = d.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: d[d.startIndex..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        guard lines.first?.hasPrefix("POST /api/upload ") == true else { return nil }
        var h: [String: String] = [:]
        for l in lines.dropFirst() {
            let p = l.split(separator: ":", maxSplits: 1)
            if p.count == 2 { h[p[0].lowercased()] = p[1].trimmingCharacters(in: .whitespaces) }
        }
        guard let n = Int(h["content-length"] ?? "") else { return nil }
        name = h["x-name"] ?? "upload"; length = n; head = d.subdata(in: end.upperBound..<d.endIndex)
    }
}

/// True for the first caller only.
private final class Once: @unchecked Sendable {
    private let lock = NSLock(); private var used = false
    func first() -> Bool { lock.lock(); defer { lock.unlock() }; let f = !used; used = true; return f }
}
