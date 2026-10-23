// "Кіно": HDRezka search, title pages, voiceovers / seasons / episodes / qualities, bookmarks, history and
// "continue where you stopped". Runs on the core (core host) so the phone and the Mac share one store.
// The site answers plain HTTP clients with a bot check, so every request runs as fetch() inside a WebKit page
// already open on rezka.ag (same origin, its cookies). Parsing happens in that page with DOMParser.
import AppKit
import WebKit

@MainActor
final class Kino: NSObject {
    static let shared = Kino()

    var web: WKWebView?

    var ready = false

    var waiters: [CheckedContinuation<Void, Never>] = []

    let store = KinoStore()

    // MARK: API (all JSON in, JSON out)
    static func releaseName(_ magnet: String) -> String {
        URLComponents(string: magnet)?.queryItems?.first { $0.name == "dn" }?.value ?? ""
    }

    /// A Discover film on HDRezka: same year (±1), Russian title first. Gives "where to watch" and a fallback poster.
    var found: [String: [String: Any]] = [:]

    /// The site's own visitor check expired: open the site again in this browser and let it finish its check
    /// (as Safari does). Once per 2 min at most, only on the owner's action.
    var lastRecheck = Date.distantPast

    // MARK: Playback and progress

    /// The planned switch (switchplan.py) and its status file for the dock. One plan at a time: a new one replaces it.
    var switchPlan: Process?

    var switchStatus: String?

    static let mixDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/tinyTV-mix")

    var keeper: Process?

    /// keeper.py: one per core, restarted if it ends.
    func ensureKeeper() {
        guard keeper?.isRunning != true, let py = Bundle.main.path(forResource: "keeper", ofType: "py") else { return }
        try? FileManager.default.createDirectory(at: Self.mixDir, withIntermediateDirectories: true)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); p.arguments = [py, Self.mixDir.path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = Caster.ffmpegLog()
        if (try? p.run()) != nil { keeper = p }
    }

    func startPlan(_ py: String, _ plan: [String: Any]) -> Any {
        if let s = switchStatus { FileManager.default.createFile(atPath: s + ".cancel", contents: nil) }
        switchPlan?.terminate()
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/tinyTV-mix")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let planURL = dir.appendingPathComponent("plan.json"), st = dir.appendingPathComponent("plan-status.json")
        [st, URL(fileURLWithPath: st.path + ".cancel")].forEach { try? FileManager.default.removeItem(at: $0) }
        var plan = plan; plan["mixdir"] = dir.path
        guard let data = try? JSONSerialization.data(withJSONObject: plan), (try? data.write(to: planURL)) != nil else { return ["error": "Не вдалося записати план"] }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); p.arguments = [py, planURL.path, st.path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = Caster.ffmpegLog()
        do { try p.run(); switchPlan = p; switchStatus = st.path } catch { return ["error": "Не вдалося запустити план"] }
        return ["ok": true]
    }

    /// What plays now from Kino, to save progress and to offer the next episode.
    var current: [String: Any]?

    var next: [String: Any]?

    var nextTimer: Task<Void, Never>?

    var watcher: Task<Void, Never>?

    func saveTorrent(_ h: String, position: Double, duration: Double, name: String) {
        store.saveTorrent(h, position: position, duration: duration, name: name)
        // The film's own position too: HDRezka's "Продовжити" and the next torrent start from here.
        if let f = film, let id = f["id"] as? String { store.saveProgress(id, position: position, duration: duration) }
    }

    /// The film a playing torrent belongs to (set when it was started from a film card).
    var film: [String: Any]?

    var filmSaved = Date.distantPast

    /// A torrent from the Downloads list for the phone, the Mac window or a paired screen, from where he stopped.
    /// Done: the file on the disk (no engine, no peers); otherwise the engine streams it.
    func torrentHere(_ m: String) async -> Any {
        guard let r = m.range(of: "btih:") else { return ["error": "Немає магнета"] }
        let hash = String(m[r.upperBound...].prefix(40)).lowercased()
        let from = store.torrentPos(hash) ?? 0
        // Done: the file on the disk (no engine, no peers needed); the folder's largest video for a multi-file torrent.
        if let l = await Downloads.list(), let folder = l["folder"] as? String,
           let t = (l["torrents"] as? [[String: Any]])?.first(where: { ($0["hash"] as? String)?.lowercased() == hash }),
           t["done"] as? Bool == true, let name = t["name"] as? String {
            let p = (folder as NSString).appendingPathComponent(name); var dir: ObjCBool = false
            let file = FileManager.default.fileExists(atPath: p, isDirectory: &dir) && !dir.boolValue ? p
                : FileManager.default.enumerator(atPath: p)?.compactMap { $0 as? String }
                    .filter { Library.exts.contains(($0 as NSString).pathExtension.lowercased()) }
                    .map { (p as NSString).appendingPathComponent($0) }
                    .max { ((try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? Int) ?? 0) ?? 0 < ((try? FileManager.default.attributesOfItem(atPath: $1)[.size] as? Int) ?? 0) ?? 0 }
            if let file {
                var r = await PhoneWatch.file(file, from: from)
                if var d = r as? [String: Any] { d["hash"] = hash; r = d }
                return r
            }
        }
        return await PhoneWatch.torrent(m, hash: hash, from: from)
    }

    func torrentResume(_ magnet: String) -> Double {
        guard let r = magnet.range(of: "btih:") else { return 0 }
        return store.torrentPos(String(magnet[r.upperBound...].prefix(40))) ?? 0
    }

    var torrentPositions: [String: [String: Any]] { store.torrentPositions }

    /// For /api/state: what Kino plays and the next-episode offer.
    /// The episode before / after the current one (dir -1 / +1), across seasons; nil at either end.
    func neighbour(_ dir: Int) -> (s: Int, e: Int)? {
        guard let cur = current, let s = cur["season"] as? Int, let e = cur["episode"] as? Int,
              let seasons = cur["seasons"] as? [[String: Any]] else { return nil }
        let all = seasons.compactMap { x -> [(Int, Int)]? in
            guard let n = x["n"] as? Int else { return nil }; return (x["episodes"] as? [Int] ?? []).sorted().map { (n, $0) } }
            .flatMap { $0 }.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        guard let i = all.firstIndex(where: { $0.0 == s && $0.1 == e }), all.indices.contains(i + dir) else { return nil }
        return (all[i + dir].0, all[i + dir].1)
    }

    func state() -> [String: Any] {
        var s: [String: Any] = [:]
        // Only while our title is the one on the TV: the cover and choices for the players on every screen.
        // A non-empty title only: "x".hasPrefix("") is true, and an old untitled entry hid the torrent film (2026-10-23).
        if let c = current, let t = c["title"] as? String, !t.isEmpty, Caster.shared.title.hasPrefix(t) {
            for key in ["id", "url", "title", "poster", "season", "episode", "quality", "qualities", "translator", "translatorName"] { s[key] = c[key] }
        } else if let f = film, !Caster.shared.title.isEmpty, !Caster.shared.torrent.isEmpty || Caster.shared.mix != nil {
            // A torrent of a film card: the players show the film, not the file name.
            for key in ["id", "url", "title", "poster", "season", "episode"] { s[key] = f[key] }
            s["source"] = "torrent"
        }
        if let n = next { s["next"] = n }
        ensureKeeper()
        // Releases in use now with their "↓ лишити" mark, for the dock.
        if let d = try? Data(contentsOf: Self.mixDir.appendingPathComponent("watch-torrents.json")),
           let reg = try? JSONSerialization.jsonObject(with: d) as? [String: [String: Any]] {
            let keep = (try? Data(contentsOf: Self.mixDir.appendingPathComponent("keep.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Bool] } ?? [:]
            s["keep"] = reg.filter { $0.value["active"] as? Bool == true }.map { h, e -> [String: Any] in
                ["hash": h, "keep": keep[h] ?? false, "files": e["files"] ?? [], "save": e["save"] ?? [:], "mixed": e["mix"] != nil] }
            // Saved pairs in progress (for the downloads view): kept, with a voice, not finished.
            s["saving"] = reg.filter { keep[$0.key] == true && $0.value["mix"] != nil }.map { h, e -> [String: Any] in
                ["hash": h, "files": e["files"] ?? [], "save": e["save"] ?? [:], "label": (e["mix"] as? [String: Any])?["label"] ?? ""] }
        }
        if let p = switchStatus, let d = try? Data(contentsOf: URL(fileURLWithPath: p)),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { s["plan"] = j }
        if !s.isEmpty { s["hasPrev"] = neighbour(-1) != nil; s["hasNext"] = neighbour(1) != nil }
        return s
    }

    func handle(_ cmd: String, _ b: [String: Any]) async -> Any {
#if PROVIDER_HDREZKA
        if let r = await hdrezka(cmd, b) { return r }
#endif
        switch cmd {
        case "kino/home": return store.home()
        case "kino/search2":
            // Owner: search must not depend on HDRezka - IMDb / Wikidata names, shown as film cards with all sources.
            return await Discover.run(["search", b["q"] as? String ?? ""]) ?? ["items": []]
        case "kino/bookmark": store.bookmark(b, on: b["on"] as? Bool ?? true); return store.home()
        case "kino/forget": store.forget(b["id"] as? String ?? ""); return store.home()
        case "kino/next/cancel": nextTimer?.cancel(); next = nil; return ["ok": true]
        case "kino/torrents":
            // Optional torrent index providers (providers/trackers); none are compiled in by default.
            return await Providers.searchTorrents(title: b["title"] as? String ?? "", original: b["original"] as? String ?? "")
        case "kino/discover": return await Discover.list(b["tab"] as? String ?? "top", b["param"] as? String ?? "")
        case "kino/refresh": Discover.refreshAll(); return Discover.progress()
        case "kino/refresh/state": return Discover.progress()
        case "kino/seed": return await Discover.run(["seed"]) ?? ["error": "Немає даних"]
        case "kino/taste":
            // Questionnaire answers live with the history and lists (kino.json "taste"); discover.py reads them.
            if let t = b["taste"] as? [String: Any] { store.setTaste(t) }
            return ["taste": store.taste]
        case "kino/directors": return await Discover.run(["directors"]) ?? []
        case "kino/trailer": return await Discover.trailer(b["title"] as? String ?? "", year: b["year"] as? Int ?? 0, tv: b["tv"] as? Bool ?? false)
        case "kino/list":
            // Owner: "В закладки" and "Подивитись" for films found in Discover (keyed by IMDb id).
            guard let it = b["item"] as? [String: Any], let l = b["list"] as? String, ["fav", "watch"].contains(l) else { return ["error": "Невідомий список"] }
            store.mark(l, it, on: b["on"] as? Bool ?? true); return store.home()
        case "kino/downloads", "kino/download/bg", "kino/download/remove", "kino/download/pause":
            return await Downloads.handle(cmd, b, positions: torrentPositions)
        case "kino/phone/torrent": return await PhoneWatch.start()
        case "kino/media": return await Library.list(b, positions: torrentPositions)
        case "kino/torrents/any":
            // Search tab (owner: "type anything, it searches everywhere, download to core host"): one request per index.
            guard let q = (b["q"] as? String)?.trimmingCharacters(in: .whitespaces), q.count >= 2 else { return [] as [Any] }
            return await Providers.searchAny(q)
        case "kino/open":
            // A link pasted on the home screen (YouTube, a web page, a magnet, HDRezka): to the TV, and into the
            // recent links (5 newest; pinned ones stay apart, at most 3).
            guard let u = (b["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !u.isEmpty else { return ["error": "Порожнє посилання"] }
            store.link(u, title: b["title"] as? String); TV.shared.open(u); return store.links
        case "kino/links":
            if let u = b["remove"] as? String { store.unlink(u) }
            if let u = b["pin"] as? String { store.pin(u, on: b["on"] as? Bool ?? true) }
            return store.links
        case "kino/inbox":
            // Agents send films here ("відправ на ТВ" / "запиши"): POST {add: {title, url|magnet|imdb|path, from, note}, play: bool}.
            // The owner sees them as "Від агентів" on the home screen and marks them watched.
            if var a = b["add"] as? [String: Any], (a["title"] as? String).map({ !$0.isEmpty }) == true {
                a["at"] = Date().timeIntervalSince1970; a["id"] = UUID().uuidString.prefix(8).lowercased()
                store.inbox(add: a)
                if b["play"] as? Bool == true, let u = (a["url"] ?? a["magnet"] ?? a["path"]) as? String { TV.shared.open(u) }
            }
            if let id = b["done"] as? String { store.inbox(done: id) }
            if let id = b["remove"] as? String { store.inbox(remove: id) }
            return ["items": store.inboxItems]
        case "kino/media/phone":
            guard let p = b["path"] as? String, Library.allowed(p) else { return ["error": "Файл поза медіатекою"] }
            return await PhoneWatch.file(p, from: b["from"] as? Double ?? store.torrentPos("file:" + p) ?? 0)
        case "kino/download/phone":
            guard let m = b["magnet"] as? String else { return ["error": "Немає магнета"] }
            return await torrentHere(m)
        case "kino/phone/seek":
            // 1:1 seeking: a second the stream has not reached yet restarts it from there (owner).
            return await PhoneWatch.seek(b["at"] as? Double ?? 0)
        case "kino/screens":
            if let id = b["remove"] as? String { Screens.remove(id) }
            if let id = b["rename"] as? String, let n = b["name"] as? String { Screens.rename(id, n) }
            return ["screens": Screens.all(), "pair": TV.macIP().map { "http://\($0):\(MediaServer.port.rawValue)/screen" } ?? ""]
        case "kino/screens/send":
            // A paired screen plays it: the same HLS, its LAN path pushed to the screen's next poll.
            guard let id = b["id"] as? String else { return ["error": "Немає екрана"] }
            let r: Any
            // Owner 2026-10-22: every source can go to every screen - a rutracker release (topic), a page link, a direct stream.
            var mag = b["magnet"] as? String
            if mag == nil, let t = b["topic"] as? String { mag = await Providers.magnet(topic: t) }
            if let m = mag { r = await torrentHere(m) }
            else if let u = b["url"] as? String, u.hasPrefix("http") {
                r = ["url": u, "title": b["title"] as? String ?? "", "from": b["from"] as? Double ?? 0, "dur": 0] }
            else if let pg = b["page"] as? String, pg.hasPrefix("http") {
                guard let d = await Direct.resolve(pg) else { return ["error": "Це посилання грає лише через ТВ"] }
                r = ["url": d, "title": b["title"] as? String ?? pg, "from": b["from"] as? Double ?? 0, "dur": 0] }
            else if let p = b["path"] as? String, Library.allowed(p) { r = await PhoneWatch.file(p, from: b["from"] as? Double ?? store.torrentPos("file:" + p) ?? 0) }
            else { r = await PhoneWatch.start() }
            guard let d = r as? [String: Any], let url = d["url"] as? String else { return r }
            guard Screens.send(id, ["play": ["url": url, "title": d["title"] ?? "", "from": d["from"] ?? 0, "dur": d["dur"] ?? 0]]) else { return ["error": "Екран не знайдено"] }
            return ["ok": true, "title": d["title"] ?? ""]
        case "kino/here/start":
            // Two planes (owner 2026-10-22): the core says what and from which second, the device fetches the media
            // itself from the source. core host HLS only for what lives on core host (files, torrents) or on "hls": true
            // (the device could not open the source, e.g. a phone away from home: YouTube links are tied to our IP).
            if let m = b["magnet"] as? String { return await torrentHere(m) }
            if let t = b["topic"] as? String {
                guard let m = await Providers.magnet(topic: t) else { return ["error": "Не знайшов магнет у роздачі"] }
                return await torrentHere(m) }
            if let p = b["path"] as? String, Library.allowed(p) {
                return await PhoneWatch.file(p, from: b["from"] as? Double ?? store.torrentPos("file:" + p) ?? 0) }
            // Any link straight to this device (a YouTube page, an mp4); without one - what the TV plays.
            if let p = b["page"] as? String, p.hasPrefix("http") {
                if b["hls"] as? Bool == true {   // fallback: core host reads the same source and serves HLS
                    let s = await Direct.resolve(p).map { Direct.variants[p] ?? $0 } ?? p
                    let from: Double = b["from"] as? Double ?? store.torrentPos("url:" + p) ?? 0
                    var r = await PhoneWatch.start(src: s, probeURL: s, from: from, title: b["title"] as? String ?? Direct.titles[p] ?? p, track: 0)
                    if var d = r as? [String: Any] { d["key"] = "url:" + p; r = d }
                    return r
                }
                guard let d = await Direct.resolve(p) else { return ["error": "Це посилання грає лише через ТВ"] }
                // Typed first: inside an Any literal `a ?? b ?? c` can stay Optional, and JSONSerialization then throws
                // an Objective-C exception that try? misses - it broke the main queue and the whole core went deaf.
                let title: String = b["title"] as? String ?? Direct.titles[p] ?? p
                let from: Double = b["from"] as? Double ?? store.torrentPos("url:" + p) ?? 0
                return ["direct": d, "title": title, "from": from, "key": "url:" + p]
            }
            let c = Caster.shared, page = c.page
            if b["hls"] as? Bool != true, page.hasPrefix("http"), let d = await Direct.resolve(page) {
                return ["direct": d, "title": c.title, "from": max(0, c.displayPosition - 1), "dur": c.duration, "key": "url:" + page]
            }
            return await PhoneWatch.start()
        case "kino/media/progress":
            // The phone's own player keeps the file's second too (same memory as the TV); a torrent by its hash.
            if let k = b["key"] as? String, k.hasPrefix("url:") || k.hasPrefix("file:"), let pos = b["position"] as? Double, pos > 5 {
                store.saveTorrent(k, position: pos, duration: b["duration"] as? Double ?? 0, name: b["name"] as? String ?? "") }
            if let h = b["hash"] as? String, h.count == 40, h.allSatisfy(\.isHexDigit), let pos = b["position"] as? Double, pos > 5 {
                store.saveTorrent(h, position: pos, duration: b["duration"] as? Double ?? 0, name: b["name"] as? String ?? "") }
            if let p = b["path"] as? String, Library.allowed(p), let pos = b["position"] as? Double, pos > 5 {
                store.saveTorrent("file:" + p, position: pos, duration: b["duration"] as? Double ?? 0, name: (p as NSString).lastPathComponent) }
            return ["ok": true]
        case "kino/media/play":
            guard let p = b["path"] as? String, Library.allowed(p) else { return ["error": "Файл поза медіатекою"] }
            TV.shared.open(p); Caster.shared.startAt = b["from"] as? Double ?? store.torrentPos("file:" + p) ?? 0
            return ["ok": true]
        case "kino/download/add":
            // "↓ Скачати": into the background downloads, the TV is not touched.
            var m = b["magnet"] as? String
            if m == nil, let id = b["topic"] as? String { m = await Providers.magnet(topic: id) }
            guard let m else { return ["error": "Не знайшов магнет у роздачі"] }
            return await Downloads.fetch(m) ? ["ok": true] : ["error": "Рушій торентів не працює"]
        case "kino/download/play":
            guard let m = b["magnet"] as? String else { return ["error": "Немає магнета"] }
            TV.shared.open(m); Caster.shared.startAt = b["from"] as? Double ?? torrentResume(m)
            return ["ok": true]
        case "kino/torrent/use":
            // Magnet from the rutracker page (topic) or as found; "from" = start at that second; while an HDRezka
            // episode plays, it is the fallback if the torrent fails or starves.
            var m = b["magnet"] as? String
            if m == nil, let id = b["topic"] as? String { m = await Providers.magnet(topic: id) }
            guard let m else { return ["error": "Не знайшов магнет у роздачі"] }
            // Owner: one film = one position, whatever the source. A torrent started from a film card belongs to that
            // film: no choice made -> where the film stopped (HDRezka or another torrent), else this torrent's own spot.
            // UX review 47: a torrent started from Search / Media has no film card; a release named after a film in the
            // history ("Лоуренс Аравийский / Lawrence of Arabia (1962) …") continues that film's one position.
            let f = b["film"] as? [String: Any] ?? store.film(named: Self.releaseName(m))
            var filmPos: Double?
            if let f, let fid = f["id"] as? String {
                filmPos = store.episodePosition(fid, season: f["season"] as? Int, episode: f["episode"] as? Int)
                if store.progress(fid) == nil { store.recordStart(f) }
            }
            // Owner 2026-10-23: E06 played for E18. A release named after one other episode never starts for this one.
            if let f, let s = f["season"] as? Int, let e = f["episode"] as? Int {
                let n = Self.releaseName(m).isEmpty ? (b["name"] as? String ?? "") : Self.releaseName(m)
                if let r = n.range(of: #"(?i)s(\d{1,2})[ ._-]?e(\d{1,3})(?!\d)(?![ ._-]*[-–])"#, options: .regularExpression) {
                    let d = n[r].lowercased().split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
                    if d.count >= 2, d[0] != s || d[1] != e {
                        return ["error": "Ця роздача - S\(String(format: "%02d", d[0]))E\(String(format: "%02d", d[1])), а не S\(String(format: "%02d", s))E\(String(format: "%02d", e))"]
                    }
                }
            }
            let from = b["from"] as? Double ?? filmPos ?? torrentResume(m)
            let back = current.flatMap { cur -> [String: Any]? in (cur["title"] as? String).map { !$0.isEmpty && Caster.shared.title.hasPrefix($0) } == true ? cur : nil }
            film = f; filmSaved = Date.distantPast
            TV.shared.open(m)
            Caster.shared.startAt = from
            Caster.shared.torrentEpisode = f.flatMap { f in (f["season"] as? Int).flatMap { s in (f["episode"] as? Int).map { "\(s)x\($0)" } } }
            Caster.shared.fallback = back.map { cur in { [weak self] in
                guard let self else { return }
                var c = cur; c["from"] = max(Caster.shared.displayPosition, from)
                Task { _ = await self.replay(c) }
            } }
            return ["ok": true]
        case "kino/mix":
            // "Озвучка з іншого джерела": the picture that plays now + an HDRezka voice (or a dub file on tinyTV Core).
            let label: String, dub: String, key: String
            var dubTrack = 0
            if let path = b["path"] as? String {
                // Only media folders (and the Transmission folder on External), never an arbitrary path from the network.
                guard PhoneServer.movieRoots.map(\.path).contains(where: { path.hasPrefix($0 + "/") }) || path.hasPrefix("/Volumes/External/Torrent/"), !path.contains("/../"),
                      FileManager.default.fileExists(atPath: path) else { return ["error": "Немає такого файлу"] }
                // A downloaded release (folder): the file of this episode (SxxEyy), else its largest media file.
                var file = path, isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                    let exts: Set<String> = ["mkv", "mp4", "avi", "ts", "m2ts", "mka", "ac3", "eac3", "dts", "aac", "m4a", "flac"]
                    let all = (FileManager.default.enumerator(atPath: path)?.compactMap { $0 as? String } ?? [])
                        .filter { exts.contains(($0 as NSString).pathExtension.lowercased()) }.map { (path as NSString).appendingPathComponent($0) }
                    let size = { (f: String) in (try? FileManager.default.attributesOfItem(atPath: f)[.size] as? Int) ?? 0 ?? 0 }
                    var pick = all.max { size($0) < size($1) }
                    if let s = b["season"] as? Int, let e = b["episode"] as? Int {
                        let tag = String(format: "s%02de%02d", s, e)
                        pick = all.filter { $0.lowercased().replacingOccurrences(of: " ", with: "").contains(tag) }.max { size($0) < size($1) } ?? pick
                    }
                    guard let pick else { return ["error": "У роздачі немає медіафайлів"] }
                    file = pick
                }
                dub = file; label = (b["label"] as? String) ?? (file as NSString).lastPathComponent; key = Caster.shared.title + "|" + file
                // Its Ukrainian track, else the first one.
                if let probe = Caster.tool("ffprobe") {
                    let r = Caster.run(probe, ["-v", "error", "-select_streams", "a", "-show_entries", "stream_tags=language,title", "-of", "json", file])
                    let st = ((try? JSONSerialization.jsonObject(with: r.out)) as? [String: Any])?["streams"] as? [[String: Any]] ?? []
                    dubTrack = Caster.uaTrack(st) ?? 0
                }
                if let t = b["track"] as? Int { dubTrack = t }   // the planner already read it
            } else {
                guard let id = b["id"] as? String, let tr = b["translator"] as? String else { return ["error": "Не вибрано озвучку"] }
                let season = b["season"] as? Int, episode = b["episode"] as? Int
                // The smallest stream: the sound is the same in every quality, the copy is ~70 MB per hour.
                func rank(_ q: String) -> Int { q.hasSuffix("Premium") ? 99_999 : (Int(q.prefix { $0.isNumber }) ?? 0) }
                guard let pick = await catalogStreams(id: id, translator: tr, season: season, episode: episode).min(by: { rank($0.q) < rank($1.q) })
                else { return ["error": "Для цієї озвучки немає потоку"] }
                dub = pick.url; label = "HDRezka · " + (b["translatorName"] as? String ?? tr)
                key = Caster.shared.title + "|rz\(id)-\(tr)-\(season ?? 0)x\(episode ?? 0)"
            }
            // "video": switch the picture to this downloaded release file at "from" in the same step.
            if let v = b["video"] as? String, Library.allowed(v) || v.hasPrefix("/Volumes/External/Torrent/"), !v.contains("/../") {
                if let cur = current { film = cur; filmSaved = Date.distantPast }   // the dock keeps the film and «Джерело»
                Caster.shared.mixFile(v, from: b["from"] as? Double ?? Caster.shared.displayPosition, dub: dub, track: dubTrack, label: label,
                                      key: (v as NSString).lastPathComponent + key.drop { $0 != "|" } + "#\(dubTrack)")
                return ["ok": true, "label": label]
            }
            Caster.shared.mix(dub: dub, track: dubTrack, label: label, key: key + "#\(dubTrack)")
            return ["ok": true, "label": label]
        case "kino/switch/plan":
            // Owner 2026-10-24: what plays goes on; the release downloads from a future point P, the voice is aligned
            // for P ahead, and at P it switches (switchplan.py). "picture": the release's video with the HDRezka voice;
            // "sound": the release's Ukrainian track over the picture that plays now. The dock shows when.
            let kind = b["kind"] as? String ?? "picture"
            var m = b["magnet"] as? String
            if kind == "sound" {
                if m == nil, let topic = b["topic"] as? String { m = await Providers.magnet(topic: topic) }
                guard let m, let py = Bundle.main.path(forResource: "switchplan", ofType: "py"), let video = Caster.shared.watchInputs.first,
                      Caster.shared.duration > 0 else { return ["error": "Зараз нічого не грає"] }
                let season = (current?["season"] ?? film?["season"]) as? Int, episode = (current?["episode"] ?? film?["episode"]) as? Int
                return startPlan(py, ["kind": "sound", "magnet": m, "duration": Caster.shared.duration, "video": video, "vtrack": Caster.shared.track,
                                      "label": b["label"] as? String ?? "UA з роздачі",
                                      "episode": season.flatMap { s in episode.map { String(format: "s%02de%02d", s, $0) } } as Any? ?? NSNull()])
            }
            guard let cur = current, let id = cur["id"] as? String, let tr = cur["translator"] as? String else {
                return ["error": "Плановий перехід картинки - коли грає HDRezka"] }
            if m == nil, let topic = b["topic"] as? String { m = await Providers.magnet(topic: topic) }
            guard let m, let py = Bundle.main.path(forResource: "switchplan", ofType: "py") else { return ["error": "Не знайшов магнет у роздачі"] }
            let season = cur["season"] as? Int, episode = cur["episode"] as? Int
            func rank(_ q: String) -> Int { q.hasSuffix("Premium") ? 99_999 : (Int(q.prefix { $0.isNumber }) ?? 0) }
            guard let dub = await catalogStreams(id: id, translator: tr, season: season, episode: episode).min(by: { rank($0.q) < rank($1.q) })?.url,
                  Caster.shared.duration > 0 else { return ["error": "Немає потоку озвучки або тривалості серії"] }
            let mixBody: [String: Any] = ["id": id, "translator": tr, "translatorName": cur["translatorName"] ?? "", "season": season as Any? ?? NSNull(),
                                          "episode": episode as Any? ?? NSNull(), "key": "rz\(id)-\(tr)-\(season ?? 0)x\(episode ?? 0)"]
            return startPlan(py, ["kind": "picture", "magnet": m, "duration": Caster.shared.duration, "dub": dub, "mix": mixBody,
                                  "episode": season.flatMap { s in episode.map { String(format: "s%02de%02d", s, $0) } } as Any? ?? NSNull()])
        case "kino/prepare":
            // «Підготувати на потім»: a release + an HDRezka voice, downloaded in order and muxed for later (switchplan.py).
            var m = b["magnet"] as? String
            if m == nil, let topic = b["topic"] as? String { m = await Providers.magnet(topic: topic) }
            guard let m, let id = b["id"] as? String, let tr = b["translator"] as? String,
                  let py = Bundle.main.path(forResource: "switchplan", ofType: "py") else { return ["error": "Не вибрано роздачу чи озвучку"] }
            let season = b["season"] as? Int, episode = b["episode"] as? Int
            func rank(_ q: String) -> Int { q.hasSuffix("Premium") ? 99_999 : (Int(q.prefix { $0.isNumber }) ?? 0) }
            guard let dub = await catalogStreams(id: id, translator: tr, season: season, episode: episode).min(by: { rank($0.q) < rank($1.q) })?.url
            else { return ["error": "Для цієї озвучки немає потоку"] }
            let dir = Self.mixDir; try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let tag = UUID().uuidString.prefix(8), planURL = dir.appendingPathComponent("prepare-\(tag).json")
            let plan: [String: Any] = ["kind": "prepare", "magnet": m, "duration": 1, "dub": dub, "mixdir": dir.path,
                                       "label": "HDRezka · " + (b["translatorName"] as? String ?? tr),
                                       "episode": season.flatMap { s in episode.map { String(format: "s%02de%02d", s, $0) } } as Any? ?? NSNull()]
            guard let data = try? JSONSerialization.data(withJSONObject: plan), (try? data.write(to: planURL)) != nil else { return ["error": "Не вдалося записати план"] }
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = [py, planURL.path, dir.appendingPathComponent("prepare-\(tag)-status.json").path]
            p.standardOutput = FileHandle.nullDevice; p.standardError = Caster.ffmpegLog()
            do { try p.run() } catch { return ["error": "Не вдалося запустити"] }
            return ["ok": true]
        case "kino/switch/cancel":
            if let s = switchStatus { FileManager.default.createFile(atPath: s + ".cancel", contents: nil) }
            switchPlan?.terminate(); switchPlan = nil
            return ["ok": true]
        case "kino/keep":
            // Owner 2026-10-24: "↓" keeps a release started for watching; unmarked ones are deleted after viewing (keeper.py).
            guard let h = (b["hash"] as? String)?.lowercased(), h.allSatisfy(\.isHexDigit) else { return ["error": "Немає такого торента"] }
            let u = Self.mixDir.appendingPathComponent("keep.json")
            var k = (try? Data(contentsOf: u)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Bool] } ?? [:]
            k[h] = b["keep"] as? Bool ?? true
            if let d = try? JSONSerialization.data(withJSONObject: k) { try? d.write(to: u) }
            // A torrent of the TV engine: kept = it downloads to the end and stays; not kept = keeper.py removes it after viewing.
            _ = await Downloads.handle("kino/download/bg", ["hash": h, "on": k[h] ?? false])
            return ["ok": true, "keep": k[h] ?? false]
        case "kino/mix/nudge": Caster.shared.mixNudge(b["d"] as? Double ?? 0); return Caster.shared.mixState
        case "kino/mix/off": Caster.shared.mixOff(); return ["ok": true]
        case "kino/progress":
            if let id = b["id"] as? String { store.saveProgress(id, position: b["position"] as? Double ?? 0, duration: b["duration"] as? Double ?? 0) }
            return ["ok": true]
        default: return ["error": "Невідома команда"]
        }
    }

    /// A torrent that fails or starves falls back to the catalog stream it replaced (catalog providers only).
    func replay(_ item: [String: Any]) async -> Any {
#if PROVIDER_HDREZKA
        return await play(item)
#else
        return ["error": "No catalog provider"]
#endif
    }

    /// Streams of a catalog title (a voice for "Озвучка з іншого джерела"); empty without a catalog provider.
    func catalogStreams(id: String, translator: String, season: Int?, episode: Int?) async -> [(q: String, url: String)] {
#if PROVIDER_HDREZKA
        return await catalogStreams(id: id, translator: translator, season: season, episode: episode)
#else
        return []
#endif
    }
}


/// Bookmarks and history on disk (core): ~/Library/Application Support/tinyTV/kino.json.
@MainActor
final class KinoStore {
    private let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/tinyTV/kino.json")
    private var data: [String: Any]

    init() {
        data = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            ?? ["bookmarks": [[String: Any]](), "history": [[String: Any]]()]
    }

    private var bookmarks: [[String: Any]] { get { data["bookmarks"] as? [[String: Any]] ?? [] } set { data["bookmarks"] = newValue } }
    private var history: [[String: Any]] { get { data["history"] as? [[String: Any]] ?? [] } set { data["history"] = newValue } }

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: data) { try? d.write(to: url, options: .atomic) }
    }

    private static let keep = ["id", "url", "title", "poster", "year", "series"]
    private func card(_ b: [String: Any]) -> [String: Any] { b.filter { KinoStore.keep.contains($0.key) } }

    func home() -> [String: Any] { ["bookmarks": favourites, "history": history, "fav": favourites, "watch": data["watch"] ?? []] }
    /// Owner 2026-10-22 (UX review 5): one "Обране" everywhere. The film page star (HDRezka id) and the Discover star
    /// (IMDb id) were two lists both called "Закладки"; this is their union, newest first, one entry per film.
    private var favourites: [[String: Any]] {
        var out = data["fav"] as? [[String: Any]] ?? []
        for b in bookmarks where !out.contains(where: { Self.same($0, b) }) { out.append(b) }
        return out
    }
    static func same(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        if let x = a["id"] as? String, let y = b["id"] as? String, x == y { return true }
        if let x = a["imdb"] as? String, let y = b["imdb"] as? String, x == y { return true }
        let t = { (d: [String: Any]) in [d["title"], d["ru"], d["orig"]].compactMap { ($0 as? String)?.lowercased() }.filter { !$0.isEmpty } }
        let ya = "\(a["year"] ?? "")", yb = "\(b["year"] ?? "")"
        return ya == yb && !Set(t(a)).isDisjoint(with: t(b))
    }

    var taste: [String: Any] { data["taste"] as? [String: Any] ?? [:] }

    var links: [String: Any] { ["recent": data["links"] ?? [], "pinned": data["pinned"] ?? []] }
    func link(_ u: String, title: String?) {
        let pinned = data["pinned"] as? [[String: Any]] ?? []
        guard !pinned.contains(where: { $0["url"] as? String == u }) else { return }
        var l = (data["links"] as? [[String: Any]] ?? []).filter { $0["url"] as? String != u }
        l.insert(["url": u, "title": title ?? "", "at": Date().timeIntervalSince1970], at: 0)
        data["links"] = Array(l.prefix(5)); save()
    }
    func unlink(_ u: String) {
        data["links"] = (data["links"] as? [[String: Any]] ?? []).filter { $0["url"] as? String != u }
        data["pinned"] = (data["pinned"] as? [[String: Any]] ?? []).filter { $0["url"] as? String != u }; save()
    }
    func pin(_ u: String, on: Bool) {
        var p = (data["pinned"] as? [[String: Any]] ?? []).filter { $0["url"] as? String != u }
        var l = (data["links"] as? [[String: Any]] ?? []).filter { $0["url"] as? String != u }
        let item: [String: Any] = ["url": u, "at": Date().timeIntervalSince1970]
        if on { p.insert(item, at: 0); p = Array(p.prefix(3)) } else { l.insert(item, at: 0); l = Array(l.prefix(5)) }
        data["pinned"] = p; data["links"] = l; save()
    }

    var inboxItems: [[String: Any]] { data["inbox"] as? [[String: Any]] ?? [] }
    func inbox(add a: [String: Any]) { data["inbox"] = Array(([a] + inboxItems).prefix(60)); save() }
    func inbox(done id: String) {
        data["inbox"] = inboxItems.map { var x = $0; if x["id"] as? String == id { x["seen"] = Date().timeIntervalSince1970 }; return x }; save()
    }
    func inbox(remove id: String) { data["inbox"] = inboxItems.filter { $0["id"] as? String != id }; save() }
    func setTaste(_ t: [String: Any]) { var t = t; t["at"] = Date().timeIntervalSince1970; data["taste"] = t; save() }

    /// Torrent positions by hash: [pos, dur] plus the file name.
    func saveTorrent(_ hash: String, position: Double, duration: Double, name: String) {
        var t = data["tpos"] as? [String: [String: Any]] ?? [:]
        t[hash.lowercased()] = ["pos": position, "dur": duration, "name": name, "at": Date().timeIntervalSince1970]
        data["tpos"] = t; save()
    }
    func torrentPos(_ hash: String) -> Double? {
        guard let t = (data["tpos"] as? [String: [String: Any]])?[hash.lowercased()], let p = t["pos"] as? Double, let d = t["dur"] as? Double else { return nil }
        return p > 60 && (d <= 0 || p < d - 120) ? p : nil
    }
    var torrentPositions: [String: [String: Any]] { data["tpos"] as? [String: [String: Any]] ?? [:] }

    /// Discover lists: "fav" (В закладки) and "watch" (Подивитись), newest first.
    func mark(_ list: String, _ it: [String: Any], on: Bool) {
        guard let id = it["imdb"] as? String else { return }
        var l = data[list] as? [[String: Any]] ?? []
        l.removeAll { ($0["imdb"] as? String) == id }
        if list == "fav", !on { bookmarks.removeAll { Self.same($0, it) } }   // one "Обране": unstar here = unstar everywhere
        if on { l.insert(it.filter { ["imdb", "title", "orig", "ru", "year", "poster", "dirs", "imdbR", "rt", "badges"].contains($0.key) }, at: 0) }
        data[list] = l; save()
    }
    func isBookmarked(_ id: String) -> Bool { favourites.contains { ($0["id"] as? String) == id } }
    /// The history film a release name belongs to: its title inside the name and, when the name has a year, the same year.
    func film(named n: String) -> [String: Any]? {
        let low = n.lowercased().replacingOccurrences(of: "[._+]", with: " ", options: .regularExpression)
        let year = low.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression).map { String(low[$0]) }
        return history.first { h in
            guard let t = (h["title"] as? String)?.lowercased(), t.count >= 3, h["series"] as? Bool != true, low.contains(t) else { return false }
            return year == nil || "\(h["year"] ?? "")" == year
        }.map { h in ["id": h["id"] ?? "", "url": h["url"] ?? "", "title": h["title"] ?? "", "poster": h["poster"] ?? "", "year": h["year"] ?? "", "series": false] }
    }
    func progress(_ id: String) -> [String: Any]? { history.first { ($0["id"] as? String) == id } }

    func bookmark(_ b: [String: Any], on: Bool) {
        guard let id = b["id"] as? String else { return }
        bookmarks.removeAll { ($0["id"] as? String) == id }
        if on { bookmarks.insert(card(b), at: 0) }
        else { data["fav"] = (data["fav"] as? [[String: Any]] ?? []).filter { !Self.same($0, b) } }
        save()
    }

    func forget(_ id: String) { history.removeAll { ($0["id"] as? String) == id }; save() }

    func recordStart(_ b: [String: Any]) {
        guard let id = b["id"] as? String else { return }
        var h = progress(id) ?? card(b)
        for k in ["translator", "translatorName", "season", "episode", "quality", "seasons"] { if let v = b[k] { h[k] = v } }
        if (b["from"] as? Double ?? 0) < 1 { h["position"] = 0 }
        h["updated"] = Date().timeIntervalSince1970
        history.removeAll { ($0["id"] as? String) == id }
        history.insert(h, at: 0)
        if history.count > 60 { history = Array(history.prefix(60)) }
        save()
    }

    /// Saves the title's last position and, per episode ("season:episode"), [position, duration].
    /// 90 % watched (or under 2 min left) marks the episode watched, so the grid colours it without waiting for the end.
    func saveProgress(_ id: String, position: Double, duration: Double) {
        guard let i = history.firstIndex(where: { ($0["id"] as? String) == id }) else { return }
        var h = history[i]; h["position"] = position; if duration > 0 { h["duration"] = duration }
        h["updated"] = Date().timeIntervalSince1970
        let key = "\(h["season"] as? Int ?? 0):\(h["episode"] as? Int ?? 0)"
        var eps = h["eps"] as? [String: [Double]] ?? [:]
        let dur = duration > 0 ? duration : (eps[key]?.last ?? 0)
        eps[key] = [position, dur]; h["eps"] = eps
        if dur > 0, position >= dur * 0.9 || dur - position < 120 {
            var w = h["watched"] as? [String] ?? []; if !w.contains(key) { w.append(key) }; h["watched"] = w
        }
        history[i] = h; save()
    }

    func episodePosition(_ id: String, season: Int?, episode: Int?) -> Double? {
        guard let h = progress(id) else { return nil }
        if let m = (h["eps"] as? [String: [Double]])?["\(season ?? 0):\(episode ?? 0)"], let p = m.first, p > 0 { return p }
        return season == nil ? h["position"] as? Double : nil
    }

    func markWatched(_ id: String, season: Int?, episode: Int?) {
        guard let i = history.firstIndex(where: { ($0["id"] as? String) == id }) else { return }
        var h = history[i]; var w = h["watched"] as? [String] ?? []
        let key = "\(season ?? 0):\(episode ?? 0)"; if !w.contains(key) { w.append(key) }
        h["watched"] = w; history[i] = h; save()
    }
}


/// Torrent downloads on tinyTV Core (TV Cast engine, ~/Downloads/Torrent): the list like qBittorrent, "На фоні", delete.
/// hash "active" means the torrent that plays on the TV now.
enum Downloads {
    private static let base = "http://127.0.0.1:8890"

    static func list() async -> [String: Any]? {
        guard let u = URL(string: base + "/list"), let (d, _) = try? await URLSession.shared.data(from: u) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    static func fetch(_ magnet: String) async -> Bool {
        var r = URLRequest(url: URL(string: base + "/fetch")!); r.httpMethod = "POST"; r.httpBody = Data(magnet.utf8)
        guard let (_, resp) = try? await URLSession.shared.data(for: r) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    static func handle(_ cmd: String, _ b: [String: Any], positions: [String: [String: Any]] = [:]) async -> Any {
        guard var l = await list() else { return ["error": "Рушій торентів не працює"] }
        if cmd == "kino/downloads" {
            // Where he stopped in each torrent (saved by hash) goes with the list: "▶ Дивитись з 28:37".
            l["torrents"] = ((l["torrents"] as? [[String: Any]]) ?? []).map { t in
                var t = t; if let h = t["hash"] as? String, let p = positions[h.lowercased()] { t["pos"] = p["pos"]; t["dur"] = p["dur"] }; return t }
            return l
        }
        var hash = b["hash"] as? String ?? ""
        if hash == "active" {
            hash = ((l["torrents"] as? [[String: Any]]) ?? []).first { $0["active"] as? Bool == true }?["hash"] as? String ?? ""
        }
        guard !hash.isEmpty, hash.allSatisfy(\.isHexDigit) else { return ["error": "Немає такого торента"] }
        let on = (b["on"] as? Bool ?? true) ? 1 : 0
        let path = cmd == "kino/download/bg" ? "/background?hash=\(hash)&on=\(on)" : cmd == "kino/download/pause" ? "/pause?hash=\(hash)&on=\(on)" : "/remove?hash=\(hash)&files=1"
        var r = URLRequest(url: URL(string: base + path)!); r.httpMethod = "POST"
        guard let (_, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else { return ["error": "Не вийшло"] }
        if cmd == "kino/download/remove", ((l["torrents"] as? [[String: Any]]) ?? []).contains(where: { $0["hash"] as? String == hash && $0["active"] as? Bool == true }) {
            await MainActor.run { Caster.shared.stop() }   // it was playing on the TV: nothing to play any more
        }
        return await list() ?? ["ok": true]
    }
}


/// One list from every source: duplicates merged, each release graded by seeders (owner: green / yellow / red),
/// best first - grade, then quality, then seeders.
enum TorrentRank {
    static func row(title: String, bytes: Double, seeds: Int, peers: Int, tracker: String, hash: String, magnet: String) -> [String: Any] {
        let lt = title.lowercased()
        let q = lt.contains("2160") || lt.contains("4k") || lt.contains("uhd") ? 2160 : lt.contains("1080") ? 1080 : lt.contains("720") ? 720 : 480
        var seasons: [Int] = []
        if let r = lt.range(of: #"s(\d{1,2})(?:e\d+)?\b"#, options: .regularExpression) { seasons = [Int(lt[r].dropFirst().prefix { $0.isNumber }) ?? 0] }
        else if let r = lt.range(of: #"season\s*(\d{1,2})"#, options: .regularExpression), let n = Int(lt[r].filter(\.isNumber)) { seasons = [n] }
        return ["title": title, "quality": q, "hdr": lt.contains("hdr") || lt.contains("dolby vision") || lt.contains(" dv "),
                "size": bytes > 0 ? String(format: "%.2f GB", bytes / 1_073_741_824) : "", "seeds": seeds, "peers": peers,
                "tracker": tracker, "seasons": seasons.filter { $0 > 0 }, "magnet": magnet, "hash": hash.uppercased()]
    }

    static func grade(_ seeds: Int) -> String { seeds >= 20 ? "g" : seeds >= 5 ? "y" : "r" }

    static func merge(_ sources: [[[String: Any]]]) -> [[String: Any]] {
        var out: [[String: Any]] = [], index: [String: Int] = [:]
        func keys(_ r: [String: Any]) -> [String] {
            var k: [String] = []
            if let h = r["hash"] as? String, !h.isEmpty { k.append(h.uppercased()) }
            if let t = r["topic"] as? String, !t.isEmpty { k.append("rt:" + t) }
            if let u = r["url"] as? String, u.contains("rutracker"), let q = URLComponents(string: u)?.queryItems?.first(where: { $0.name == "t" })?.value { k.append("rt:" + q) }
            return k
        }
        for list in sources { for r in list {
            let ks = keys(r)
            if let i = ks.compactMap({ index[$0] }).first {
                // Same release: keep the first copy (the owner's rutracker row first), take the higher counts.
                out[i]["seeds"] = max(out[i]["seeds"] as? Int ?? 0, r["seeds"] as? Int ?? 0)
                out[i]["peers"] = max(out[i]["peers"] as? Int ?? 0, r["peers"] as? Int ?? 0)
                if out[i]["magnet"] == nil, let m = r["magnet"] { out[i]["magnet"] = m }
                ks.forEach { index[$0] = i }
            } else { out.append(r); ks.forEach { index[$0] = out.count - 1 } }
        } }
        // mazepa is multi-tracker (Toloka shares the swarm) and shows only its own seeders: "unknown", not red.
        let rank = ["g": 0, "y": 1, "u": 1, "r": 2]
        for i in out.indices {
            let s = out[i]["seeds"] as? Int ?? 0
            out[i]["grade"] = (out[i]["tracker"] as? String) == "mazepa" && s < 20 ? "u" : grade(s)
        }
        return out.sorted { a, b in
            let ga = rank[a["grade"] as? String ?? "r"] ?? 2, gb = rank[b["grade"] as? String ?? "r"] ?? 2
            if ga != gb { return ga < gb }
            let qa = a["quality"] as? Int ?? 0, qb = b["quality"] as? Int ?? 0
            return qa != qb ? qa > qb : (a["seeds"] as? Int ?? 0) > (b["seeds"] as? Int ?? 0)
        }.prefix(150).map { $0 }
    }
}


/// Discover tab (owner-approved concept 2026-10-21): lists come from discover.py on this machine
/// (IMDb datasets + Wikidata + Wikipedia posters, cached on the SSD); trailers via yt-dlp from YouTube.
@MainActor
enum Discover {
    private static var built = Date.distantPast

    static func run(_ args: [String]) async -> Any? {
        guard let py = Bundle.main.path(forResource: "discover", ofType: "py") else { return nil }
        return await Task.detached {
            let r = Caster.run("/usr/bin/python3", [py] + args)
            return try? JSONSerialization.jsonObject(with: r.out)
        }.value
    }

    /// The base is rebuilt in the background at most once a day (IMDb publishes daily).
    static func refresh() {
        guard Date().timeIntervalSince(built) > 20 * 3600, let py = Bundle.main.path(forResource: "discover", ofType: "py") else { return }
        built = Date()
        Task.detached { _ = Caster.run("/usr/bin/python3", [py, "build"]) }
    }

    static func list(_ tab: String, _ param: String) async -> Any {
        refresh()
        guard var r = await run(["list", tab, param]) as? [String: Any] else { return ["error": "Не вийшло зібрати список", "items": []] }
        // Films of this tab not checked yet go to the front of the availability queue; the page polls until done.
        if let p = r["pending"] as? [[String: Any]], !p.isEmpty { enqueue(p, front: true) }
        r["checking"] = queue.count
        return r
    }

    // MARK: availability (owner: show only what can be watched)
    private static var queue: [[String: Any]] = []
    private static var queued = Set<String>()
    private static var working = false, building = false, checked = 0
    private static var availPath: String?

    /// HDRezka limits its search per address (measured 2026-10-21: HTTP 500 for every search after ~400 in 30 min,
    /// for the Mac and core host alike). So: one HDRezka search per 10 s, and a 30 min pause when it starts refusing.
    private static var rzPausedUntil = Date.distantPast, rzMisses = 0
    static func progress() -> [String: Any] { ["building": building, "queue": queue.count, "checked": checked, "working": working,
                                              "rzPaused": rzPausedUntil > Date() ? Int(rzPausedUntil.timeIntervalSinceNow) : 0] }

    static func enqueue(_ items: [[String: Any]], front: Bool = false) {
        guard Providers.checksAvailability else { return }   // no source to check against: Discover shows everything
        let fresh = items.filter { ($0["imdb"] as? String).map { !queued.contains($0) } ?? false }
        fresh.forEach { queued.insert($0["imdb"] as? String ?? "") }
        queue = front ? fresh + queue : queue + fresh
        if !working { Task { await work() } }
    }

    /// One film at a time: HDRezka (same year) and the torrent index; the result goes to avail.json for discover.py.
    private static func work() async {
        working = true; defer { working = false }
        if availPath == nil { availPath = String(decoding: (await Task.detached { () -> Data in
            guard let py = Bundle.main.path(forResource: "discover", ofType: "py") else { return Data() }
            return Caster.run("/usr/bin/python3", [py, "avail-path"]).out }.value), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let path = availPath, !path.isEmpty else { return }
        while !queue.isEmpty {
            let it = queue.removeFirst()
            guard let id = it["imdb"] as? String else { continue }
            var f: [String: Any] = [:]
#if PROVIDER_HDREZKA
            if rzPausedUntil < Date() {
                f = await Kino.shared.find(it) as? [String: Any] ?? [:]
                // A well-known film with no HDRezka hit, three times running = HDRezka refuses searches: pause it.
                if (f["url"] as? String ?? "").isEmpty { rzMisses += 1 } else { rzMisses = 0 }
                if rzMisses >= 3 { rzPausedUntil = Date().addingTimeInterval(30 * 60); rzMisses = 0 }
            }
#endif
            // A refusal (rate limit, timeout) is not "no torrents": the film goes back to the queue (measured 2026-10-21:
            // 401 films wrongly hidden as "no source" after a burst). Empty index -> The Pirate Bay by the English title.
            let raw = await Providers.availability(title: (it["ru"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (it["title"] as? String ?? ""),
                                                 original: it["orig"] as? String ?? "")
            guard var t = raw as? [[String: Any]] else {
                queue.append(it); try? await Task.sleep(nanoseconds: 30_000_000_000); continue
            }
            if t.isEmpty, let o = it["orig"] as? String, !o.isEmpty { t = await Providers.availabilityByOriginal(o) }
            let ua = t.contains { (($0["title"] as? String) ?? "").range(of: #"укр|ukr|україн|украин|\bua\b"#, options: [.regularExpression, .caseInsensitive]) != nil }
            if rzPausedUntil > Date(), (f["url"] as? String ?? "").isEmpty, t.isEmpty { queue.append(it); try? await Task.sleep(nanoseconds: 30_000_000_000); continue }   // retry later, slowly
            let entry: [String: Any] = ["rz": f["url"] as? String ?? "", "tor": t.count, "k4": t.contains { ($0["quality"] as? Int ?? 0) >= 2160 }, "ua": ua,
                                        "at": Date().timeIntervalSince1970]
            var all = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))) as? [String: Any] ?? [:]
            all[id] = entry
            if let d = try? JSONSerialization.data(withJSONObject: all) { try? d.write(to: URL(fileURLWithPath: path), options: .atomic) }
            queued.remove(id); checked += 1
            try? await Task.sleep(nanoseconds: 10_000_000_000)
        }
    }

    /// "Оновити": fresh IMDb / Wikidata / festival lists, then every film the tabs can show is (re)checked.
    static func refreshAll() {
        guard !building else { return }
        building = true; built = Date()
        Task {
            _ = await run(["build"])
            let items = await run(["pool"]) as? [[String: Any]] ?? []
            building = false
            enqueue(items)
        }
    }

    static func trailer(_ title: String, year: Int, tv: Bool) async -> Any {
        guard !title.isEmpty, let y = Caster.tool("yt-dlp") else { return ["error": "Немає трейлера"] }
        let q = "ytsearch1:\(title) \(year > 0 ? String(year) : "") official trailer"
        let id = await Task.detached { () -> String in
            let r = Caster.run(y, ["--no-warnings", "--get-id", "--no-playlist", q])
            return String(decoding: r.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").first ?? ""
        }.value
        guard id.count == 11 else { return ["error": "Трейлер не знайшовся"] }
        let url = "https://www.youtube.com/watch?v=\(id)"
        if tv { await MainActor.run { TV.shared.open(url) } }
        return ["url": url, "id": id]
    }
}


/// The torrent core host plays, on the phone itself (owner): ffmpeg makes HLS (fMP4) from the engine's stream at the TV's
/// second. Light files keep their video as is; heavy ones (REMUX) shrink to 1080p HEVC on the GPU. Sound -> AAC stereo.
@MainActor
enum PhoneWatch {
    nonisolated static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/tinyTV/watch")
    private static var job: Process?
    /// The last source, for 1:1 seeking (restart at any second of the film).
    private static var last: (src: String, probe: String, title: String, track: Int, audio: String?, shift: Double)?
    private static var lastDur = 0.0

    /// ffmpeg errors go to the same log as the TV's (~/Library/Logs/tinyTV-ffmpeg.log), marked "phone".
    private static func log() -> FileHandle {
        let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/tinyTV-ffmpeg.log")
        if !FileManager.default.fileExists(atPath: u.path) { FileManager.default.createFile(atPath: u.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: u) else { return FileHandle.nullDevice }
        h.seekToEndOfFile(); h.write(Data("--- phone \(Date())\n".utf8)); return h
    }

    static func seek(_ at: Double) async -> Any {
        guard let l = last else { return ["error": "Немає потоку"] }
        return await start(src: l.src, probeURL: l.probe, from: max(0, at - l.shift), title: l.title, track: l.track, audio: l.audio, shift: l.shift)
    }

    /// Whatever the TV plays (torrent, file, HDRezka, YouTube), from the TV's second; the TV keeps playing.
    static func start() async -> Any {
        let c = Caster.shared, inputs = c.watchInputs
        guard !c.title.isEmpty, let src = inputs.first else { return ["error": "Зараз на ТВ немає відео"] }
        if c.duration > 0 { lastDur = c.duration }
        // The TV re-encodes (4K VP9 YouTube, heavy files): copy its output, never a second decode next to it.
        if let l = c.watchLive {
            return await start(src: l.path, probeURL: l.path, from: max(0, c.displayPosition - 2 - l.offset), title: c.title, track: 0, shift: l.offset)
        }
        return await start(src: src, probeURL: src == Caster.engineStream ? "http://127.0.0.1:8890/probe" : src, from: max(0, c.displayPosition - 2),
                           title: c.title, track: inputs.count > 1 ? 0 : c.track, audio: inputs.count > 1 ? inputs[1] : nil)
    }

    /// A torrent from the Downloads list: the engine makes it the active one, unless the TV plays another torrent.
    static func torrent(_ magnet: String, hash: String, from: Double) async -> Any {
        let base = URL(string: "http://127.0.0.1:8890")!
        func state() async -> [String: Any] {
            guard let (d, _) = try? await URLSession.shared.data(from: base.appendingPathComponent("state")) else { return [:] }
            return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
        }
        let active = { (s: [String: Any]) in (s["magnet"] as? String ?? "").lowercased().contains("btih:" + hash) }
        var s = await state()
        if !active(s) {
            if Caster.shared.watchInputs.first == Caster.engineStream { return ["error": "На ТВ зараз інший торент"] }
            // The engine deletes the previous active torrent's files unless it is kept in the background: keep it.
            if let a = (await Downloads.list()?["torrents"] as? [[String: Any]])?.first(where: { $0["active"] as? Bool == true }),
               let h = a["hash"] as? String, a["background"] as? Bool != true {
                var k = URLRequest(url: base.appendingPathComponent("background")); k.url = URL(string: "http://127.0.0.1:8890/background?hash=\(h)&on=1")
                k.httpMethod = "POST"; _ = try? await URLSession.shared.data(for: k)
            }
            var r = URLRequest(url: base.appendingPathComponent("add")); r.httpMethod = "POST"; r.httpBody = Data(magnet.utf8)
            guard let (_, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else {
                return ["error": "Рушій торентів не відповідає"] }
            for _ in 0..<120 {   // up to 1 min for the file name and the first pieces
                s = await state()
                if active(s), !(s["fileName"] as? String ?? "").isEmpty, ((s["downloadedBytes"] as? NSNumber)?.doubleValue ?? 0) > 8e6 { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        let name = s["fileName"] as? String ?? "Торент"
        var r = await start(src: Caster.engineStream, probeURL: "http://127.0.0.1:8890/probe", from: from,
                            title: Library.pretty((name as NSString).deletingPathExtension), track: 0)
        if var d = r as? [String: Any] { d["hash"] = hash; r = d }
        return r
    }

    /// A file from the Media tab on the phone (or any device in the tailnet: the URL plays in VLC / Safari / AirPlay).
    static func file(_ path: String, from: Double) async -> Any {
        var r = await start(src: path, probeURL: path, from: from, title: Library.pretty(((path as NSString).lastPathComponent as NSString).deletingPathExtension), track: 0)
        if var d = r as? [String: Any] { d["path"] = path; r = d }
        return r
    }

    static func start(src: String, probeURL: String, from: Double, title: String, track: Int, audio: String? = nil, shift: Double = 0) async -> Any {
        guard let ff = Caster.tool("ffmpeg"), let probe = Caster.tool("ffprobe") else { return ["error": "Немає ffmpeg"] }
        job?.terminate(); job = nil
        try? FileManager.default.removeItem(at: dir)
        last = (src, probeURL, title, track, audio, shift)
        // A download still running (yt-dlp dl-*.mp4): seeking inside a growing fragmented MP4 ends early even with
        // -follow (5.7 s of 391, measured 2026-10-22), so wait until the files stop growing (1080p: ~12 s), at most 150 s.
        let files = ([src] + (audio.map { [$0] } ?? [])).filter { $0.hasPrefix("/") && !$0.hasSuffix(".ts") }
        let sizes = { files.map { (try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? Int) ?? 0 } }
        let fresh = files.contains { ((try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date) ?? .distantPast).timeIntervalSinceNow > -5 }
        var prev = sizes(), still = fresh ? 0 : 3
        for _ in 0..<150 where still < 3 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let now = sizes(); still = now == prev ? still + 1 : 0; prev = now
        }
        let id = String(UUID().uuidString.prefix(8)).lowercased().filter { $0.isLetter || $0.isNumber }
        let out = dir.appendingPathComponent(id)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let pr = await Task.detached { Caster.run(probe, ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=codec_name:format=size,duration",
                                                          "-of", "json", probeURL]) }.value
        let j = (try? JSONSerialization.jsonObject(with: pr.out)) as? [String: Any] ?? [:]
        let codec = ((j["streams"] as? [[String: Any]])?.first?["codec_name"] as? String) ?? "hevc"
        let f = j["format"] as? [String: Any] ?? [:]
        let size = Double(f["size"] as? String ?? "") ?? 0, dur = Double(f["duration"] as? String ?? "") ?? 0
        // > ~20 Mbit/s is too much for a phone; the TV's own re-encode is copied as is (it is already HEVC).
        let heavy = Caster.shared.watchLive?.path != src && (dur > 0 ? size / dur > 2_500_000 : size > 20e9)
        var args = ["-hide_banner", "-loglevel", "error", "-y"]
        if heavy { args += ["-hwaccel", "videotoolbox", "-hwaccel_output_format", "videotoolbox_vld"] }
        // A local input may still be growing (yt-dlp download, the TV's live TS): wait at its end, stop after 20 s
        // without new data. Without it ffmpeg hit "partial file" and gave 3 s of HLS (measured 2026-10-22).
        let grow = { (u: String) -> [String] in u.hasPrefix("http") ? ["-reconnect", "1"] : ["-follow", "1", "-rw_timeout", "20000000"] }
        if from > 1 { args += ["-ss", String(Int(from))] }
        args += grow(src) + ["-i", src]
        // Separate audio (YouTube video + audio): the same second from the second input.
        if let audio { args += (from > 1 ? ["-ss", String(Int(from))] : []) + grow(audio) + ["-i", audio] }
        args += ["-map", "0:v:0", "-map", audio == nil ? "0:a:\(track)?" : "1:a:0"]
        if heavy { args += ["-vf", "scale_vt=w=1920:h=1080", "-c:v", "hevc_videotoolbox", "-b:v", "10M", "-maxrate", "15M", "-tag:v", "hvc1"] }
        else { args += ["-c:v", "copy"] + (codec == "hevc" ? ["-tag:v", "hvc1"] : []) }
        args += ["-c:a", "aac", "-ac", "2", "-b:a", "192k", "-f", "hls", "-hls_time", "4", "-hls_list_size", "0", "-hls_playlist_type", "event",
                 "-hls_segment_type", "fmp4", "-hls_fmp4_init_filename", "init.mp4",
                 "-hls_segment_filename", out.appendingPathComponent("seg%05d.m4s").path, out.appendingPathComponent("index.m3u8").path]
        let p = Process(); p.executableURL = URL(fileURLWithPath: ff); p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = Self.log()
        do { try p.run() } catch { return ["error": "Не вийшло запустити ffmpeg"] }
        job = p
        // Ready once the playlist lists two segments (the phone can start and keep up).
        let list = out.appendingPathComponent("index.m3u8")
        for _ in 0..<60 {
            if let t = try? String(contentsOf: list, encoding: .utf8), t.components(separatedBy: "#EXTINF").count > 2 {
                // Also on the home network (media server :8892) for screens without Tailscale.
                let lan = TV.macIP().map { "http://\($0):\(MediaServer.port.rawValue)/watch/\(id)/index.m3u8" } ?? ""
                if dur > 0 { lastDur = dur }
                return ["url": "/watch/\(id)/index.m3u8", "lan": lan, "from": from + shift, "title": title, "dur": dur > 0 && shift == 0 ? dur : lastDur]
            }
            if !p.isRunning { return ["error": "ffmpeg зупинився"] }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return ["error": "Потік для телефона не встиг підготуватись"]
    }
}


/// Media tab: every video on the core host's disks (external SSD, HDD, home folder), not only what the torrent engine
/// fetched. Owner: torrent downloads stay apart from the own library. One background scan, at most every 10 min.
enum Library {
    static let exts: Set<String> = ["mkv", "mp4", "m4v", "avi", "mov", "ts", "m2ts", "webm", "wmv", "mpg", "mpeg", "flv", "vob"]
    static let skip: Set<String> = ["node_modules", "Library", "Applications", "System", ".Trashes", ".Spotlight-V100", ".fseventsd"]
    static var torrentRoots: [String] { ["/Volumes/External/Torrent", NSHomeDirectory() + "/Downloads/Torrent"] }
    /// Mounted disks (not the system one) plus the home folder.
    static var roots: [(name: String, path: String)] {
        let vols = ((try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? [])
            .filter { !$0.hasPrefix(".") && $0 != "Macintosh HD" && !$0.hasPrefix("com.apple") }
            .map { (name: $0, path: "/Volumes/" + $0) }
        // Not the whole home folder: Desktop / Documents are privacy-protected and the scan waits on a prompt
        // (measured 2026-10-21: stuck at 0.8 % CPU on /Users/user).
        return vols + [(name: "Фільми", path: NSHomeDirectory() + "/Movies"), (name: "Завантаження", path: NSHomeDirectory() + "/Downloads")]
    }
    nonisolated(unsafe) private static var files: [[String: Any]] = []
    nonisolated(unsafe) private static var scannedAt = Date.distantPast
    nonisolated(unsafe) private static var scanning = false
    private static let lock = NSLock()

    static func allowed(_ p: String) -> Bool {
        guard p.hasPrefix("/"), !p.contains("/../"), exts.contains((p as NSString).pathExtension.lowercased()),
              roots.contains(where: { p.hasPrefix($0.path + "/") }) else { return false }
        return FileManager.default.isReadableFile(atPath: p)
    }

    static func rescan() {
        lock.lock(); if scanning { lock.unlock(); return }; scanning = true; lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            var out: [[String: Any]] = []
            let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
            for r in roots {
                guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: r.path), includingPropertiesForKeys: keys,
                                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                for case let u as URL in e {
                    if skip.contains(u.lastPathComponent) || e.level > 8 { e.skipDescendants(); continue }
                    guard exts.contains(u.pathExtension.lowercased()), let v = try? u.resourceValues(forKeys: Set(keys)),
                          let size = v.fileSize, size > 20_000_000 else { continue }
                    let p = u.path
                    out.append(["path": p, "name": pretty(u.deletingPathExtension().lastPathComponent), "base": u.deletingPathExtension().lastPathComponent,
                                "file": u.lastPathComponent, "folder": u.deletingLastPathComponent().lastPathComponent,
                                "disk": r.name, "mb": size / 1_000_000, "at": (v.contentModificationDate ?? .distantPast).timeIntervalSince1970,
                                "torrent": torrentRoots.contains { p.hasPrefix($0 + "/") },
                                // A film: big file or a film container; small .mov / .mp4 are clips and renders.
                                // .mov / .webm are renders and clips (measured: 9 Yope ProRes renders on External); they stay
                                // in search and folders, not in the films list.
                                "film": ["mkv", "avi", "m2ts", "vob", "wmv"].contains(u.pathExtension.lowercased())
                                    || (["mp4", "m4v", "ts", "mpg", "mpeg"].contains(u.pathExtension.lowercased()) && size > 600_000_000)])
                }
            }
            lock.lock(); files = out; scannedAt = Date(); scanning = false; lock.unlock()
        }
    }

    /// "The.Matrix.1999.1080p.BluRay" -> "The Matrix 1999".
    static func pretty(_ n: String) -> String {
        var s = n.replacingOccurrences(of: "[._]", with: " ", options: .regularExpression)
        if let r = s.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression) { s = String(s[..<r.upperBound]) }
        else if let r = s.range(of: #"\b(2160p|1080p|720p|480p|BDRip|WEB|HDRip|BluRay|x264|x265|HEVC)\b"#, options: [.regularExpression, .caseInsensitive]) {
            s = String(s[..<r.lowerBound]) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Catalogue cards for file names (discover.py match: name + year -> IMDb -> poster, Ukrainian title, rating).
    /// Known names answer at once; new ones are matched in the background and the page asks again.
    nonisolated(unsafe) private static var meta: [String: [String: Any]] = [:]
    nonisolated(unsafe) private static var asked = Set<String>()
    nonisolated(unsafe) private static var matching = false
    private static func cards(_ rows: [[String: Any]]) -> (rows: [[String: Any]], pending: Bool) {
        let names = rows.compactMap { $0["base"] as? String }
        lock.lock()
        let todo = names.filter { !asked.contains($0) }
        let start = !todo.isEmpty && !matching
        if start { matching = true; todo.forEach { asked.insert($0) } }
        let m = meta, busy = matching; lock.unlock()
        if start {
            Task.detached {
                let f = FileManager.default.temporaryDirectory.appendingPathComponent("tinytv-match.json")
                try? JSONSerialization.data(withJSONObject: todo).write(to: f)
                let r = await Discover.run(["match", f.path]) as? [String: [String: Any]] ?? [:]
                lock.lock(); r.forEach { meta[$0.key] = $0.value }; matching = false; lock.unlock()
            }
        }
        return (rows.map { var x = $0; if let c = m[x["base"] as? String ?? ""] { x["card"] = c }; return x }, busy || start)
    }

    /// {q: search}, {path: folder to browse}; default = disks, torrent downloads and the newest films.
    static func list(_ b: [String: Any], positions: [String: [String: Any]]) async -> [String: Any] {
        lock.lock(); let stale = Date().timeIntervalSince(scannedAt) > 600, fresh = scannedAt != .distantPast; lock.unlock()
        if stale { rescan() }
        if !fresh { for _ in 0..<40 { try? await Task.sleep(nanoseconds: 500_000_000); lock.lock(); let s = scanning; lock.unlock(); if !s { break } } }
        lock.lock(); var all = files; let busy = scanning; lock.unlock()
        // Owner 2026-10-24: a file still downloading shows how much of it is in ("63 %"), from keeper.py.
        let prog = (try? Data(contentsOf: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/tinyTV-mix/progress.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Double] } ?? [:]
        all = all.map { var f = $0; if let t = positions["file:" + ($0["path"] as? String ?? "")], let p = t["pos"] as? Double, let d = t["dur"] as? Double, d > 0 {
            f["pos"] = p; f["dur"] = d }
            let path = $0["path"] as? String ?? ""
            if let pct = prog.first(where: { path == $0.key || path.hasPrefix($0.key + "/") })?.value { f["pct"] = pct }
            return f }
        func newest(_ l: [[String: Any]]) -> [[String: Any]] { l.sorted { ($0["at"] as? Double ?? 0) > ($1["at"] as? Double ?? 0) } }
        if let q = (b["q"] as? String)?.lowercased().trimmingCharacters(in: .whitespaces), !q.isEmpty {
            let words = q.split(separator: " ").map(String.init)
            let hit = all.filter { f in let h = ((f["file"] as? String ?? "") + " " + (f["folder"] as? String ?? "")).lowercased()
                .replacingOccurrences(of: "[._]", with: " ", options: .regularExpression); return words.allSatisfy { h.contains($0) } }
            let c = cards(Array(newest(hit).prefix(100)))
            return ["items": c.rows, "pending": c.pending, "scanning": busy]
        }
        if let p = b["path"] as? String, roots.contains(where: { p == $0.path || p.hasPrefix($0.path + "/") }), !p.contains("/../") {
            let dirs = ((try? FileManager.default.contentsOfDirectory(atPath: p)) ?? []).filter { n in
                var d: ObjCBool = false
                return !n.hasPrefix(".") && !skip.contains(n) && FileManager.default.fileExists(atPath: p + "/" + n, isDirectory: &d) && d.boolValue
                    && all.contains { ($0["path"] as? String ?? "").hasPrefix(p + "/" + n + "/") }   // only folders that hold video
            }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { n -> [String: Any] in let pre = p + "/" + n + "/"
                let inside = all.filter { ($0["path"] as? String ?? "").hasPrefix(pre) }
                return ["name": n, "n": inside.count, "mb": inside.reduce(0) { $0 + ($1["mb"] as? Int ?? 0) }] }
            let here = all.filter { (($0["path"] as? String ?? "") as NSString).deletingLastPathComponent == p }
            let c = cards(newest(here))
            return ["path": p, "dirs": dirs, "items": c.rows, "pending": c.pending, "scanning": busy]
        }
        let disks = roots.map { r -> [String: Any] in
            let n = all.filter { ($0["disk"] as? String) == r.name && $0["film"] as? Bool == true }.count
            return ["name": r.name, "path": r.path, "films": n] }
        let films = cards(Array(newest(all.filter { $0["film"] as? Bool == true && $0["torrent"] as? Bool != true }).prefix(80)))
        return ["disks": disks, "films": films.rows, "pending": films.pending, "total": all.count, "scanning": busy]
    }
}


/// Screens paired by QR (owner 2026-10-22): any device on the home Wi-Fi opens /screen on the LAN media server,
/// keeps its id and plays what it is sent. The media server polls from its own queue: everything under the lock.
enum Screens {
    struct S: Codable { var id: String; var name: String }
    nonisolated(unsafe) private static var list: [S] = (try? JSONDecoder().decode([S].self, from: Data(contentsOf: file))) ?? []
    nonisolated(unsafe) private static var seen: [String: Double] = [:]
    nonisolated(unsafe) private static var pending: [String: [String: Any]] = [:]
    private static let lock = NSLock()
    private static var file: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/tinyTV/screens.json") }
    private static func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(list).write(to: file)
    }

    /// One poll from a screen page (every 2 s): a new page gets an id and a name; a known one gets its waiting command.
    static func poll(_ id: String?) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        if let id, let s = list.first(where: { $0.id == id }) {
            seen[id] = now
            return ["id": id, "name": s.name, "cmd": pending.removeValue(forKey: id) ?? [:]]
        }
        let s = S(id: String(UUID().uuidString.prefix(8)).lowercased(), name: "Екран \(list.count + 2)")
        list.append(s); seen[s.id] = now; save()
        return ["id": s.id, "name": s.name, "cmd": [:] as [String: Any]]
    }
    static func all() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        return list.map { ["id": $0.id, "name": $0.name, "online": now - (seen[$0.id] ?? 0) < 8] }
    }
    static func send(_ id: String, _ cmd: [String: Any]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard list.contains(where: { $0.id == id }) else { return false }
        pending[id] = cmd; return true
    }
    static func remove(_ id: String) { lock.lock(); list.removeAll { $0.id == id }; save(); lock.unlock() }
    static func rename(_ id: String, _ name: String) {
        lock.lock(); if let i = list.firstIndex(where: { $0.id == id }) { list[i].name = String(name.prefix(30)); save() }; lock.unlock()
    }
}


/// A source a device can play by itself (data plane of "Грати тут"): YouTube's own HLS manifest (adaptive, like the
/// YouTube app; tied to the home IP), or a direct mp4 / m3u8 link as is. Nil: only core host can serve it.
@MainActor
enum Direct {
    nonisolated(unsafe) private static var cache: [String: (url: String, at: Date)] = [:]
    nonisolated(unsafe) static var titles: [String: String] = [:]   // page -> the video's own title
    /// For the core host HLS fallback: one H.264 variant up to 1080p (ffmpeg on the master took the first one, 240p).
    nonisolated(unsafe) static var variants: [String: String] = [:]
    static func resolve(_ page: String) async -> String? {
        guard let u = URL(string: page) else { return nil }
        if ["mp4", "m4v", "mov", "m3u8"].contains(u.pathExtension.lowercased()) { return page }
        guard (u.host ?? "").contains("youtu") || (u.host ?? "").contains("youtube") else { return nil }
        if let c = cache[page], c.at.timeIntervalSinceNow > -3600 { return c.url }
        guard let y = Caster.tool("yt-dlp") else { return nil }
        // On a GCD thread, not the Swift concurrency pool: blocked waits there starved every kino/* request (2026-10-22).
        let r = await withCheckedContinuation { (k: CheckedContinuation<(out: Data, err: Data), Never>) in
            DispatchQueue.global().async { k.resume(returning: Caster.run(y, ["--no-js-runtimes", "--js-runtimes", "node:" + NSHomeDirectory() + "/tinyTV/tools/bin/node", "--socket-timeout", "10", "--no-playlist", "--no-warnings", "-J", page])) } }
        let j = (try? JSONSerialization.jsonObject(with: r.out)) as? [String: Any]
        let m = (j?["formats"] as? [[String: Any]])?.first { ($0["protocol"] as? String ?? "").contains("m3u8") && $0["manifest_url"] != nil }?["manifest_url"] as? String
        if let m { cache[page] = (m, Date()) }
        if let t = j?["title"] as? String { titles[page] = t }
        let hls = (j?["formats"] as? [[String: Any]] ?? []).filter { ($0["protocol"] as? String ?? "").contains("m3u8")
            && ($0["vcodec"] as? String ?? "").hasPrefix("avc1") && ($0["height"] as? Int ?? 0) <= 1080 }
        if let v = hls.max(by: { ($0["height"] as? Int ?? 0) < ($1["height"] as? Int ?? 0) })?["url"] as? String { variants[page] = v }
        return m
    }
}
