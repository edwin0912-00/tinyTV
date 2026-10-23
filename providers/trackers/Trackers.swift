// Optional provider: torrent search across public indexes and, optionally, your own rutracker login in your own Chrome.
// OFF by default. Built only with PROVIDERS="trackers" (scripts/build.sh adds -D PROVIDER_TRACKERS). See providers/README.md.
// You are responsible for what you search and download and for the law where you live.
import AppKit

@MainActor
enum Trackers {
    static func register() {
        Providers.torrentSearch = { t, o in
            async let rt = RuTracker.search(title: t, original: o)
            async let jr = Trackers.jacred(title: t, original: o)
            async let tpb = MoreTorrents.apibay(original: o)
            async let kn = MoreTorrents.knaben(original: o)
            let jac = await jr as? [[String: Any]] ?? []
            return TorrentRank.merge([await rt ?? [], jac, await tpb, await kn])
        }
        Providers.magnetLookup = { await RuTracker.magnet(topic: $0) }
        Providers.anySearch = { await MoreTorrents.any($0) }
        Providers.availabilityIndex = { await Trackers.jacred(title: $0, original: $1) }
        Providers.availabilityFallback = { await MoreTorrents.apibay(original: $0) }
    }

    /// Magnets for a title from the public jac.red index (rutracker, kinozal, rutor… without a tracker login).
    /// Only releases whose name or original name matches the title exactly; best quality, then most seeders.
    static func jacred(title: String, original: String) async -> Any {
        func n(_ t: String) -> String { String(t.lowercased().replacingOccurrences(of: "ё", with: "е").filter { $0.isLetter || $0.isNumber }) }
        let want = n(title), wantOrig = n(original)
        guard !want.isEmpty || !wantOrig.isEmpty else { return [] as [Any] }
        var c = URLComponents(string: "https://jac.red/api/v1.0/torrents")!
        c.queryItems = [URLQueryItem(name: "search", value: original.isEmpty ? title : original)]
        var r = URLRequest(url: c.url!, timeoutInterval: 25)
        r.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        guard let (d, _) = try? await URLSession.shared.data(for: r),
              let list = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return ["error": "Індекс торентів недоступний"] }
        var seen = Set<String>()
        // Same release on several trackers: keep the copy with the most seeders.
        let hits = list.sorted { ($0["sid"] as? Int ?? 0) > ($1["sid"] as? Int ?? 0) }.filter { t in
            (!want.isEmpty && n(t["name"] as? String ?? "") == want) || (!wantOrig.isEmpty && n(t["originalname"] as? String ?? "").hasPrefix(wantOrig))
        }.compactMap { t -> [String: Any]? in
            guard let m = t["magnet"] as? String, let h = m.range(of: "btih:") else { return nil }
            let hash = m[h.upperBound...].prefix(40).uppercased()
            guard seen.insert(String(hash)).inserted else { return nil }
            return ["title": t["title"] ?? "", "quality": t["quality"] as? Int ?? 0, "hdr": (t["videotype"] as? String ?? "").contains("hdr"),
                    "size": t["sizeName"] ?? "", "seeds": t["sid"] as? Int ?? 0, "peers": t["pir"] as? Int ?? 0, "tracker": t["tracker"] ?? "",
                    "seasons": t["seasons"] ?? [], "voices": t["voices"] ?? [], "magnet": m, "hash": String(hash), "url": t["url"] ?? ""]
        }
        return hits.sorted { a, b in
            let qa = a["quality"] as? Int ?? 0, qb = b["quality"] as? Int ?? 0
            return qa != qb ? qa > qb : (a["seeds"] as? Int ?? 0) > (b["seeds"] as? Int ?? 0)
        }.prefix(80).map { $0 }
    }
}


/// rutracker through the owner's own logged-in Chrome on core host (a Chrome with remote debugging on 127.0.0.1).
/// Searches run as fetch() inside an open rutracker.org tab, so the site sees that session; no cookie or password
/// leaves the browser. Nothing here when that Chrome or its rutracker tab is not open.
enum RuTracker {
    private static let profile = TV.config["rutracker_chrome_profile"] ?? (NSHomeDirectory() + "/Library/Application Support/tinyTV/chrome-rutracker")
    private static let defaultPort = 18850

    /// DevTools port of the Chrome that runs the owner's profile, or nil when that Chrome is not running.
    private static func port() -> Int? {
        let txt = String(decoding: Caster.run("/bin/ps", ["-axo", "command"]).out, as: UTF8.self)
        for line in txt.split(separator: "\n") where line.contains("Google Chrome") && line.contains(profile) {
            if let r = line.range(of: "--remote-debugging-port="), let p = Int(line[r.upperBound...].prefix { $0.isNumber }) { return p }
        }
        return nil
    }

    /// Owner: must not depend on an open tab. Starts that Chrome with the same profile when it is closed,
    /// opens a rutracker tab when there is none, and returns the tab's DevTools socket.
    private static func tab() async -> URL? {
        var p = port()
        if p == nil {
            let app = [TV.config["chrome_app"] ?? "/Applications/Google Chrome.app", "/Applications/Google Chrome.app"]
                .first { FileManager.default.fileExists(atPath: $0) }
            guard let app else { return nil }
            _ = Caster.run("/usr/bin/open", ["-na", app, "--args", "--user-data-dir=\(profile)", "--remote-debugging-port=\(defaultPort)",
                                             "--remote-allow-origins=*", "--no-first-run", "--no-default-browser-check"])
            for _ in 0..<30 where p == nil { try? await Task.sleep(nanoseconds: 500_000_000); p = port() }
        }
        guard let p else { return nil }
        let base = "http://127.0.0.1:\(p)"
        func find() async -> URL? {
            guard let u = URL(string: base + "/json/list"), let (d, _) = try? await URLSession.shared.data(from: u),
                  let tabs = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return nil }
            return tabs.first { ($0["type"] as? String) == "page" && (($0["url"] as? String) ?? "").hasPrefix("https://rutracker.org") }
                .flatMap { ($0["webSocketDebuggerUrl"] as? String).flatMap(URL.init(string:)) }
        }
        if let ws = await find() { return ws }
        var r = URLRequest(url: URL(string: base + "/json/new?https://rutracker.org/forum/index.php")!); r.httpMethod = "PUT"
        _ = try? await URLSession.shared.data(for: r)
        for _ in 0..<20 {   // Cloudflare's check passes on its own with the profile's clearance; give the page time.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if let ws = await find(), let ready = await run(ws, "document.readyState === 'complete' && !!document.querySelector('#logged-in-username, #login-form-full, form[action*=login]')") as? Bool, ready { return ws }
        }
        return await find()
    }

    /// Runs JS (an async IIFE returning JSON-able data) in the rutracker tab.
    static func eval(_ js: String) async -> Any? {
        guard let ws = await tab() else { return nil }
        return await run(ws, js)
    }

    private static func run(_ ws: URL, _ js: String) async -> Any? {
        let task = URLSession.shared.webSocketTask(with: ws)
        task.maximumMessageSize = 32 << 20
        task.resume(); defer { task.cancel(with: .goingAway, reason: nil) }
        let msg: [String: Any] = ["id": 1, "method": "Runtime.evaluate",
                                  "params": ["expression": js, "awaitPromise": true, "returnByValue": true]]
        guard let out = try? JSONSerialization.data(withJSONObject: msg) else { return nil }
        do {
            try await task.send(.string(String(decoding: out, as: UTF8.self)))
            for _ in 0..<50 {
                guard case .string(let s) = try await task.receive(),
                      let m = try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any], (m["id"] as? Int) == 1 else { continue }
                return ((m["result"] as? [String: Any])?["result"] as? [String: Any])?["value"]
            }
        } catch {}
        return nil
    }

    /// Video releases for the title: quality and HDR from the release name, seasons from "Сезон: 1-7".
    static func search(title: String, original: String) async -> [[String: Any]]? {
        let q = [title, original].filter { !$0.isEmpty }.joined(separator: " ")
        guard !q.isEmpty, let qd = try? JSONSerialization.data(withJSONObject: [q]) else { return nil }
        let js = """
        (async () => {
          const q = \(String(decoding: qd, as: UTF8.self))[0];
          const r = await fetch('/forum/tracker.php?o=10&s=2&nm=' + encodeURIComponent(q));
          const d = new DOMParser().parseFromString(new TextDecoder('windows-1251').decode(await r.arrayBuffer()), 'text/html');
          if (!d.querySelector('#logged-in-username')) return null;
          return [...d.querySelectorAll('tr.tCenter.hl-tr')].map(tr => { const a = tr.querySelector('a.tLink') || {};
            return {topic: (a.dataset || {}).topic_id || '', title: (a.textContent || '').trim(),
                    bytes: +((tr.querySelector('td.tor-size') || {}).dataset || {}).ts_text || 0,
                    seeds: +((tr.querySelector('b.seedmed') || {}).textContent || 0),
                    peers: +((tr.querySelector('.leechmed') || {}).textContent || 0)}; });
        })()
        """
        guard let rows = await eval(js) as? [[String: Any]] else { return nil }
        func n(_ t: String) -> String { String(t.lowercased().replacingOccurrences(of: "ё", with: "е").filter { $0.isLetter || $0.isNumber }) }
        let names = [title, original].map(n).filter { !$0.isEmpty }
        return rows.compactMap { r -> [String: Any]? in
            let t = r["title"] as? String ?? "", lt = t.lowercased()
            guard let topic = r["topic"] as? String, !topic.isEmpty,
                  names.contains(where: { n(t).hasPrefix($0) || n(t).contains($0) }),
                  !["soundtrack", "mp3", "flac", "аудиокниг", "ost"].contains(where: { lt.contains($0) }) else { return nil }
            let quality = lt.contains("2160") || lt.contains("4k") || lt.contains("uhd") ? 2160 : lt.contains("1080") ? 1080 : lt.contains("720") ? 720 : 480
            var seasons: [Int] = []
            if let s = t.range(of: #"Сезон[ыи]?:?\s*(\d+)(?:\s*-\s*(\d+))?"#, options: .regularExpression) {
                let nums = t[s].split { !$0.isNumber }.compactMap { Int($0) }
                if let a = nums.first { seasons = Array(a...(nums.count > 1 ? max(a, nums[1]) : a)) }
            }
            else if let s = t.range(of: #"(\d+)\s*сезон"#, options: [.regularExpression, .caseInsensitive]), let a = Int(t[s].prefix { $0.isNumber }) { seasons = [a] }
            let bytes = r["bytes"] as? Double ?? 0
            return ["title": t, "quality": quality, "hdr": lt.contains("hdr") || lt.contains("dolby vision"),
                    "size": bytes > 0 ? String(format: "%.2f GB", bytes / 1_073_741_824) : "", "seeds": r["seeds"] as? Int ?? 0, "peers": r["peers"] as? Int ?? 0,
                    "tracker": "rutracker", "seasons": seasons, "topic": topic]
        }.sorted { a, b in
            let qa = a["quality"] as? Int ?? 0, qb = b["quality"] as? Int ?? 0
            return qa != qb ? qa > qb : (a["seeds"] as? Int ?? 0) > (b["seeds"] as? Int ?? 0)
        }
    }

    /// The magnet link from the release page, taken only when the owner presses "Використати".
    static func magnet(topic: String) async -> String? {
        guard topic.allSatisfy(\.isNumber) else { return nil }
        let js = """
        (async () => { const r = await fetch('/forum/viewtopic.php?t=\(topic)');
          const d = new DOMParser().parseFromString(new TextDecoder('windows-1251').decode(await r.arrayBuffer()), 'text/html');
          const a = d.querySelector('a.magnet-link, a[href^="magnet:"]'); return a ? a.getAttribute('href') : null; })()
        """
        return await eval(js) as? String
    }
}


/// Releases from the English-language indexes, matched by the original title ("The Mentalist" -> The.Mentalist.S01…).
enum MoreTorrents {
    private static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/605.1.15"

    private static func get(_ r: URLRequest) async -> Any? {
        var r = r; r.timeoutInterval = 20; r.setValue(ua, forHTTPHeaderField: "User-Agent")
        guard let (d, _) = try? await URLSession.shared.data(for: r) else { return nil }
        return try? JSONSerialization.jsonObject(with: d)
    }
    private static func matches(_ name: String, _ original: String) -> Bool {
        let n = { (t: String) in String(t.lowercased().filter { $0.isLetter || $0.isNumber }) }
        return !original.isEmpty && n(name).hasPrefix(n(original))
    }

    /// Search tab: anything (music, series, software...), every index at once, no film-name filter.
    static func any(_ q: String) async -> [[String: Any]] {
        async let a = apibay(original: q, loose: true)
        async let k = knaben(original: q, loose: true)
        async let j = jacred(q)
        return TorrentRank.merge([await j, await a, await k])
    }

    static func jacred(_ q: String) async -> [[String: Any]] {
        guard var c = URLComponents(string: "https://jac.red/api/v1.0/torrents") else { return [] }
        c.queryItems = [URLQueryItem(name: "search", value: q)]
        let rows = await get(URLRequest(url: c.url!)) as? [[String: Any]] ?? []
        return rows.compactMap { t in
            guard let m = t["magnet"] as? String, let h = m.range(of: "btih:") else { return nil }
            var r = TorrentRank.row(title: t["title"] as? String ?? "", bytes: (t["size"] as? NSNumber)?.doubleValue ?? 0,
                                    seeds: t["sid"] as? Int ?? 0, peers: t["pir"] as? Int ?? 0, tracker: t["tracker"] as? String ?? "jacred",
                                    hash: String(m[h.upperBound...].prefix(40)), magnet: m)
            if let q = t["quality"] as? Int, q > 0 { r["quality"] = q }
            r["voices"] = t["voices"] ?? []; r["url"] = t["url"] ?? ""
            return r
        }
    }

    static func apibay(original: String, loose: Bool = false) async -> [[String: Any]] {
        guard !original.isEmpty, var c = URLComponents(string: "https://apibay.org/q.php") else { return [] }
        c.queryItems = [URLQueryItem(name: "q", value: original)]
        let rows = await get(URLRequest(url: c.url!)) as? [[String: Any]] ?? []
        return rows.compactMap { r in
            guard let name = r["name"] as? String, let h = r["info_hash"] as? String, h.count == 40, h != String(repeating: "0", count: 40),
                  loose || matches(name, original) else { return nil }
            let enc = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            return TorrentRank.row(title: name, bytes: Double(r["size"] as? String ?? "") ?? 0, seeds: Int(r["seeders"] as? String ?? "") ?? 0,
                                   peers: Int(r["leechers"] as? String ?? "") ?? 0, tracker: "thepiratebay", hash: h,
                                   magnet: "magnet:?xt=urn:btih:\(h)&dn=\(enc)&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce")
        }
    }

    static func knaben(original: String, loose: Bool = false) async -> [[String: Any]] {
        guard !original.isEmpty else { return [] }
        var r = URLRequest(url: URL(string: "https://api.knaben.org/v1")!); r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["search_type": "100%", "search_field": "title", "query": original, "size": 100,
                                                                  "order_by": "seeders", "order_direction": "desc", "hide_unsafe": true, "hide_xxx": true])
        let hits = (await get(r) as? [String: Any])?["hits"] as? [[String: Any]] ?? []
        return hits.compactMap { h in
            guard let name = h["title"] as? String, let hash = h["hash"] as? String, loose || matches(name, original) else { return nil }
            let magnet = h["magnetUrl"] as? String ?? "magnet:?xt=urn:btih:\(hash)"
            return TorrentRank.row(title: name, bytes: (h["bytes"] as? NSNumber)?.doubleValue ?? 0, seeds: (h["seeders"] as? NSNumber)?.intValue ?? 0,
                                   peers: (h["peers"] as? NSNumber)?.intValue ?? 0, tracker: (h["tracker"] as? String ?? "knaben").lowercased().replacingOccurrences(of: " ", with: ""),
                                   hash: hash, magnet: magnet)
        }
    }
}
