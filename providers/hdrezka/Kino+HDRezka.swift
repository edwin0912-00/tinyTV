// Optional provider: HDRezka catalog for "Кіно" (search, title pages, voiceovers, seasons, episodes, qualities).
// OFF by default. Built only with PROVIDERS="hdrezka" (build.sh adds -D PROVIDER_HDREZKA). See providers/README.md.
// The site answers plain HTTP clients with a bot check, so every request runs as fetch() inside a WebKit page
// already open on the site (same origin, its cookies). This provider never solves or bypasses bot checks:
// when the site asks for one, it stops and reports that. Keep requests rare (at most one per 10 s in the background).
import AppKit
import WebKit

@MainActor
extension Kino: WKNavigationDelegate {
    static let site = "https://rezka.ag"
    // MARK: Page session

    func session() async -> WKWebView? {
        if ready, let web { return web }
        if web == nil {
            let cfg = WKWebViewConfiguration(); cfg.websiteDataStore = .default()
            let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: cfg)
            w.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
            w.navigationDelegate = self
            web = w
            w.load(URLRequest(url: URL(string: Kino.site + "/")!))
        }
        await withCheckedContinuation { k in
            waiters.append(k)
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in self?.release() }   // never hang a request
        }
        return ready ? web : nil
    }

    func release() { let w = waiters; waiters = []; w.forEach { $0.resume() } }

    func webView(_ w: WKWebView, didFinish _: WKNavigation!) {
        // The bot check page keeps reloading itself until it passes; only the real site counts as ready.
        if !(w.title ?? "").lowercased().contains("не бот") { ready = true; release() }
    }

    func webView(_ w: WKWebView, didFail _: WKNavigation!, withError _: Error) { release() }

    /// Runs JS (async body, `return` allowed) in the rezka page and returns its JSON-compatible result.
    func js(_ body: String, _ args: [String: Any] = [:]) async -> Any? {
        guard let w = await session() else { return nil }
        return try? await w.callAsyncJavaScript(body, arguments: args, contentWorld: .page)
    }

    /// Catalog commands served by HDRezka; nil = not ours.
    func hdrezka(_ cmd: String, _ b: [String: Any]) async -> Any? {
        switch cmd {
        case "kino/search": return await search(b["q"] as? String ?? "")
        case "kino/find": return await find(b)
        case "kino/title": return await title(b["url"] as? String ?? "")
        case "kino/episodes": return await episodes(id: b["id"] as? String ?? "", translator: b["translator"] as? String ?? "")
        case "kino/play": return await play(b)
        case "kino/resume": return await resume(b["q"] as? String ?? "")
        case "kino/next/play": return await playNext()
        case "kino/step": return await step(b["dir"] as? Int ?? 1)
        case "kino/stream":
            // Watch on the phone itself: the direct stream for the chosen episode and quality, no TV.
            guard let id = b["id"] as? String, let tr = b["translator"] as? String else { return ["error": "Missing title"] }
            let list = await streams(id: id, translator: tr, season: b["season"] as? Int, episode: b["episode"] as? Int)
            func rank(_ q: String) -> Int { q.hasSuffix("Premium") ? -1 : (Int(q.prefix { $0.isNumber }) ?? 0) * 10 + (q.lowercased().contains("ultra") ? 1 : 0) }
            guard let pick = list.first(where: { $0.q == (b["quality"] as? String) }) ?? list.max(by: { rank($0.q) < rank($1.q) }) else {
                return ["error": "No stream for that choice"] }
            store.recordStart(b)
            return ["url": pick.url, "quality": pick.q, "qualities": list.map { $0.q }]
        default: return nil
        }
    }


    /// A Discover film on HDRezka: same year (±1), Russian title first. Gives "where to watch" and a fallback poster.
    func find(_ b: [String: Any]) async -> Any {
        let key = b["imdb"] as? String ?? ""
        if let f = found[key] { return f }
        let year = b["year"] as? Int ?? 0
        for q in [b["ru"] as? String, b["title"] as? String, b["orig"] as? String].compactMap({ $0 }).filter({ !$0.isEmpty }) {
            // HDRezka's quick search (the one that suggests names while typing): it answers when the full search
            // page is refused (2026-10-21), and needs no browser tab. Falls back to the full search.
            var list = await Kino.quickSearch(q)
            if list.isEmpty { list = await search(q) as? [[String: Any]] ?? [] }
            if let hit = list.first(where: { x in
                let years = ((x["info"] as? String) ?? "").split { !$0.isNumber }.compactMap { Int($0) }.filter { $0 > 1880 && $0 < 2100 }
                return year == 0 || years.contains { abs($0 - year) <= 1 } }) {
                let r: [String: Any] = ["url": hit["url"] ?? "", "poster": hit["poster"] ?? "", "title": hit["title"] ?? ""]
                found[key] = r; return r
            }
        }
        let none: [String: Any] = ["url": ""]
        found[key] = none; return none
    }

    /// POST /engine/ajax/search.php -> [{url, title, info: "Original, 1999"}].
    static func quickSearch(_ q: String) async -> [[String: Any]] {
        var r = URLRequest(url: URL(string: "https://rezka.ag/engine/ajax/search.php")!, timeoutInterval: 15); r.httpMethod = "POST"
        r.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        r.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        r.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        r.httpBody = Data(("q=" + (q.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")).utf8)
        guard let (d, _) = try? await URLSession.shared.data(for: r) else { return [] }
        let html = String(decoding: d, as: UTF8.self)
        guard let re = try? NSRegularExpression(pattern: #"<a href="([^"]+)"><span class="enty">([^<]+)</span>\s*\(([^)]*)\)"#) else { return [] }
        return re.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { m in
            guard let u = Range(m.range(at: 1), in: html), let t = Range(m.range(at: 2), in: html), let i = Range(m.range(at: 3), in: html) else { return nil }
            return ["url": String(html[u]), "title": String(html[t]), "info": String(html[i]), "poster": ""]
        }
    }

    func search(_ q: String) async -> Any {
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else { return [] as [Any] }
        let r = await js("""
        const r = await fetch('/search/?do=search&subaction=search&q=' + encodeURIComponent(q));
        const d = new DOMParser().parseFromString(await r.text(), 'text/html');
        return [...d.querySelectorAll('.b-content__inline_item')].slice(0, 36).map(e => ({
          url: e.dataset.url || (e.querySelector('.b-content__inline_item-link a') || {}).href || '',
          title: ((e.querySelector('.b-content__inline_item-link a') || {}).textContent || '').trim(),
          info: ((e.querySelector('.b-content__inline_item-link div') || {}).textContent || '').trim(),
          poster: (e.querySelector('img') || {}).src || '',
          type: ((e.querySelector('.entity') || {}).textContent || '').trim()
        })).filter(x => x.url);
        """, ["q": q])
        return r ?? []
    }

    func title(_ url: String) async -> Any {
        guard url.contains("rezka") else { return ["error": "Not an HDRezka link"] }
        let r = await js("""
        const page = url.split('#')[0];
        const html = await (await fetch(page)).text();
        const d = new DOMParser().parseFromString(html, 'text/html');
        const init = html.match(/initCDN(Series|Movies)Events\\(\\s*(\\d+)\\s*,\\s*(\\d+)\\s*,\\s*(\\d+)?\\s*,?\\s*(\\d+)?/);
        const series = init ? init[1] === 'Series' : !!d.querySelector('#simple-episodes-tabs');
        const tr = [...d.querySelectorAll('#translators-list .b-translator__item')].map(e => ({
          id: e.dataset.translator_id, name: (e.title || e.textContent).trim(), active: e.classList.contains('active') }));
        const eps = {};
        d.querySelectorAll('#simple-episodes-tabs .b-simple_episode__item').forEach(e => {
          (eps[e.dataset.season_id] = eps[e.dataset.season_id] || []).push(+e.dataset.episode_id); });
        const hash = url.match(/t:(\\d+)-s:(\\d+)-e:(\\d+)/) || url.match(/\\/(\\d+)-[^/]*\\/(\\d+)-season\\/(\\d+)-episode/);
        const id = init ? init[2] : ((d.querySelector('#post_id') || {}).value || '');
        const defTr = init ? init[3] : ((tr.find(t => t.active) || tr[0] || {}).id || '');
        return {
          id, url: page, series,
          title: ((d.querySelector('.b-post__title h1') || {}).textContent || '').trim().replace(/\\s+\\d+\\s+сезон.*$/i, '').replace(/\\s+в озвучке.*$/i, ''),
          original: ((d.querySelector('.b-post__origtitle') || {}).textContent || '').trim(),
          poster: (d.querySelector('.b-sidecover img') || {}).src || '',
          year: ((((d.querySelector('.b-post__info') || {}).textContent || '') + ' ' + ((d.querySelector('.b-post__infolast') || {}).textContent || '')).match(/(19|20)\\d\\d/) || [''])[0],
          translators: tr.length ? tr : [{id: defTr, name: 'Default', active: true}],
          translator: hash ? hash[1] : defTr,
          seasons: Object.keys(eps).map(s => ({n: +s, episodes: eps[s]})).sort((a, b) => a.n - b.n),
          linkSeason: hash ? +hash[2] : null, linkEpisode: hash ? +hash[3] : null
        };
        """, ["url": url])
        guard var t = r as? [String: Any] else { return ["error": "HDRezka didn't answer"] }
        if let id = t["id"] as? String { t["progress"] = store.progress(id) ?? NSNull(); t["bookmarked"] = store.isBookmarked(id) }
        return t
    }

    func episodes(id: String, translator: String) async -> Any {
        let r = await js("""
        const body = new URLSearchParams({id, translator_id: translator, action: 'get_episodes'});
        const j = await (await fetch('/ajax/get_cdn_series/?t=' + Date.now(), {method: 'POST', body,
          headers: {'Content-Type': 'application/x-www-form-urlencoded', 'X-Requested-With': 'XMLHttpRequest'}})).json();
        const d = new DOMParser().parseFromString('<ul>' + (j.episodes || '') + '</ul>', 'text/html');
        const eps = {};
        d.querySelectorAll('[data-episode_id]').forEach(e => { (eps[e.dataset.season_id] = eps[e.dataset.season_id] || []).push(+e.dataset.episode_id); });
        return Object.keys(eps).map(s => ({n: +s, episodes: eps[s]})).sort((a, b) => a.n - b.n);
        """, ["id": id, "translator": translator])
        return r ?? []
    }

    /// Streams for one episode (series) or the film, as [(quality, url)] from the "#h…" string the site returns.
    func streams(id: String, translator: String, season: Int?, episode: Int?) async -> [(q: String, url: String)] {
        let r = await js("""
        const p = {id, translator_id: translator, action: season ? 'get_stream' : 'get_movie'};
        if (season) { p.season = season; p.episode = episode; }
        const j = await (await fetch('/ajax/get_cdn_series/?t=' + Date.now(), {method: 'POST', body: new URLSearchParams(p),
          headers: {'Content-Type': 'application/x-www-form-urlencoded', 'X-Requested-With': 'XMLHttpRequest'}})).json();
        return j.url || '';
        """, ["id": id, "translator": translator, "season": season as Any? ?? NSNull(), "episode": episode as Any? ?? NSNull()])
        guard let raw = r as? String, !raw.isEmpty else { return [] }
        return Rezka.decode(raw).split(separator: ",").compactMap { part -> (String, String)? in
            guard let close = part.firstIndex(of: "]") else { return nil }
            let raw = String(part[part.index(after: part.startIndex)..<close])
            // Premium qualities come as HTML ("<span class=pjs-prem-quality>4K<img…>") and, without a paid
            // account, stream only a 60 s preview (measured 2026-10-20): clean label, marked so auto-pick skips it.
            let name = raw.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            let q = raw.contains("pjs-prem") ? name + " · Premium" : name
            let urls = part[part.index(after: close)...].components(separatedBy: " or ").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let u = urls.first(where: { $0.hasSuffix(".mp4") }) ?? urls.first, u.hasPrefix("http") else { return nil }
            return (q, u)
        }
    }

    func play(_ b: [String: Any]) async -> Any {
        film = nil   // HDRezka plays now: no torrent film card
        guard let id = b["id"] as? String, let tr = b["translator"] as? String else { return ["error": "Missing title"] }
        let season = b["season"] as? Int, episode = b["episode"] as? Int
        let list = await streams(id: id, translator: tr, season: season, episode: episode)
        guard !list.isEmpty else { return ["error": "No stream for that choice"] }
        let want = (b["quality"] as? String) ?? ""
        // Owner: highest available by default (4K when the site has it, "Ultra" = higher bitrate of the same size).
        func rank(_ q: String) -> Int { q.hasSuffix("Premium") ? -1 : (Int(q.prefix { $0.isNumber }) ?? 0) * 10 + (q.lowercased().contains("ultra") ? 1 : 0) }
        let pick = list.first { $0.q == want } ?? list.max { rank($0.q) < rank($1.q) }!
        var item = b; item["quality"] = pick.q; item["qualities"] = list.map { $0.q }
        current = item; next = nil; nextTimer?.cancel()
        store.recordStart(item)
        let label = (b["title"] as? String ?? "HDRezka") + (season.map { " · S\($0)E\(episode ?? 0)" } ?? "")
        // A resume from a page opened earlier carries the second it showed then; after a drop-out the core knows a later one.
        var from = b["from"] as? Double ?? 0
        if from > 0, let saved = store.episodePosition(id, season: season, episode: episode), abs(saved - from) > 10 { from = saved }
        Caster.shared.castAt(pick.url, title: label, from: from)
        // The TV reports no duration for this stream: read it from the file header (needed for progress and "next").
        let streamURL = pick.url, probeTool = Caster.tool("ffprobe")
        Task.detached {
            guard let probe = probeTool else { return }
            let r = Caster.run(probe, ["-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", streamURL])
            if let d = Double(String(decoding: r.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)), d > 0 {
                await MainActor.run { if Caster.shared.title == label { Caster.shared.duration = d } }
            }
        }
        watch(label: label, from: from)
        return ["ok": true, "quality": pick.q, "qualities": item["qualities"] as Any, "from": from]
    }

    /// Seeks to the saved second once the TV plays, saves the position every 5 s, offers the next episode at the end.
    func watch(label: String, from: Double) {
        watcher?.cancel()
        watcher = Task { @MainActor in
            var lastPos = from, dur: Double = 0
            for _ in 0..<(6 * 60 * 60 / 5) {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                let c = Caster.shared
                guard c.title == label else {                       // something else plays now, or the TV dropped the stream
                    if c.title.isEmpty, dur > 0, dur - lastPos < 120 { finished() }   // ...at the credits: still go on
                    break
                }
                if c.displayPosition > 0 { lastPos = c.displayPosition }
                if c.duration > 0 { dur = c.duration }
                if let id = current?["id"] as? String { store.saveProgress(id, position: lastPos, duration: dur) }
                if dur > 0, lastPos > dur - 45, !c.playing { finished(); break }
            }
        }
    }

    func finished() {
        guard var cur = current, let id = cur["id"] as? String else { return }
        store.markWatched(id, season: cur["season"] as? Int, episode: cur["episode"] as? Int)
        guard let s = cur["season"] as? Int, let e = cur["episode"] as? Int,
              let seasons = cur["seasons"] as? [[String: Any]] else { return }
        // Next episode in this season, else the first of the next season.
        let eps = (seasons.first { ($0["n"] as? Int) == s }?["episodes"] as? [Int]) ?? []
        if let n = eps.first(where: { $0 > e }) { cur["episode"] = n }
        else if let ns = seasons.compactMap({ $0["n"] as? Int }).filter({ $0 > s }).min(),
                let first = (seasons.first { ($0["n"] as? Int) == ns }?["episodes"] as? [Int])?.min() {
            cur["season"] = ns; cur["episode"] = first
        } else { return }
        cur["from"] = 0
        next = ["season": cur["season"] as Any, "episode": cur["episode"] as Any, "at": Date().timeIntervalSince1970 + 10]
        current = cur
        nextTimer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled, next != nil else { return }
            _ = await playNext()
        }
    }

    /// Voice ("включи менталіста"): finds the title in the history by a word in any case form and goes on where it
    /// stopped; a watched episode moves to the next one. Returns "say" for the Shortcut to speak.
    func resume(_ q: String) async -> Any {
        func norm(_ t: String) -> [String] {
            let m: [Character: Character] = ["і": "и", "ї": "и", "є": "е", "ґ": "г", "ё": "е", "ы": "и", "э": "е"]
            return String(t.lowercased().map { m[$0] ?? $0 }).split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 }
        }
        // "менталиста" ~ "менталист": a shared start of 5 letters (or the whole shorter word).
        func near(_ a: String, _ b: String) -> Bool {
            let n = zip(a, b).prefix { $0 == $1 }.count
            return n >= min(5, a.count, b.count)
        }
        let words = norm(q).filter { !["включи", "увімкни", "увимкни", "постав", "запусти", "серіал", "сериал", "фильм", "фільм", "далі", "дали"].contains($0) }
        let history = store.home()["history"] as? [[String: Any]] ?? []
        guard !words.isEmpty, var h = history.first(where: { h in
            let tw = norm(h["title"] as? String ?? ""); return words.contains { w in tw.contains { near($0, w) } } }) else {
            return ["error": "Не знайшов в історії", "say": "Не знайшов це в історії перегляду"]
        }
        guard let id = h["id"] as? String else { return ["error": "Bad history entry"] }
        if let q = h["quality"] as? String, q.contains("<") || q.hasSuffix("Premium") { h["quality"] = nil }
        var from = 0.0
        if let s = h["season"] as? Int, let e = h["episode"] as? Int {
            let key = "\(s):\(e)", watched = (h["watched"] as? [String] ?? []).contains(key)
            if watched, let seasons = h["seasons"] as? [[String: Any]] {
                let eps = (seasons.first { ($0["n"] as? Int) == s }?["episodes"] as? [Int]) ?? []
                if let n = eps.first(where: { $0 > e }) { h["episode"] = n }
                else if let ns = seasons.compactMap({ $0["n"] as? Int }).filter({ $0 > s }).min(),
                        let first = (seasons.first { ($0["n"] as? Int) == ns }?["episodes"] as? [Int])?.min() { h["season"] = ns; h["episode"] = first }
            }
            if !watched { from = store.episodePosition(id, season: s, episode: e) ?? 0 }
        } else { from = (h["position"] as? Double ?? 0) }
        if from < 30 { from = 0 }
        h["from"] = from
        if let t = h["translator"] { h["translator"] = "\(t)" }
        let r = await play(h)
        if let e = (r as? [String: Any])?["error"] { return ["error": e, "say": "Не вийшло запустити"] }
        let ep = (h["season"] as? Int).map { " сезон \($0), серія \(h["episode"] as? Int ?? 0)" } ?? ""
        let at = from > 0 ? ", з \(Int(from) / 60) хвилини" : ""
        return ["ok": true, "say": "Вмикаю \(h["title"] as? String ?? "")\(ep)\(at)"]
    }

    func playNext() async -> Any {
        guard let cur = current, next != nil else { return ["error": "Nothing next"] }
        next = nil; nextTimer?.cancel()
        return await play(cur)
    }

    /// Previous / next episode buttons: same voiceover and quality; resumes a half-watched episode where it stopped.
    func step(_ dir: Int) async -> Any {
        guard var cur = current, let id = cur["id"] as? String, let n = neighbour(dir) else { return ["error": "Немає такої серії"] }
        next = nil; nextTimer?.cancel()
        cur["season"] = n.s; cur["episode"] = n.e
        let key = "\(n.s):\(n.e)", watched = ((store.progress(id)?["watched"] as? [String]) ?? []).contains(key)
        let at = watched ? 0 : (store.episodePosition(id, season: n.s, episode: n.e) ?? 0)
        cur["from"] = at < 30 ? 0 : at
        return await play(cur)
    }

}
