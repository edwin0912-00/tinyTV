// "Кіно": bookmarks, history and "continue where you stopped", Discover (IMDb + Wikidata lists), background
// torrent downloads. Runs on the core so the phone and the Mac share one store.
// Catalog sources are optional providers (providers/): providers/hdrezka adds title pages, voiceovers and
// episodes through extension Kino; providers/trackers adds torrent search. Neither is compiled in by default.
import AppKit
import WebKit

@MainActor
final class Kino: NSObject {
    static let shared = Kino()

    var web: WKWebView?
    var ready = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    /// Catalog hits per IMDb id (filled by a catalog provider).
    var found: [String: [String: Any]] = [:]
    let store = KinoStore()

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
            guard let it = b["item"] as? [String: Any], let l = b["list"] as? String, ["fav", "watch"].contains(l) else { return ["error": "bad list"] }
            store.mark(l, it, on: b["on"] as? Bool ?? true); return store.home()
        case "kino/downloads", "kino/download/bg", "kino/download/remove":
            return await Downloads.handle(cmd, b, positions: torrentPositions)
        case "kino/phone/torrent": return await PhoneWatch.start()
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
            let f = b["film"] as? [String: Any]
            var filmPos: Double?
            if let f, let fid = f["id"] as? String {
                filmPos = store.episodePosition(fid, season: f["season"] as? Int, episode: f["episode"] as? Int)
                if store.progress(fid) == nil { store.recordStart(f) }
            }
            let from = b["from"] as? Double ?? filmPos ?? torrentResume(m)
            let back = current.flatMap { cur -> [String: Any]? in Caster.shared.title.hasPrefix((cur["title"] as? String) ?? "\u{0}") ? cur : nil }
            film = f; filmSaved = Date.distantPast
            TV.shared.open(m)
            Caster.shared.startAt = from
            Caster.shared.fallback = back.map { cur in { [weak self] in
                guard let self else { return }
                var c = cur; c["from"] = max(Caster.shared.displayPosition, from)
                Task { _ = await self.replay(c) }
            } }
            return ["ok": true]
        case "kino/progress":
            if let id = b["id"] as? String { store.saveProgress(id, position: b["position"] as? Double ?? 0, duration: b["duration"] as? Double ?? 0) }
            return ["ok": true]
        default: return ["error": "unknown"]
        }
    }

    // MARK: Playback and progress

    /// What plays now from Kino, to save progress and to offer the next episode.
    var current: [String: Any]?
    var next: [String: Any]?
    var nextTimer: Task<Void, Never>?
    var watcher: Task<Void, Never>?

    /// A torrent that fails or starves falls back to the catalog stream it replaced (catalog providers only).
    func replay(_ item: [String: Any]) async -> Any {
#if PROVIDER_HDREZKA
        return await play(item)
#else
        return ["error": "No catalog provider"]
#endif
    }

    func saveTorrent(_ h: String, position: Double, duration: Double, name: String) {
        store.saveTorrent(h, position: position, duration: duration, name: name)
        // The film's own position too: HDRezka's "Продовжити" and the next torrent start from here.
        if let f = film, let id = f["id"] as? String { store.saveProgress(id, position: position, duration: duration) }
    }
    /// The film a playing torrent belongs to (set when it was started from a film card).
    var film: [String: Any]?
    var filmSaved = Date.distantPast
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
        if let c = current, Caster.shared.title.hasPrefix((c["title"] as? String) ?? "\u{0}") {
            for key in ["id", "url", "title", "poster", "season", "episode", "quality", "qualities", "translator", "translatorName"] { s[key] = c[key] }
        } else if let f = film, !Caster.shared.title.isEmpty, !Caster.shared.torrent.isEmpty {
            // A torrent of a film card: the players show the film, not the file name.
            for key in ["id", "url", "title", "poster", "season", "episode"] { s[key] = f[key] }
            s["source"] = "torrent"
        }
        if let n = next { s["next"] = n }
        if !s.isEmpty { s["hasPrev"] = neighbour(-1) != nil; s["hasNext"] = neighbour(1) != nil }
        return s
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

    func home() -> [String: Any] { ["bookmarks": bookmarks, "history": history, "fav": data["fav"] ?? [], "watch": data["watch"] ?? []] }

    var taste: [String: Any] { data["taste"] as? [String: Any] ?? [:] }
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
        if on { l.insert(it.filter { ["imdb", "title", "orig", "ru", "year", "poster", "dirs", "imdbR", "rt", "badges"].contains($0.key) }, at: 0) }
        data[list] = l; save()
    }
    func isBookmarked(_ id: String) -> Bool { bookmarks.contains { ($0["id"] as? String) == id } }
    func progress(_ id: String) -> [String: Any]? { history.first { ($0["id"] as? String) == id } }

    func bookmark(_ b: [String: Any], on: Bool) {
        guard let id = b["id"] as? String else { return }
        bookmarks.removeAll { ($0["id"] as? String) == id }
        if on { bookmarks.insert(card(b), at: 0) }
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




/// Torrent downloads on the core host (TV Cast engine, ~/Downloads/Torrent): the list like qBittorrent, "На фоні", delete.
/// hash "active" means the torrent that plays on the TV now.
enum Downloads {
    private static let base = "http://127.0.0.1:8890"

    private static func list() async -> [String: Any]? {
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
        let path = cmd == "kino/download/bg" ? "/background?hash=\(hash)&on=\((b["on"] as? Bool ?? true) ? 1 : 0)" : "/remove?hash=\(hash)&files=1"
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
    /// for the Mac and the core host alike). So: one HDRezka search per 10 s, and a 30 min pause when it starts refusing.
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
            let t = await Providers.availability(title: (it["ru"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (it["title"] as? String ?? ""),
                                               original: it["orig"] as? String ?? "")
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


/// The torrent the core host plays, on the phone itself (owner): ffmpeg makes HLS (fMP4) from the engine's stream at the TV's
/// second. Light files keep their video as is; heavy ones (REMUX) shrink to 1080p HEVC on the GPU. Sound -> AAC stereo.
@MainActor
enum PhoneWatch {
    nonisolated static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/tinyTV/watch")
    private static var job: Process?

    static func start() async -> Any {
        guard let ff = Caster.tool("ffmpeg"), let probe = Caster.tool("ffprobe") else { return ["error": "Немає ffmpeg"] }
        let c = Caster.shared
        guard !c.title.isEmpty, c.torrent["rate"] != nil else { return ["error": "Зараз на ТВ не торент"] }
        let src = Caster.engineStream, from = max(0, c.displayPosition - 2)
        job?.terminate(); job = nil
        try? FileManager.default.removeItem(at: dir)
        let id = String(UUID().uuidString.prefix(8)).lowercased().filter { $0.isLetter || $0.isNumber }
        let out = dir.appendingPathComponent(id)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let pr = await Task.detached { Caster.run(probe, ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=codec_name:format=size,duration",
                                                          "-of", "json", "http://127.0.0.1:8890/probe"]) }.value
        let j = (try? JSONSerialization.jsonObject(with: pr.out)) as? [String: Any] ?? [:]
        let codec = ((j["streams"] as? [[String: Any]])?.first?["codec_name"] as? String) ?? "hevc"
        let f = j["format"] as? [String: Any] ?? [:]
        let size = Double(f["size"] as? String ?? "") ?? 0, dur = Double(f["duration"] as? String ?? "") ?? 0
        let heavy = dur > 0 ? size / dur > 2_500_000 : size > 20e9   // > ~20 Mbit/s is too much for a phone
        var args = ["-hide_banner", "-loglevel", "error", "-y"]
        if heavy { args += ["-hwaccel", "videotoolbox", "-hwaccel_output_format", "videotoolbox_vld"] }
        if from > 1 { args += ["-ss", String(Int(from))] }
        args += ["-reconnect", "1", "-i", src, "-map", "0:v:0", "-map", "0:a:\(c.track)?"]
        if heavy { args += ["-vf", "scale_vt=w=1920:h=1080", "-c:v", "hevc_videotoolbox", "-b:v", "10M", "-maxrate", "15M", "-tag:v", "hvc1"] }
        else { args += ["-c:v", "copy"] + (codec == "hevc" ? ["-tag:v", "hvc1"] : []) }
        args += ["-c:a", "aac", "-ac", "2", "-b:a", "192k", "-f", "hls", "-hls_time", "4", "-hls_list_size", "0", "-hls_playlist_type", "event",
                 "-hls_segment_type", "fmp4", "-hls_fmp4_init_filename", "init.mp4",
                 "-hls_segment_filename", out.appendingPathComponent("seg%05d.m4s").path, out.appendingPathComponent("index.m3u8").path]
        let p = Process(); p.executableURL = URL(fileURLWithPath: ff); p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return ["error": "Не вийшло запустити ffmpeg"] }
        job = p
        // Ready once the playlist lists two segments (the phone can start and keep up).
        let list = out.appendingPathComponent("index.m3u8")
        for _ in 0..<60 {
            if let t = try? String(contentsOf: list, encoding: .utf8), t.components(separatedBy: "#EXTINF").count > 2 {
                return ["url": "/watch/\(id)/index.m3u8", "from": from, "title": c.title]
            }
            if !p.isRunning { return ["error": "ffmpeg зупинився"] }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return ["error": "Потік для телефона не встиг підготуватись"]
    }
}
