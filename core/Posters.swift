// Poster library (owner 2026-10-24: "треба, щоб все гарненько було"): every cover the pages show comes through the
// core, GET /poster?u=<original>&t=<title>&o=<original title>&y=<year>&i=<imdb id>. Found once, kept on core host' disk.
// Order: the cache, the original URL, IMDb by id, IMDb by title and year. Nothing found: 404, the page draws its plain card.
import Foundation
import CryptoKit

enum Posters {
    static let dir: URL = {
        let ssd = URL(fileURLWithPath: "/Volumes/External/tinyTV-cache")
        let base = FileManager.default.fileExists(atPath: ssd.path) ? ssd
            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/tinyTV")
        let d = base.appendingPathComponent("posters")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    /// IMDb is asked one title at a time, a second apart (a page of 40 cards must not burst).
    private static let gate = Gate()
    actor Gate {
        private var next = Date.distantPast
        /// The slot is taken before the sleep: ten callers get 0, 1, 2 … 9 s (they all passed at once before).
        func wait() async {
            let at = max(Date(), next); next = at.addingTimeInterval(1)
            let gap = at.timeIntervalSinceNow
            if gap > 0 { try? await Task.sleep(nanoseconds: UInt64(gap * 1e9)) }
        }
        private var running: [String: Task<Data?, Never>] = [:]
        /// One lookup per cover however many cards ask for it.
        func once(_ key: String, _ work: @escaping @Sendable () async -> Data?) -> Task<Data?, Never> {
            if let t = running[key] { return t }
            let t = Task { await work() }; running[key] = t
            Task { _ = await t.value; self.done(key) }
            return t
        }
        private func done(_ key: String) { running[key] = nil }
    }

    static func get(u: String, t: String, o: String, y: Int, i: String) async -> Data? {
        // One file per cover: by IMDb id, else by the original URL (a corrected URL is a new key), else by title and year.
        let key = i.hasPrefix("tt") ? i : u.hasPrefix("http") ? u : !t.isEmpty || !o.isEmpty ? "\(norm(o.isEmpty ? t : o))-\(y)" : ""
        guard !key.isEmpty else { return nil }
        let hex = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24)
        let file = dir.appendingPathComponent("\(hex).jpg"), miss = dir.appendingPathComponent("\(hex).none")
        if let d = try? Data(contentsOf: file) { return d }
        // A miss is remembered for a day: no lookups on every page load.
        if let a = (try? FileManager.default.attributesOfItem(atPath: miss.path))?[.modificationDate] as? Date,
           Date().timeIntervalSince(a) < 86400 { return nil }
        // The original link answers inline (one quick request). IMDb runs in the background, one title a second:
        // the page shows initials now and the cover on its retry (frontend review: 31 covers held Safari's 6
        // connections and a pause tap waited 10 s).
        if u.hasPrefix("https://"), let h = URL(string: u)?.host, !h.hasPrefix("192.168."), !h.hasPrefix("10."), !h.hasPrefix("127."), h != "localhost",
           let d = await image(u) {
            try? d.write(to: file, options: .atomic); return d
        }
        guard i.hasPrefix("tt") || !o.isEmpty || !t.isEmpty else { return nil }
        _ = await gate.once(String(hex)) {
            var found: Data? = nil
            if i.hasPrefix("tt") { found = await imdb(i, year: 0) }
            if found == nil, !o.isEmpty { found = await imdb(o, year: y) }
            if found == nil, !t.isEmpty, t != o { found = await imdb(t, year: y) }
            if let d = found { try? d.write(to: file, options: .atomic); try? FileManager.default.removeItem(at: miss) }
            else if !(await offline()) { FileManager.default.createFile(atPath: miss.path, contents: nil) }   // a network error is no miss
            return found
        }
        return nil
    }
    /// Whether IMDb is reachable at all (asked when a lookup found nothing: a network error is no miss).
    private static func offline() async -> Bool {
        var r = URLRequest(url: URL(string: "https://v3.sg.media-imdb.com/suggestion/x/a.json")!, timeoutInterval: 5); r.httpMethod = "HEAD"
        return (try? await URLSession.shared.data(for: r)) == nil
    }

    private static func norm(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "ё", with: "е").filter { $0.isLetter || $0.isNumber }
    }

    /// The bytes when the URL answers with an image (HDRezka covers want their own Referer).
    private static func image(_ u: String) async -> Data? {
        guard let url = URL(string: u) else { return nil }
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
#if PROVIDER_HDREZKA
        if u.contains("hdrezka") || u.contains("rezka") { r.setValue("https://rezka.ag/", forHTTPHeaderField: "Referer") }
#endif
        r.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        guard let (d, resp) = try? await URLSession.shared.data(for: r), let h = resp as? HTTPURLResponse, h.statusCode == 200,
              (h.value(forHTTPHeaderField: "Content-Type") ?? "").hasPrefix("image"), d.count > 2000 else { return nil }
        return d
    }

    /// IMDb's public search suggestions: an id gives its own entry; a title gives the best match of that year
    /// (±1, release years differ between countries), a film or series with a picture.
    private static func imdb(_ q: String, year: Int) async -> Data? {
        let s = q.lowercased().trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, let e = s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://v3.sg.media-imdb.com/suggestion/x/\(e).json") else { return nil }
        await gate.wait()
        guard let (d, _) = try? await URLSession.shared.data(from: url),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let list = j["d"] as? [[String: Any]] else { return nil }
        let hits = list.filter { (($0["i"] as? [String: Any])?["imageUrl"] as? String) != nil }
        let pick = q.hasPrefix("tt") ? hits.first { $0["id"] as? String == q }
            : hits.first { year > 0 && abs(($0["y"] as? Int ?? 0) - year) <= 1 && norm($0["l"] as? String ?? "") == norm(q) }
            ?? hits.first { year > 0 && abs(($0["y"] as? Int ?? 0) - year) <= 1 }
            ?? (year == 0 ? hits.first { norm($0["l"] as? String ?? "") == norm(q) } : nil)
        guard let img = (pick?["i"] as? [String: Any])?["imageUrl"] as? String else { return nil }
        // Full-size originals are several MB: ask Amazon's image server for a 400 px wide copy.
        return await image(img.replacingOccurrences(of: "._V1_.jpg", with: "._V1_SX400_.jpg"))
    }
}
