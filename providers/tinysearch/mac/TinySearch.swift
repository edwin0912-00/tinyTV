// tinySearch - torrent client panel in the Mac menu bar (owner 2026-10-22: its own tool, native SwiftUI).
// Two tabs: Пошук (work cards) and Завантаження (one list: Transmission + the TV Cast engine).
// Talks only to searchd (core host on the tailnet :8444 by default; the server menu switches to a peer); searchd talks to
// Transmission, the sources and the tinyTV core.
// Debug keys: --api <url> (base for this run only), --shot out.png "query" [--tv] [--tab 1] [--files] [--delete], --selftest.
import SwiftUI
import AppKit

let defaultAPI = "https://<core-host>.<tailnet>.ts.net:8444/api/"

func argValue(_ k: String) -> String? { let a = CommandLine.arguments; guard let i = a.firstIndex(of: k), a.count > i + 1 else { return nil }; return a[i + 1] }
// "https://host:8444", "https://host:8444/" or "https://host:8444/api/" -> https://host:8444/api/ (the base every request is built on)
func apiURL(_ s: String) -> URL? {
    var u = s.trimmingCharacters(in: .whitespacesAndNewlines); guard !u.isEmpty else { return nil }
    while u.hasSuffix("/") { u.removeLast() }
    if u.hasSuffix("/api") { u.removeLast(4) }
    return URL(string: u + "/api/")
}
func apiBase() -> URL { apiURL(argValue("--api") ?? UserDefaults.standard.string(forKey: "api") ?? defaultAPI) ?? URL(string: defaultAPI)! }
// Torrent ids hold a colon ('tr:12', 'tv:<hash>'): every colon and slash goes into the path as a %-escape.
func enc(_ id: String) -> String { id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id }

struct Src: Codable, Identifiable { let id: String; let label: String; let ok: Bool?; let ms: Int?; let n: Int?; let err: String?; let cooldown: Double; let ago: Int? }
struct JobSrc: Codable { let state: String; let label: String; let n: Int?; let ms: Int?; let cached: Bool?; let err: String? }
struct Have: Codable { let engine: String?; let id: String?; let progress: Double; let state: String? }
struct Item: Codable, Identifiable {
    var id: String { hash.isEmpty ? (topic ?? page ?? title) : hash }
    let title: String; let tracker: String; let seeds: Int; let quality: Int; let size_gb: Double?; let grade: String
    let hash: String; let magnet: String; let topic: String?; let also: [String]?; let page: String?; let category: String?
    let codec: String?; let dv5: Bool?; let tv_ok: Bool?; let tenbit: Bool?; let mbps: Int?; let hdr: Bool?; let audio: [String]?; let have: Have?
}
// One film / album / game = one card with its best release (the server folds the rows: group.py).
struct Work: Codable, Identifiable {
    var id: String { key }
    let key: String; let title: String; let year: String?; let kind: String?; let count: Int?; var best: Item?; let rows: [Item]
}
struct Job: Decodable {
    let id: String; let q: String; let state: String; let count: Int; let ms: Int?; let items: [Item]?; let sources: [String: JobSrc]?; let works: [Work]?
    enum K: String, CodingKey { case id, q, state, count, ms, items, sources, works }
    init(from d: Decoder) throws {   // a bad card must not hide the rows: every optional part decodes on its own
        let c = try d.container(keyedBy: K.self)
        id = try c.decode(String.self, forKey: .id); q = try c.decode(String.self, forKey: .q); state = try c.decode(String.self, forKey: .state)
        count = (try? c.decode(Int.self, forKey: .count)) ?? 0; ms = try? c.decode(Int.self, forKey: .ms)
        items = try? c.decode([Item].self, forKey: .items); sources = try? c.decode([String: JobSrc].self, forKey: .sources); works = try? c.decode([Work].self, forKey: .works)
    }
}
struct JobSum: Codable, Identifiable { let id: String; let q: String; let from: String; let created: Double; let count: Int }
struct Peer: Codable { let name: String; let url: String }
struct ServerInfo: Codable { let name: String; let public_url: String?; let tv: Bool?; let peers: [Peer]? }
struct ClientInfo: Codable { var alt_speed: Bool; let free_gb: Double? }
struct FileRow: Codable, Identifiable { var id: Int { index }; let index: Int; let name: String; let size: Double; let done: Double; let wanted: Bool }
// One row of GET torrents (Transmission or the TV engine). Lenient: a missing number is 0, so one odd row never empties the list.
struct Tor: Decodable, Identifiable, Equatable {
    let id: String, engine: String, hash: String, name: String, state: String, error: String
    let size: Double, progress: Double, down: Double, up: Double, eta: Double, ratio: Double
    enum K: String, CodingKey { case id, engine, hash, name, state, error, size, progress, down, up, eta, ratio }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        func s(_ k: K, _ def: String = "") -> String { (try? c.decode(String.self, forKey: k)) ?? def }
        func n(_ k: K, _ def: Double = 0) -> Double { (try? c.decode(Double.self, forKey: k)) ?? def }
        id = try c.decode(String.self, forKey: .id); engine = s(.engine, "transmission"); hash = s(.hash); name = s(.name, "?"); state = s(.state, "paused"); error = s(.error)
        size = n(.size); progress = n(.progress); down = n(.down); up = n(.up); eta = n(.eta, -1); ratio = n(.ratio)
    }
}
struct ApiError: Error { let msg: String }

// Readable name: the part after the first " / " in Russian-style titles, without the bracket tail (same as search.html).
func nice(_ t: String) -> String {
    let p = t.components(separatedBy: " / "); var n = p.count > 1 ? p.dropFirst().joined(separator: " / ") : t
    if let r = n.range(of: #"\s*[\[(|].*$"#, options: .regularExpression) { n.removeSubrange(r) }
    return n.count > 3 ? n.trimmingCharacters(in: .whitespaces) : t
}
func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let a = n % 10, b = n % 100
    return "\(n) " + (a == 1 && b != 11 ? one : (2...4).contains(a) && !(12...14).contains(b) ? few : many)
}
func kindName(_ k: String?) -> String { ["film": "Фільм", "series": "Серіал", "music": "Музика", "book": "Книга", "game": "Гра", "software": "Софт"][k ?? ""] ?? "Інше" }
func fmtBytes(_ b: Double) -> String { b >= 1_073_741_824 ? String(format: "%.1f ГБ", b / 1_073_741_824) : b >= 1_048_576 ? String(format: "%.0f МБ", b / 1_048_576) : String(format: "%.0f КБ", b / 1024) }
func fmtSpeed(_ b: Double) -> String { b >= 1_048_576 ? String(format: "%.1f МБ/с", b / 1_048_576) : b >= 1024 ? String(format: "%.0f КБ/с", b / 1024) : "\(Int(b)) Б/с" }
func etaText(_ s: Double) -> String {
    guard s >= 0 else { return "" }
    let m = Int(s) / 60, h = m / 60
    return m < 1 ? "< 1 хв" : h < 1 ? "\(m) хв" : h < 24 ? "\(h) год \(m % 60) хв" : "\(h / 24) д \(h % 24) год"
}
let stateName = ["downloading": "Качається", "seeding": "Роздаю", "paused": "Пауза", "checking": "Перевірка", "queued": "У черзі", "done": "Готово", "error": "Помилка"]

@MainActor final class Model: ObservableObject {
    @Published var tab = 0
    @Published var base = apiBase()
    @Published var server: ServerInfo?
    @Published var q = ""
    @Published var film = false
    @Published var rutracker = false
    @Published var tvOnly = false
    @Published var uaOnly = false
    @Published var job: Job?
    @Published var sources: [Src] = []
    @Published var recent: [JobSum] = []
    @Published var torrents: [Tor] = []
    @Published var torrentsLoaded = false   // false until GET torrents answered: then `have` falls back to the mark the server put on the row
    @Published var torrentsErr = ""
    @Published var client: ClientInfo?
    @Published var filesFor: Tor?
    @Published var files: [FileRow] = []
    @Published var filesLoaded = false   // a magnet without metadata answers an empty list: that is not the same as «still reading»
    @Published var wanted: Set<Int> = []
    @Published var delFor: Tor?
    @Published var toast = ""
    @Published var clipMagnet = ""
    weak var win: NSWindow?
    private var poll: Task<Void, Never>?
    private var busy = false
    private var quietLock = Date.distantPast   // after the owner flips «Тихий режим», a poll must not flip it back before the server answers

    var visible: Bool { win?.isVisible == true }   // the 2 s refresh runs only while the panel is on screen
    var active: Int { torrents.filter { ["downloading", "checking", "queued"].contains($0.state) }.count }

    // MARK: requests (every path is built on `base`; an answer that arrives after a server switch is dropped)
    func req(_ path: String, _ body: [String: Any]? = nil) async throws -> Data {
        let b = base
        guard let u = URL(string: b.absoluteString + path) else { throw ApiError(msg: "Погана адреса") }
        var r = URLRequest(url: u); r.timeoutInterval = body == nil ? 10 : 95
        if let body { r.httpMethod = "POST"; r.setValue("application/json", forHTTPHeaderField: "Content-Type"); r.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let d = try await URLSession.shared.data(for: r).0
        if b != base { throw CancellationError() }
        return d
    }
    func get<T: Decodable>(_ p: String) async throws -> T {
        let d = try await req(p)
        if let t = try? JSONDecoder().decode(T.self, from: d) { return t }
        if let e = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["error"] as? String { throw ApiError(msg: e) }   // {error} with 4xx/5xx
        return try JSONDecoder().decode(T.self, from: d)
    }
    func post(_ p: String, _ b: [String: Any]) async throws -> [String: Any] {
        (try JSONSerialization.jsonObject(with: try await req(p, b))) as? [String: Any] ?? [:]
    }
    func say(_ s: String) { toast = s; Task { try? await Task.sleep(for: .seconds(3)); if toast == s { toast = "" } } }

    // MARK: loading
    func loadServer() async { if let s: ServerInfo = try? await get("server") { server = s } }
    func loadSources() async { sources = (try? await get("sources")) ?? sources }
    func loadRecent() async { recent = (try? await get("jobs")) ?? recent }
    func loadClient() async { if Date() < quietLock { return }; if let c: ClientInfo = try? await get("client") { client = c } }
    func loadTorrents() async {
        do { let t: [Tor] = try await get("torrents"); if t != torrents { torrents = t }; torrentsErr = ""; torrentsLoaded = true }
        catch is CancellationError {}
        catch let e as ApiError { torrentsErr = e.msg; torrentsLoaded = false }   // «Transmission не працює: ...» comes from the server
        catch { torrentsErr = "searchd не відповідає"; torrentsLoaded = false }
    }
    func checkClip() { let c = NSPasteboard.general.string(forType: .string) ?? ""; clipMagnet = c.hasPrefix("magnet:?") ? c : "" }
    func reload() async {   // first load, panel opened, server switched
        async let a: Void = loadServer(); async let b: Void = loadTorrents(); async let c: Void = loadClient(); async let d: Void = loadSources(); async let e: Void = loadRecent()
        _ = await (a, b, c, d, e); checkClip()
    }
    func tick() async {   // every 2 s while visible: the list always (the tab label and the «є тут» marks use it), the rest by tab
        guard !busy else { return }; busy = true; defer { busy = false }
        await loadTorrents()
        if tab == 1 { await loadClient() } else { await loadSources(); checkClip() }
    }
    func switchServer(_ url: String) {
        guard let nb = apiURL(url), nb != base else { return }
        UserDefaults.standard.set(nb.absoluteString, forKey: "api")
        poll?.cancel(); base = nb; server = nil; job = nil; torrents = []; torrentsLoaded = false; torrentsErr = ""; client = nil; sources = []; recent = []
        filesFor = nil; delFor = nil; say("Сервер: " + (URL(string: url)?.host ?? url))
        Task { await reload() }
    }

    // MARK: search
    func search() {
        let text = q.trimmingCharacters(in: .whitespaces); guard !text.isEmpty else { return }
        Task { do { let r = try await post("jobs", ["q": text, "film": film, "rutracker": rutracker, "from": "Мак"])
            if let id = r["id"] as? String { open(id) } else { say(r["error"] as? String ?? "Помилка") } } catch { say("searchd не відповідає") } }
    }
    func open(_ id: String) {
        poll?.cancel()
        poll = Task { while !Task.isCancelled {
            guard let j: Job = try? await get("jobs/" + id) else { if !Task.isCancelled { say("searchd не відповідає") }; return }
            job = j; if j.state == "done" { await loadRecent(); await loadSources(); return }
            try? await Task.sleep(for: .milliseconds(700)) } }
    }
    func pass(_ r: Item) -> Bool { (!tvOnly || r.tv_ok == true) && (!uaOnly || (r.audio ?? []).contains("UA")) }
    var shown: [Item] { (job?.items ?? []).filter(pass) }
    var cards: [Work] {   // the TV ✓ / UA toggles filter the rows of each card; a card with none left is hidden
        (job?.works ?? []).compactMap { w in
            let rows = w.rows.filter(pass); guard !rows.isEmpty else { return nil }
            var b = w.best; if let x = b, !pass(x) { b = rows.first }   // the server's pick fails the filter: the first row that passes (rows come ranked)
            return Work(key: w.key, title: w.title, year: w.year, kind: w.kind, count: (tvOnly || uaOnly) ? rows.count : (w.count ?? rows.count), best: b ?? rows.first, rows: rows)
        }
    }
    // «є тут»: the live list when it is loaded (so the mark follows the progress and drops when the torrent is removed), else the server's mark.
    func have(_ t: Item) -> Have? {
        let h = t.hash.lowercased()
        guard torrentsLoaded else { return t.have }
        return h.isEmpty ? nil : torrents.first { $0.hash.lowercased() == h }.map { Have(engine: $0.engine, id: $0.id, progress: $0.progress, state: $0.state) }
    }

    // MARK: actions
    func act(_ t: Item, _ to: String) {
        if to == "copy" {
            Task { var m = t.magnet
                if m.isEmpty { say("Беру магнет…"); let r = try? await post("act", ["to": "magnet", "page": t.page ?? "", "topic": t.topic ?? ""]); m = r?["magnet"] as? String ?? "" }
                if m.isEmpty { say("Не знайшов магнет"); return }
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(m, forType: .string); say("Магнет скопійовано") }
            return
        }
        if to == "download" { add(["magnet": t.magnet, "topic": t.topic ?? "", "page": t.page ?? "", "title": nice(t.title)]); return }
        say("Відправляю на ТВ…")
        Task { let r = try? await post("act", ["to": "tv", "magnet": t.magnet, "topic": t.topic ?? "", "page": t.page ?? "", "title": nice(t.title), "from": "Мак"])
            say(r == nil ? "searchd не відповідає" : (r?["error"] as? String).map { "Не вийшло: " + $0 } ?? "На ТВ") }
    }
    func add(_ b: [String: Any]) {   // POST torrents/add -> {id, hash, name, duplicate, warning?}
        say("Додаю…")
        Task { do { let r = try await post("torrents/add", b); let name = nice(r["name"] as? String ?? "")
                if let e = r["error"] as? String { say("Не вийшло: " + e) }
                else if r["duplicate"] as? Bool == true { say("Вже є в списку: " + name) }
                else { say(r["warning"] as? String ?? "Додано: " + name) } }
            catch { say("searchd не відповідає") }
            await loadTorrents() }
    }
    func downloadClip() { add(["magnet": clipMagnet]); clipMagnet = "" }
    func send(_ t: Tor, _ action: String, _ extra: [String: Any] = [:]) async -> String? {   // POST torrents/<id> {action, ...}; nil = done, else the reason
        do { return try await post("torrents/" + enc(t.id), extra.merging(["action": action]) { _, new in new })["error"] as? String }
        catch is CancellationError { return nil }
        catch { return "searchd не відповідає" }
    }
    func control(_ t: Tor, _ action: String, _ extra: [String: Any] = [:], ok: String? = nil) {
        Task { if let e = await send(t, action, extra) { say("Не вийшло: " + e) } else if let ok { say(ok) }
            await loadTorrents() }
    }
    func openFiles(_ t: Tor) {
        filesFor = t; files = []; wanted = []; filesLoaded = false
        Task { do { let f: [FileRow] = try await get("torrents/" + enc(t.id) + "/files"); guard filesFor?.id == t.id else { return }; files = f; wanted = Set(f.filter(\.wanted).map(\.index)); filesLoaded = true }
            catch let e as ApiError { say(e.msg); filesFor = nil }
            catch is CancellationError {}
            catch { say("searchd не відповідає"); filesFor = nil } }
    }
    func saveFiles(_ t: Tor) {
        let off = files.map(\.index).filter { !wanted.contains($0) }
        control(t, "files", ["wanted": wanted.sorted(), "unwanted": off], ok: "Файли збережено"); filesFor = nil
    }
    func setQuiet(_ on: Bool) {
        quietLock = Date().addingTimeInterval(3); client?.alt_speed = on
        Task { let r = try? await post("client", ["alt_speed": on])
            if r == nil || r?["error"] != nil { say(r?["error"] as? String ?? "searchd не відповідає") }
            quietLock = .distantPast; await loadClient() }
    }
}

// MARK: search tab
struct Tag: View {
    let text: String; var fg: Color = .secondary; var bg: Color = .gray.opacity(0.18)
    var body: some View { Text(text).font(.system(size: 10, weight: .bold)).foregroundStyle(fg).padding(.horizontal, 6).padding(.vertical, 2).background(bg, in: .rect(cornerRadius: 5)) }
}

struct Tags: View {   // the tag line of one release (quality, TV ✓, codec, audio, size, seeds, trackers)
    let t: Item
    var gradeColor: Color { ["g": .green, "y": .yellow, "u": .purple][t.grade] ?? .red }
    var body: some View {
        HStack(spacing: 4) {
            if t.quality > 0 { Tag(text: t.quality == 2160 ? "4K" : "\(t.quality)p") }
            if t.dv5 == true { Tag(text: "DV5 ✕", fg: .red, bg: .red.opacity(0.18)).help("Dolby Vision без HDR10: на ТВ кольори зламаються") }
            else if t.tv_ok == true { Tag(text: t.tenbit == true ? "TV ✓ 10-біт" : "TV ✓", fg: .green, bg: .green.opacity(0.16)).help("ТВ грає без перекодування") }
            else if (t.mbps ?? 0) > 36 { Tag(text: "~\(t.mbps!) Мбіт/с", fg: .orange, bg: .orange.opacity(0.16)).help("перекодую під Wi-Fi ТВ") }
            if let c = t.codec, !c.isEmpty { Tag(text: c.uppercased()) }
            ForEach(t.audio ?? [], id: \.self) { a in a == "UA" ? Tag(text: a, fg: .yellow, bg: .blue.opacity(0.3)) : Tag(text: a) }
            if let c = t.category, !c.isEmpty { Tag(text: String(c.prefix(24))) }
            if let g = t.size_gb { Tag(text: g >= 1 ? String(format: "%.1f ГБ", g) : "\(Int(g * 1024)) МБ") }
            if t.tracker != "audiobookbay" { Text("● \(t.seeds)").font(.system(size: 10, weight: .bold)).foregroundStyle(gradeColor) }
            Spacer(minLength: 0)
            Text(([t.tracker] + (t.also ?? [])).joined(separator: ", ")).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
        }
    }
}

struct Acts: View {   // ТВ (only where the server has a TV) · ↓ or «є тут NN %» · copy the magnet
    let t: Item; @EnvironmentObject var m: Model
    var body: some View {
        HStack(spacing: 8) {
            if m.server?.tv == true { Button("ТВ") { m.act(t, "tv") }.help("На ТВ") }
            if let h = m.have(t) { Text("є тут \(Int((h.progress * 100).rounded())) %").font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(.green).help("Уже в списку: вкладка «Завантаження»") }
            else { Button { m.act(t, "download") } label: { Image(systemName: "arrow.down.circle") }.help("Скачати на \(m.server?.name ?? "сервер")") }
            Button { m.act(t, "copy") } label: { Image(systemName: "link") }.help("Скопіювати магнет")
        }.buttonStyle(.borderless)
    }
}

struct Row: View {   // one release
    let t: Item
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) { Text(nice(t.title)).font(.system(size: 13, weight: .semibold)).lineLimit(1); Spacer(); Acts(t: t) }
            Tags(t: t)
        }.padding(.vertical, 4).opacity(t.dv5 == true ? 0.6 : 1).help(t.title)
    }
}

struct WorkCard: View {
    let w: Work; @EnvironmentObject var m: Model; @State private var open = CommandLine.arguments.contains("--expand")   // --expand: debug shots show the release list
    var body: some View {
        let b = w.best ?? w.rows.first
        let elsewhere = b.map { m.have($0) == nil } == true && w.rows.contains { m.have($0) != nil }   // another release of this work is already here
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(w.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                if let y = w.year, !y.isEmpty { Text(y).font(.system(size: 12)).foregroundStyle(.secondary) }
                Tag(text: kindName(w.kind), fg: .blue, bg: .blue.opacity(0.15))
                if elsewhere { Tag(text: "є тут", fg: .green, bg: .green.opacity(0.16)).help("Інший реліз цього твору вже в списку") }
                Spacer(minLength: 4)
                Text(plural(w.count ?? w.rows.count, "реліз", "релізи", "релізів")).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            if let b {
                let rel = nice(b.title)   // the picked release; a name that only repeats the card title is not worth a line of its own
                HStack(alignment: .firstTextBaseline) { Text(rel.lowercased() == w.title.lowercased() ? "найкращий реліз" : rel).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1); Spacer(); Acts(t: b) }.help(b.title)
                Tags(t: b)
            }
            DisclosureGroup(isExpanded: $open) {
                VStack(alignment: .leading, spacing: 0) { Divider(); ForEach(Array(w.rows.enumerated()), id: \.offset) { Row(t: $0.element); Divider() } }
            } label: { Text("Усі релізи").font(.system(size: 11)).foregroundStyle(.secondary) }
        }.padding(10).background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 10))
    }
}

struct SearchTab: View {
    @EnvironmentObject var m: Model
    func srcLine(_ s: Src) -> some View {
        let c: Color = s.ok == nil ? .gray : s.ok! ? (s.cooldown > 0 ? .yellow : .green) : .red
        return HStack(spacing: 4) { Circle().fill(c).frame(width: 7, height: 7)
            Text(s.label).font(.system(size: 11)); Text(s.cooldown > 0 ? "\(Int(s.cooldown.rounded(.up))) с" : s.ms.map { String(format: "%.1f с", Double($0) / 1000) } ?? "-")
                .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary) }.help(s.err ?? "")
    }
    @ViewBuilder func results(_ j: Job) -> some View {
        HStack { Text("«\(j.q)»").font(.headline); Spacer()
            Text(j.state == "done" ? "\(j.count) · \(String(format: "%.1f", Double(j.ms ?? 0) / 1000)) с" : "шукаю…").font(.caption).foregroundStyle(.secondary) }
        let cards = m.cards
        ScrollView { LazyVStack(alignment: .leading, spacing: 8) {
            if !cards.isEmpty { ForEach(cards) { WorkCard(w: $0) } }
            else { ForEach(m.shown.prefix(60)) { Row(t: $0); Divider() } }   // no cards (older server, or the grouping failed): the plain rows
        } }.frame(maxHeight: .infinity)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Image(systemName: "magnifyingglass"); TextField("Що знайти… (фільм, музика, книга, гра, софт)", text: $m.q).textFieldStyle(.plain).onSubmit { m.search() }
                if m.job?.state == "run" { ProgressView().controlSize(.small) } }
                .padding(8).background(.quaternary, in: .rect(cornerRadius: 8))
            HStack { Toggle("Точна назва", isOn: $m.film); Spacer(); Toggle("TV ✓", isOn: $m.tvOnly); Toggle("UA", isOn: $m.uaOnly) }
                .toggleStyle(.button).controlSize(.small)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], spacing: 4) { ForEach(m.sources) { srcLine($0) } }
            if !m.clipMagnet.isEmpty {
                HStack { Image(systemName: "doc.on.clipboard"); Text("У буфері магнет").font(.callout); Spacer(); Button("Скачати на \(m.server?.name ?? "сервер")") { m.downloadClip() } }
                    .padding(8).background(.blue.opacity(0.15), in: .rect(cornerRadius: 8))
            }
            if let j = m.job { results(j) } else {
                Text("Останні пошуки").font(.caption).foregroundStyle(.secondary)
                ScrollView { VStack(alignment: .leading, spacing: 6) { ForEach(m.recent.prefix(12)) { j in
                    Button { m.q = j.q; m.open(j.id) } label: { HStack { Text(j.q).lineLimit(1); Spacer(); Text("\(j.from) · \(j.count)").foregroundStyle(.secondary) }.contentShape(.rect) }.buttonStyle(.plain)
                } } }.frame(maxHeight: .infinity)
            }
        }
    }
}

// MARK: downloads tab
struct TorRow: View {
    let t: Tor; @EnvironmentObject var m: Model
    var tv: Bool { t.engine == "tv" }
    var canPause: Bool { ["downloading", "seeding", "checking", "queued"].contains(t.state) }
    var canResume: Bool { ["paused", "error"].contains(t.state) }
    var tint: Color { ["downloading": .blue, "seeding": .green, "done": .green, "paused": .orange, "error": .red][t.state] ?? .gray }
    var left: String {
        let pct = "\(Int((t.progress * 100).rounded())) %", name = stateName[t.state] ?? t.state
        if t.state == "error" { return "Помилка: " + (t.error.isEmpty ? "-" : t.error) }
        if t.size <= 0 { return name + " · отримую метадані…" }
        if t.state == "seeding" || t.state == "done" { return name + " · " + fmtBytes(t.size) }
        return (t.state == "downloading" ? "" : name + " · ") + pct + " з " + fmtBytes(t.size)
    }
    var right: String {
        var p: [String] = []
        if t.down > 0 { p.append("↓ " + fmtSpeed(t.down)) }
        if t.up > 0 { p.append("↑ " + fmtSpeed(t.up)) }
        if t.state == "downloading", t.eta >= 0 { p.append(etaText(t.eta)) }
        if !tv, t.ratio >= 0 { p.append(String(format: "ratio %.2f", t.ratio)) }
        return p.joined(separator: " · ")
    }
    func keep() { m.control(t, "keep", ok: "Залишив собі: тепер у Transmission") }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(nice(t.name)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Tag(text: tv ? "ТВ" : "Transmission", fg: tv ? .purple : .secondary, bg: tv ? .purple.opacity(0.16) : .gray.opacity(0.18))
                Spacer(minLength: 4)
                HStack(spacing: 9) {
                    if tv { Button("Залишити собі") { keep() }.help("Перенести в Transmission: файл лишається, повторного скачування нема") }
                    else {
                        if canPause { Button { m.control(t, "pause") } label: { Image(systemName: "pause.fill") }.help("Пауза") }
                        if canResume { Button { m.control(t, "resume") } label: { Image(systemName: "play.fill") }.help("Продовжити") }
                        Button { m.openFiles(t) } label: { Image(systemName: "list.bullet") }.help("Файли")
                    }
                    Button { m.delFor = t } label: { Image(systemName: "trash") }.help("Видалити")
                }.buttonStyle(.borderless)
            }
            ProgressView(value: min(max(t.progress, 0), 1)).tint(tint)
            HStack { Text(left); Spacer(); Text(right) }.font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
        }.padding(.vertical, 4).help(t.name)
        .contextMenu {
            if tv { Button("Залишити собі") { keep() } }
            else {
                if canPause { Button("Пауза") { m.control(t, "pause") } }
                if canResume { Button("Продовжити") { m.control(t, "resume") } }
                Button("Файли") { m.openFiles(t) }
            }
            Divider()
            Button("Видалити") { m.control(t, "remove", ok: "Видалено зі списку") }
            Button("Видалити з файлами") { m.delFor = t }
        }
    }
}

struct DownloadsTab: View {
    @EnvironmentObject var m: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !m.torrentsErr.isEmpty {
                HStack(alignment: .top) { Image(systemName: "exclamationmark.triangle.fill"); Text(m.torrentsErr).font(.callout) }.foregroundStyle(.red)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading).background(.red.opacity(0.12), in: .rect(cornerRadius: 8))
                Spacer()
            } else if m.torrents.isEmpty {
                Spacer(); Text(m.torrentsLoaded ? "Немає завантажень.\nЗнайдіть реліз на вкладці «Пошук» і натисніть ↓." : "Читаю список…").multilineTextAlignment(.center)
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity); Spacer()
            } else {
                List(m.torrents) { TorRow(t: $0).listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4)) }
                    .listStyle(.plain).scrollContentBackground(.hidden)
            }
            Divider()
            HStack {
                Toggle("Тихий режим", isOn: Binding(get: { m.client?.alt_speed ?? false }, set: { m.setQuiet($0) })).toggleStyle(.switch).controlSize(.small)
                    .disabled(m.client == nil).help("Обмежує швидкість у Transmission (alt-speed)")
                Spacer()
                if let f = m.client?.free_gb { Text(String(format: "вільно %.0f ГБ", f)).font(.caption).foregroundStyle(.secondary) }
            }
        }.frame(maxHeight: .infinity)
    }
}

// MARK: in-panel sheets
// A system .sheet / .confirmationDialog is a second window: it takes the key status from the MenuBarExtra panel, and that panel
// closes when it loses it. So the file list and the delete question are cards drawn inside the panel itself.
struct Dim<C: View>: View {
    let close: () -> Void; @ViewBuilder let content: () -> C
    var body: some View {
        ZStack {
            Color.black.opacity(0.35).onTapGesture(perform: close)
            content().padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .windowBackgroundColor), in: .rect(cornerRadius: 12)).shadow(radius: 10).padding(16)
        }
    }
}

struct FilesCard: View {
    let t: Tor; @EnvironmentObject var m: Model
    var root: String {   // the folder every file sits in is shown once, not on every line
        let tops = m.files.compactMap { $0.name.split(separator: "/", maxSplits: 1).first.map(String.init) }
        guard let r = tops.first, tops.count == m.files.count, m.files.allSatisfy({ $0.name.hasPrefix(r + "/") }) else { return "" }
        return r + "/"
    }
    func bind(_ f: FileRow) -> Binding<Bool> { Binding(get: { m.wanted.contains(f.index) }, set: { if $0 { m.wanted.insert(f.index) } else { m.wanted.remove(f.index) } }) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Файли: " + nice(t.name)).font(.headline).lineLimit(2)
            if !m.filesLoaded { HStack { ProgressView().controlSize(.small); Text("Читаю список файлів…").foregroundStyle(.secondary) } }
            else if m.files.isEmpty { Text("Метадані ще не прийшли: списку файлів поки нема. Спробуйте за хвилину.").font(.callout).foregroundStyle(.secondary) }
            else {
                ScrollView { VStack(alignment: .leading, spacing: 6) { ForEach(m.files) { f in
                    Toggle(isOn: bind(f)) { HStack(spacing: 6) {
                        Text(String(f.name.dropFirst(root.count))).lineLimit(1).truncationMode(.middle).help(f.name); Spacer(minLength: 6)
                        Text(fmtBytes(f.size)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) } }.toggleStyle(.checkbox)
                } } }.frame(maxHeight: min(CGFloat(m.files.count) * 24 + 8, 330))
                if m.wanted.isEmpty { Text("Оберіть хоча б один файл").font(.caption).foregroundStyle(.orange) }
            }
            HStack {
                Button("Усі") { m.wanted = Set(m.files.map(\.index)) }.disabled(m.files.isEmpty); Button("Жодного") { m.wanted = [] }.disabled(m.files.isEmpty)
                Spacer()
                Button("Скасувати") { m.filesFor = nil }.keyboardShortcut(.cancelAction)
                Button("Зберегти") { m.saveFiles(t) }.keyboardShortcut(.defaultAction).disabled(m.files.isEmpty || m.wanted.isEmpty)
            }.controlSize(.small)
        }
    }
}

struct DelCard: View {
    let t: Tor; @EnvironmentObject var m: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Видалити «\(nice(t.name))»?").font(.headline).lineLimit(2)
            Text("«Лише зі списку» лишає файли на диску. «Разом з файлами» стирає і їх, це не можна скасувати.").font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Скасувати") { m.delFor = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Лише зі списку") { m.control(t, "remove", ok: "Видалено зі списку"); m.delFor = nil }
                Button("Разом з файлами") { m.control(t, "remove_data", ok: "Видалено разом з файлами"); m.delFor = nil }.foregroundStyle(.red)
            }.controlSize(.small)
        }
    }
}

struct Overlays: View {
    @EnvironmentObject var m: Model
    var body: some View {
        if let t = m.filesFor { Dim(close: { m.filesFor = nil }) { FilesCard(t: t) } }
        else if let t = m.delFor { Dim(close: { m.delFor = nil }) { DelCard(t: t) } }
    }
}

// MARK: panel
struct WinProbe: NSViewRepresentable {   // hands the panel's NSWindow to the model: the 2 s refresh runs only while it is visible
    let found: (NSWindow?) -> Void
    final class V: NSView { var found: ((NSWindow?) -> Void)?; override func viewDidMoveToWindow() { found?(window) } }
    func makeNSView(context: Context) -> V { let v = V(); v.found = found; return v }
    func updateNSView(_ v: V, context: Context) {}
}

struct ServerMenu: View {
    @EnvironmentObject var m: Model
    var body: some View {
        Menu {
            if let s = m.server {
                Button { m.switchServer(s.public_url ?? "") } label: { Label(s.name, systemImage: "checkmark") }
                if let ps = s.peers, !ps.isEmpty { Divider(); ForEach(ps, id: \.url) { p in Button(p.name) { m.switchServer(p.url) } } }
            } else { Button("Спробувати знову") { Task { await m.reload() } } }
        } label: { Label(m.server?.name ?? m.base.host ?? "сервер", systemImage: "server.rack") }
        .menuStyle(.borderlessButton).fixedSize().help("Сервер: \(m.base.absoluteString)")
    }
}

struct Panel: View {
    @EnvironmentObject var m: Model
    let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker("", selection: $m.tab) { Text("Пошук").tag(0); Text(m.active > 0 ? "Завантаження (\(m.active))" : "Завантаження").tag(1) }
                    .pickerStyle(.segmented).labelsHidden()
                ServerMenu()
            }
            if m.tab == 0 { SearchTab() } else { DownloadsTab() }
            if !m.toast.isEmpty { Text(m.toast).font(.callout).frame(maxWidth: .infinity).padding(6).background(.quaternary, in: .rect(cornerRadius: 6)) }
            HStack { if m.tab == 0 && m.job != nil { Button("← Останні") { m.job = nil } }; Spacer()
                Button("На телефоні") { NSWorkspace.shared.open(m.base.deletingLastPathComponent()) }; Button("Вийти") { NSApp.terminate(nil) } }.buttonStyle(.borderless).font(.caption)
        }
        .padding(12).frame(width: 460, height: 620)
        .overlay { Overlays() }
        .background(WinProbe { m.win = $0 })
        .task { await m.reload() }
        .onReceive(tick) { _ in if m.visible { Task { await m.tick() } } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { n in if (n.object as? NSWindow) === m.win { Task { await m.reload() } } }
        .onChange(of: m.tab) { _, _ in Task { await m.tick() } }
    }
}

// MARK: debug keys (like tinyTV --watch)
// --shot out.png "query" [--tv] [--tab 1] [--files] [--delete]: opens the panel in a window, searches, saves the window as PNG, quits.
// --selftest: runs the model's own requests against the server (read-only; the one write goes to a torrent id nobody has) and prints PASS/FAIL.
@MainActor func debugRun(_ m: Model) {
    let a = CommandLine.arguments
    if a.contains("--selftest") { Task { await selftest(m) }; return }
    guard let i = a.firstIndex(of: "--shot"), a.count > i + 2 else { return }
    let w = NSWindow(contentRect: .init(x: 200, y: 200, width: 460, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
    w.contentView = NSHostingView(rootView: Panel().environmentObject(m)); w.makeKeyAndOrderFront(nil)
    m.tab = Int(argValue("--tab") ?? "") ?? 0; m.q = a[i + 2]; m.tvOnly = a.contains("--tv"); m.search()
    Task { try? await Task.sleep(for: .seconds(5))
        if a.contains("--files"), let t = m.torrents.first(where: { $0.engine == "transmission" }) { m.openFiles(t) }
        if a.contains("--delete"), let t = m.torrents.first { m.delFor = t }
        try? await Task.sleep(for: .seconds(3))
        let s = Process(); s.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        s.arguments = ["-x", "-o", "-l\(w.windowNumber)", a[i + 1]]; try? s.run(); s.waitUntilExit(); NSApp.terminate(nil) }
}

@MainActor func selftest(_ m: Model) async {
    var bad = 0
    func chk(_ ok: Bool, _ s: String) { print(ok ? "PASS" : "FAIL", s); if !ok { bad += 1 } }
    print("base", m.base.absoluteString)
    await m.reload()
    chk(m.server != nil, "GET server -> \(m.server?.name ?? "nil") tv=\(m.server?.tv == true) peers=\((m.server?.peers ?? []).map(\.name)) public=\(m.server?.public_url ?? "-")")
    chk(m.torrentsLoaded, "GET torrents -> \(m.torrents.count) rows \(m.torrents.map { "\($0.id)/\($0.engine)/\($0.state)/\(Int($0.progress * 100))%" }) err='\(m.torrentsErr)'")
    chk(m.client != nil, "GET client -> alt_speed=\(m.client?.alt_speed == true) free_gb=\(m.client?.free_gb ?? -1)")
    chk(apiURL("https://h.ts.net:8444")?.absoluteString == "https://h.ts.net:8444/api/" && apiURL("http://127.0.0.1:8896/api/")?.absoluteString == "http://127.0.0.1:8896/api/" && apiURL("") == nil,
        "apiURL: server url -> <url>/api/, api url unchanged, empty -> nil")
    chk(enc("tr:12") == "tr%3A12" && enc("tv:" + String(repeating: "a", count: 40)).hasPrefix("tv%3Aaaaa"), "enc: ids go into the path as tr%3A12 / tv%3A<hash>")
    if let t = m.torrents.first(where: { $0.engine == "transmission" }) {
        let fs: [FileRow]? = try? await m.get("torrents/" + enc(t.id) + "/files")
        chk(fs != nil, "GET torrents/\(enc(t.id))/files -> \(fs.map { "\($0.count) files, wanted \($0.filter(\.wanted).count)" } ?? "failed")")
    } else { print("SKIP real files: no Transmission torrent in the list") }
    do { let _: [FileRow] = try await m.get("torrents/" + enc("tr:999999") + "/files"); chk(false, "files of tr:999999 must be a 404") }
    catch let e as ApiError { chk(e.msg == "Немає такого торента", "GET torrents/tr%3A999999/files -> 404 '\(e.msg)' (the id reached the server decoded)") }
    catch { chk(false, "files of tr:999999: \(error)") }
    // Model.send is the request behind every button. Ids nobody has: a no-op for tr:N, a readable 404 / 400 for tv:<hash>.
    func fake(_ id: String) -> Tor { try! JSONDecoder().decode(Tor.self, from: Data("{\"id\":\"\(id)\"}".utf8)) }
    let tr = fake("tr:999999"), tv = fake("tv:" + String(repeating: "a", count: 40))
    for a in ["pause", "resume", "remove", "remove_data"] { let e = await m.send(tr, a); chk(e == nil, "send tr:999999 \(a) -> \(e ?? "ok")") }
    let ef = await m.send(tr, "files", ["wanted": [1, 2], "unwanted": [0]]); chk(ef == nil, "send tr:999999 files {wanted [1, 2], unwanted [0]} -> \(ef ?? "ok")")
    let ek = await m.send(tv, "keep"); chk(ek == "Немає такого торента на рушії ТВ", "send tv:<hash> keep -> \(ek ?? "ok") (a tv: id reaches the server through %3A)")
    let ep = await m.send(tv, "pause"); chk(ep?.hasPrefix("Рушій ТВ цього не вміє") == true, "send tv:<hash> pause -> \(ep ?? "ok")")
    if let c = m.client {   // the same value again: proves the Bool body without changing «Тихий режим»
        let r = try? await m.post("client", ["alt_speed": c.alt_speed]); chk(r?["alt_speed"] as? Bool == c.alt_speed, "POST client {alt_speed: \(c.alt_speed)} (unchanged) -> alt_speed=\(r?["alt_speed"] ?? "nil")")
    }
    print(bad == 0 ? "SELFTEST OK" : "SELFTEST FAILED (\(bad))"); fflush(stdout); exit(bad == 0 ? 0 : 1)
}

@main struct TinySearchApp: App {
    @StateObject var m = Model()
    init() { let m = _m.wrappedValue; DispatchQueue.main.async { debugRun(m) } }
    var body: some Scene {
        MenuBarExtra("tinySearch", systemImage: "magnifyingglass.circle") { Panel().environmentObject(m) }.menuBarExtraStyle(.window)
    }
}
