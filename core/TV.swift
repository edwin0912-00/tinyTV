// TV model: state from the Hisense VIDAA broker and every command the panel sends.
import SwiftUI
import AppKit

struct TVApp: Identifiable, Hashable { let id: String, name: String, url: String }
struct TVSource: Identifiable, Hashable { let id: String, name: String, signal: Bool }
struct Shortcut: Identifiable, Codable, Hashable { var id = UUID(); var name: String; var url: String }

@MainActor
final class TV: ObservableObject {
    static let shared = TV()
    @Published var connected = false
    /// True once a connection attempt failed: the TV is off, asleep or unreachable.
    @Published var offline = false
    @Published var volume: Double = 0 { didSet { if !syncing { debounce("vol") { [unowned self] in
        if core != nil { return Remote.post("volume", ["v": volume.rounded()]) }
        publish(ps + "actions/changevolume", String(Int(volume.rounded()))) } } } }
    @Published var nowPlaying = ""
    /// Kino series on the TV (from the core): which episode steps exist, for the panel's ⏮ / ⏭.
    @Published var episode: (prev: Bool, next: Bool)? = nil
    /// Last DLNA player state from the TV broadcast: start / play / pause / stop, "" when another source shows.
    var dlnaPlaystate = ""
    /// Title of the media the DLNA player reports (our DIDL dc:title).
    var dlnaName = ""
    @Published var apps: [TVApp] = []
    @Published var sources: [TVSource] = []
    /// Picture menu values by menu_id (measured on 55A56EEVS: 2 mode, 3 brightness, 4 contrast, 5 colour, 8 backlight).
    @Published var picture: [Int: Double] = [:]
    @Published var shortcuts: [Shortcut] = [] { didSet {
        guard core != nil else { return saveShortcuts() }
        guard !syncing else { return }
        for s in shortcuts where !oldValue.contains(where: { $0.id == s.id }) { Remote.post("shortcut", ["name": s.name, "url": s.url]) }
        for s in oldValue where !shortcuts.contains(where: { $0.id == s.id }) { Remote.post("shortcut/delete", ["id": s.id.uuidString]) }
    } }
    @Published var lastKey = ""

    let host: String
    /// Set on a remote (this Mac): the tinyTV core runs permanently on the core host and every command goes to its API.
    let core: URL?
    nonisolated static let config: [String: String] = {
        let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/tinyTV/config.json")
        return (try? Data(contentsOf: u)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
    }()
    private let cid = TV.config["client_id"] ?? "tinytv_core"   // must match the id used when pairing (scripts/pair.py)
    private var ui: String { "/remoteapp/tv/ui_service/\(cid)/" }
    private var ps: String { "/remoteapp/tv/platform_service/\(cid)/" }
    private var remote: String { "/remoteapp/tv/remote_service/\(cid)/" }
    private var mqtt: MQTT?
    private let server = PhoneServer()
    private var syncing = false
    private var lastLocalEdit = Date.distantPast
    private var timers: [String: DispatchWorkItem] = [:]

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/tinyTV")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cfg = TV.config
        host = cfg["tv"] ?? "192.168.0.2"   // set "tv" in config.json (scripts/tinytv-setup.mjs finds it)
        core = cfg["core"].flatMap(URL.init(string:))
        Caster.shared.tv = self
        if let core {
            // Remote: no MQTT here (one client id = one connection), no servers; mirror the core's state.
            Remote.shared.start(core, self)
            // Debug: --open URL sends a link as if pasted into the panel.
            if let i = CommandLine.arguments.firstIndex(of: "--open"), i + 1 < CommandLine.arguments.count {
                let u = CommandLine.arguments[i + 1]
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.open(u) }
            }
            return
        }
        loadShortcuts()
        // The TV accepts only the legacy static login with the RemoteNOW cert (measured 2026-10-20).
        let mqtt = MQTT(host: host, clientID: cid, user: "hisenseservice", pass: "multimqttservice")
        mqtt.onState = { [weak self] ok in Task { @MainActor in self?.stateChanged(ok) } }
        mqtt.onMessage = { [weak self] t, d in Task { @MainActor in self?.handle(t, d) } }
        mqtt.connect()
        self.mqtt = mqtt
        if !CommandLine.arguments.contains("--do"), !CommandLine.arguments.contains("--selftest") { server.start() }
        if let i = CommandLine.arguments.firstIndex(of: "--do"), CommandLine.arguments.dropFirst(i + 1).first == "power" {
            // Waking must not wait for a connection that only exists once the TV is awake.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in NSLog("tinyTV do power (offline path)"); power() }
        }
    }

    private func stateChanged(_ ok: Bool) {
        withAnimation(.easeOut(duration: 0.25)) { connected = ok; offline = !ok }
        guard ok else { return }
        mqtt?.subscribe("/remoteapp/mobile/#")
        refresh()
        // Debug: --do open:URL | --do keys:KEY_A,KEY_B (0.5 s apart), then quit.
        if let i = CommandLine.arguments.firstIndex(of: "--do"), i + 1 < CommandLine.arguments.count {
            let cmd = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
                if cmd.hasPrefix("open:") { NSLog("tinyTV do open %@", String(cmd.dropFirst(5))); open(String(cmd.dropFirst(5))) }
                if cmd == "capture" { MouseBridge.shared.tv = self; MouseBridge.shared.start(); NSLog("tinyTV capture started") }
                if cmd.hasPrefix("pic:") {  // pic:8=90
                    let p = cmd.dropFirst(4).split(separator: "=")
                    if p.count == 2, let id = Int(p[0]), let v = Double(p[1]) { NSLog("tinyTV do pic %d=%f", id, v); setPicture(id, v) }
                }
                if cmd.hasPrefix("keys:") {
                    for (n, k) in cmd.dropFirst(5).split(separator: ",").enumerated() {
                        DispatchQueue.main.asyncAfter(deadline: .now() + Double(n) * 0.5) { [self] in NSLog("tinyTV do key %@", String(k)); key(String(k)) }
                    }
                }
            }
        }
        if CommandLine.arguments.contains("--selftest") {
            // Volume +1 then back: proves the command path end to end via the TV's volumechange echo.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
                let v = Int(volume.rounded()); NSLog("tinyTV selftest volume %d -> %d", v, v + 1)
                publish(ps + "actions/changevolume", String(v + 1))
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
                    NSLog("tinyTV selftest volume back -> %d", v); publish(ps + "actions/changevolume", String(v))
                }
            }
        }
    }

    func refresh() {
        if core != nil { return Remote.post("refresh") }
        publish(ps + "actions/getvolume")
        publish(ui + "actions/sourcelist")
        publish(ui + "actions/applist")
        publish(ps + "actions/picturesetting", #"{"action":"get_menu_info"}"#)
    }

    private func publish(_ t: String, _ p: String = "") { mqtt?.publish(t, p) }

    private func debounce(_ k: String, _ f: @escaping () -> Void) {
        lastLocalEdit = Date()
        timers[k]?.cancel()
        let w = DispatchWorkItem(block: f); timers[k] = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: w)
    }

    // MARK: incoming

    private func handle(_ topic: String, _ data: Data) {
        if CommandLine.arguments.contains("--trace") { NSLog("tinyTV < %@ %@", topic, String(decoding: data.prefix(160), as: UTF8.self)) }
        guard let j = try? JSONSerialization.jsonObject(with: data) else { return }
        let fresh = Date().timeIntervalSince(lastLocalEdit) > 1.5  // never fight a slider being dragged
        syncing = true; defer { syncing = false }
        if topic.hasSuffix("volumechange"), fresh, let d = j as? [String: Any],
           (d["volume_type"] as? Int) == 0, let v = d["volume_value"] as? Double {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { volume = v }
        } else if topic.hasSuffix("ui_service/data/sourcelist"), let a = j as? [[String: Any]] {
            sources = a.compactMap { s in (s["sourceid"] as? String).map {
                TVSource(id: $0, name: (s["displayname"] as? String) ?? (s["sourcename"] as? String) ?? $0,
                         signal: (s["is_signal"] as? String) == "1") } }
        } else if topic.hasSuffix("ui_service/data/applist"), let a = j as? [[String: Any]] {
            apps = a.compactMap { s in (s["appId"] as? String).map {
                TVApp(id: $0, name: s["name"] as? String ?? $0, url: s["url"] as? String ?? "") } }
        } else if topic.hasSuffix("data/picturesetting"), fresh, let d = j as? [String: Any],
                  let items = d["menu_info"] as? [[String: Any]] {
            var p = picture
            for it in items where (it["menu_value_type"] as? String) == "int" {
                if let id = it["menu_id"] as? Int, let v = it["menu_value"] as? Double { p[id] = v }
            }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { picture = p }
        } else if topic.hasSuffix("ui_service/state"), let d = j as? [String: Any] {
            // The TV says when a pushed video really runs: drives the consent-dialog auto-accept.
            if (d["statetype"] as? String) == "mediadlna" { dlnaPlaystate = d["playstate"] as? String ?? ""; dlnaName = d["name"] as? String ?? "" }
            else if (d["statetype"] as? String) == "sourceswitch" { dlnaPlaystate = "" }
            let n = (d["statetype"] as? String) == "input" ? "" : (d["name"] as? String ?? "")
            if n != nowPlaying { withAnimation(.easeOut(duration: 0.3)) { nowPlaying = n } }
        }
    }

    // MARK: commands

    /// Remote mode: mirror the core's /api/state without echoing it back as commands.
    func apply(_ o: [String: Any]) {
        syncing = true; defer { syncing = false }
        let ok = o["connected"] as? Bool ?? false
        if ok != connected || offline != (o["offline"] as? Bool ?? !ok) {
            withAnimation(.easeOut(duration: 0.25)) { connected = ok; offline = o["offline"] as? Bool ?? !ok }
        }
        if Date().timeIntervalSince(lastLocalEdit) > 1.5, let v = o["volume"] as? Double, v != volume { volume = v }
        let k = o["kino"] as? [String: Any] ?? [:]
        let ep = k["season"] == nil ? nil : (prev: k["hasPrev"] as? Bool ?? false, next: k["hasNext"] as? Bool ?? false)
        if ep?.prev != episode?.prev || ep?.next != episode?.next || (ep == nil) != (episode == nil) { episode = ep }
        if let n = o["nowPlaying"] as? String, n != nowPlaying { withAnimation(.easeOut(duration: 0.3)) { nowPlaying = n } }
        let a = (o["apps"] as? [[String: Any]] ?? []).compactMap { d in (d["id"] as? String).map { TVApp(id: $0, name: d["name"] as? String ?? $0, url: "") } }
        if a != apps { apps = a }
        let src = (o["sources"] as? [[String: Any]] ?? []).compactMap { d in
            (d["id"] as? String).map { TVSource(id: $0, name: d["name"] as? String ?? $0, signal: d["signal"] as? Bool ?? false) } }
        if src != sources { sources = src }
        let sc = (o["shortcuts"] as? [[String: Any]] ?? []).compactMap { d -> Shortcut? in
            guard let id = (d["id"] as? String).flatMap(UUID.init(uuidString:)), let n = d["name"] as? String, let u = d["url"] as? String else { return nil }
            return Shortcut(id: id, name: n, url: u) }
        if sc != shortcuts { shortcuts = sc }
        if Date().timeIntervalSince(lastLocalEdit) > 1.5, let p = o["picture"] as? [String: Double] {
            let m = Dictionary(uniqueKeysWithValues: p.compactMap { k, v in Int(k).map { ($0, v) } })
            if m != picture { picture = m }
        }
    }

    /// Snapshot for the phone remote.
    func stateJSON() -> Data {
        let o: [String: Any] = [
            "connected": connected, "offline": offline, "host": host, "volume": Int(volume.rounded()),
            "nowPlaying": nowPlaying,
            "apps": apps.map { ["id": $0.id, "name": $0.name] },
            "sources": sources.map { ["id": $0.id, "name": $0.name, "signal": $0.signal] },
            "picture": Dictionary(uniqueKeysWithValues: picture.map { (String($0.key), Int($0.value.rounded())) }),
            "shortcuts": shortcuts.map { ["id": $0.id.uuidString, "name": $0.name, "url": $0.url] },
            "kino": Caster.shared.remote ? [:] : Kino.shared.state(),
            "cast": ["status": Caster.shared.status, "progress": Caster.shared.progress ?? -1.0 as Double, "failed": Caster.shared.failed,
                     "title": Caster.shared.title, "playing": Caster.shared.playing,
                     "position": Caster.shared.displayPosition,
                     "sound": ["preset": Caster.shared.sound.preset, "custom": Caster.shared.sound.custom, "bands": Caster.shared.sound.bands],
                     "video": ["mode": Caster.shared.video.mode, "height": Caster.shared.video.height,
                               "hdr": Caster.shared.video.hdr, "mbps": Caster.shared.video.mbps],
                     "tracks": Caster.shared.tracks.map { ["i": $0.i, "label": $0.label] }, "track": Caster.shared.track, "duration": Caster.shared.duration,
                     "screen": Caster.shared.screen, "screenWindow": Int(Caster.shared.screenWindow ?? UInt32.max) == Int(UInt32.max) ? -1 : Int(Caster.shared.screenWindow!),
                     "screenLatency": Caster.shared.screenLatency, "screenPreset": Caster.shared.screenPreset,
                     "torrent": Caster.shared.title.isEmpty ? [:] : Caster.shared.torrent],
            "movie": ["on": MovieLight.shared.on, "error": MovieLight.shared.lastError],
        ]
        return (try? JSONSerialization.data(withJSONObject: o)) ?? Data("{}".utf8)
    }

    /// Power: MQTT when the TV is awake, Wake-on-LAN when it sleeps (TV reports network_wakeup=1).
    func power() {
        if core != nil { return Remote.post("power") }
        if connected { key("KEY_POWER"); return }
        // config "tv_mac": the TV's MAC addresses (Wi-Fi, Ethernet), comma-separated hex; scripts/tinytv-setup.mjs prints them.
        for mac in (TV.config["tv_mac"] ?? "").split(separator: ",") { wake(mac.replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespaces)) }
    }

    private func wake(_ hex: String) {
        let m = stride(from: 0, to: 12, by: 2).map { i -> UInt8 in
            UInt8(hex[hex.index(hex.startIndex, offsetBy: i)..<hex.index(hex.startIndex, offsetBy: i + 2)], radix: 16)! }
        let pkt = [UInt8](repeating: 0xff, count: 6) + (0..<16).flatMap { _ in m }
        let fd = socket(AF_INET, SOCK_DGRAM, 0); guard fd >= 0 else { return }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        let parts = host.split(separator: ".")
        for dst in ["255.255.255.255", parts.count == 4 ? "\(parts[0]).\(parts[1]).\(parts[2]).255" : "255.255.255.255"] {
            var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_port = in_port_t(9).bigEndian
            inet_pton(AF_INET, dst, &a.sin_addr)
            _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, pkt, pkt.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
    }

    func key(_ k: String) {
        if core != nil { lastKey = k; return Remote.post("key", ["key": k]) }
        publish(remote + "actions/sendkey", k)
        lastKey = k
    }

    func setPicture(_ id: Int, _ v: Double) {
        picture[id] = v
        debounce("pic\(id)") { [unowned self] in
            if core != nil { return Remote.post("picture", ["id": id, "v": v]) }
            publish(ps + "actions/picturesetting",
                    #"{"action":"notify_value_changed","menu_id":\#(id),"menu_value":"\#(Int(v.rounded()))"}"#)
        }
    }

    func launch(_ app: TVApp, url: String? = nil) {
        if core != nil { return Remote.post("launch", ["id": app.id]) }
        let u = url ?? app.url
        let p: [String: Any] = ["appId": app.id, "name": app.name, "url": u, "urlType": 37,
                                "appName": app.name, "appUrl": u]
        publish(ui + "actions/launchapp", json(p))
    }

    func source(_ s: TVSource) {
        if core != nil { return Remote.post("source", ["id": s.id]) }
        publish(ui + "actions/changesource", json(["sourceid": s.id, "sourcename": s.name]))
    }

    /// Sends a link to the TV: the Mac fetches the video and the TV plays it over DLNA (see Cast.swift).
    func open(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        // magnet:, file paths and full URLs pass as they are; a bare domain gets https://
        if !s.contains(":"), !s.hasPrefix("/") { s = "https://" + s }
        // Optional HDRezka provider: resolve the page to a direct stream (WebKit), then cast that.
#if PROVIDER_HDREZKA
        if Rezka.handles(s) {
            Rezka.shared.resolve(s) { [weak self] r in
                switch r {
                case .success(let v): if MQTT.trace { NSLog("tinyTV rezka -> %@", v.url) }; self?.open(v.url)
                case .failure(let e): NSLog("tinyTV rezka failed: %@", e.localizedDescription)
                }
            }
            return
        }
#endif
        if core != nil {
            // A file on this Mac goes up to the core host first; links are fetched by the core itself.
            if s.hasPrefix("/") || s.hasPrefix("file://") { return Remote.shared.upload(URL(fileURLWithPath: s.hasPrefix("file://") ? (URL(string: s)?.path ?? s) : s)) }
            return Remote.post("open", ["url": s])
        }
        Caster.shared.tv = self
        Caster.shared.cast(s)
    }

    func type(_ text: String) {
        if core != nil { return Remote.post("type", ["text": text]) }
        publish(ps + "actions/txtinputdata", json(["text": text, "action": "insert"]))
    }

    func toast(_ m: String) {
        publish(ui + "actions/showmessage", json(["message": m, "title": "tinyTV", "duration": 3, "type": "notify"]))
    }

    private func json(_ o: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self)
    }

    // MARK: shortcuts

    private var shortcutsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/tinyTV/shortcuts.json")
    }

    private func loadShortcuts() {
        if let d = try? Data(contentsOf: shortcutsURL), let s = try? JSONDecoder().decode([Shortcut].self, from: d) {
            shortcuts = s
        } else {
            let ip = TV.macIP() ?? "127.0.0.1"
            shortcuts = [Shortcut(name: "TV Cast", url: "http://\(ip):8890/play"),
                         Shortcut(name: "YouTube", url: "https://www.youtube.com/tv")]
        }
    }

    private func saveShortcuts() {
        if let d = try? JSONEncoder().encode(shortcuts) { try? d.write(to: shortcutsURL) }
    }

    static func macIP() -> String? {
        var ifa: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifa) == 0 else { return nil }
        defer { freeifaddrs(ifa) }
        var p = ifa
        while let i = p {
            if String(cString: i.pointee.ifa_name) == "en0", i.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                var h = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(i.pointee.ifa_addr, socklen_t(i.pointee.ifa_addr.pointee.sa_len), &h, socklen_t(h.count), nil, 0, NI_NUMERICHOST)
                return String(cString: h)
            }
            p = i.pointee.ifa_next
        }
        return nil
    }
}

// MARK: - Mouse bridge: the Mac pointer drives the TV while captured.

@MainActor
final class MouseBridge: ObservableObject {
    static let shared = MouseBridge()
    @Published var active = false
    /// Visual offset of the virtual pointer inside the pad, springs back to centre.
    @Published var nudge: CGSize = .zero
    @Published var lastDir = ""
    weak var tv: TV?
    private var monitors: [Any] = []
    private var acc = CGSize.zero
    private let step: CGFloat = 40   // points of motion per arrow press
    private var idle: Timer?
    private var lastSend = Date.distantPast
    /// True while a TV Cast page holds the pointer stream: deltas go to its real cursor, not arrow keys.
    @Published var cursorMode = false
    private let pointerURL = URL(string: (TV.config["tvcast"] ?? "http://127.0.0.1:8890") + "/pointer")!
    private var pending = CGSize.zero, pendingClicks = 0, inFlight = false
    private var flushTimer: Timer?, probeTimer: Timer?

    func start() {
        guard !active else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { active = true }
        // Pin the real cursor where it was clicked (on the pad): it must not wander over the screen unseen.
        anchor = CGEvent(source: nil)?.location ?? .zero
        CGEventSource(stateID: .combinedSessionState)?.localEventsSuppressionInterval = 0
        CGAssociateMouseAndMouseCursorPosition(0)
        CGDisplayHideCursor(CGMainDisplayID())
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] e in
            self?.handle(e) ?? true ? nil : e
        } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] e in _ = self?.handle(e) } as Any)
        probe()
        probeTimer = .scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.probe() } }
        flushTimer = .scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in Task { @MainActor in self?.flush() } }
        touch()
    }

    /// Releases the pointer by itself after 15 s without input.
    private func touch() {
        idle?.invalidate()
        idle = .scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in Task { @MainActor in self?.stop() } }
    }

    func stop() {
        guard active else { return }
        monitors.forEach { NSEvent.removeMonitor($0) }; monitors.removeAll()
        CGWarpMouseCursorPosition(anchor)
        CGAssociateMouseAndMouseCursorPosition(1)
        CGDisplayShowCursor(CGMainDisplayID())
        acc = .zero
        probeTimer?.invalidate(); flushTimer?.invalidate(); idle?.invalidate(); probeTimer = nil; flushTimer = nil
        pending = .zero; pendingClicks = 0; cursorMode = false
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { active = false; nudge = .zero }
    }

    /// Returns true when the event is consumed.
    private var anchor = CGPoint.zero
    private var skipMoves = 0

    private func handle(_ e: NSEvent) -> Bool {
        touch()
        // The system can re-associate the cursor (another app, a menu): put it back every time.
        if let p = CGEvent(source: nil)?.location, hypot(p.x - anchor.x, p.y - anchor.y) > 1 {
            CGWarpMouseCursorPosition(anchor)
            CGAssociateMouseAndMouseCursorPosition(0)
            // The warp shows up as a jump back in the next event's delta: that read as an arrow the other way.
            skipMoves = 2
            return true
        }
        if skipMoves > 0, [.mouseMoved, .leftMouseDragged].contains(e.type) { skipMoves -= 1; return true }
        switch e.type {
        case .keyDown:
            if e.keyCode == 53 { stop() }            // Esc or a right click releases the pointer
            else if e.keyCode == 36 { send("KEY_OK") }
            else if e.keyCode == 51 { send("KEY_RETURNS") }
            return true
        case .leftMouseDown:
            if cursorMode { pendingClicks += 1; flush() } else { send("KEY_OK") }
            pulse(); return true
        case .rightMouseDown: stop(); return true
        case .scrollWheel:
            // Follow the fingers: with natural scrolling (inverted) the delta already has the finger's sign.
            let k: CGFloat = e.isDirectionInvertedFromDevice ? 0.6 : -0.6
            move(e.scrollingDeltaX * k, e.scrollingDeltaY * k); return true
        default: move(e.deltaX, e.deltaY); return true
        }
    }

    private func move(_ dx: CGFloat, _ dy: CGFloat) {
        if cursorMode { pending.width += dx; pending.height += dy; return }
        // Clamp: a fast flick never queues a burst of presses, it gives at most one step.
        acc.width = max(-step * 1.2, min(step * 1.2, acc.width + dx))
        acc.height = max(-step * 1.2, min(step * 1.2, acc.height + dy))
        guard Date().timeIntervalSince(lastSend) > 0.11, abs(acc.width) >= step || abs(acc.height) >= step else { return }
        let horiz = abs(acc.width) > abs(acc.height)
        let k = horiz ? (acc.width > 0 ? "KEY_RIGHT" : "KEY_LEFT") : (acc.height > 0 ? "KEY_DOWN" : "KEY_UP")
        acc = .zero
        send(k)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        // A short nudge in the direction of the press, then back to centre.
        let d: CGFloat = 14
        withAnimation(.spring(response: 0.18, dampingFraction: 0.7)) {
            nudge = CGSize(width: horiz ? (k == "KEY_RIGHT" ? d : -d) : 0, height: horiz ? 0 : (k == "KEY_DOWN" ? d : -d))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { self?.nudge = .zero }
        }
    }

    private func send(_ k: String) {
        lastSend = Date()
        tv?.key(k)
        withAnimation(.easeOut(duration: 0.15)) { lastDir = k }
    }

    /// TV Cast relay: is a /play page listening? Keeps checking while captured.
    private func probe() {
        URLSession.shared.dataTask(with: pointerURL) { [weak self] d, _, _ in
            let n = d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["clients"] as? Int ?? 0
            Task { @MainActor in
                guard let self, self.active, (n > 0) != self.cursorMode else { return }
                withAnimation(.easeOut(duration: 0.2)) { self.cursorMode = n > 0 }
            }
        }.resume()
    }

    /// Sends coalesced deltas and clicks, one request in flight at a time (~60 Hz).
    private func flush() {
        guard cursorMode, !inFlight, pending != .zero || pendingClicks > 0 else { return }
        var lines: [String] = []
        if pending != .zero { lines.append(String(format: "m %.1f %.1f", pending.width, pending.height)) }
        lines += Array(repeating: "c", count: pendingClicks)
        pending = .zero; pendingClicks = 0; inFlight = true
        var r = URLRequest(url: pointerURL); r.httpMethod = "POST"; r.timeoutInterval = 1
        r.httpBody = lines.joined(separator: "\n").data(using: .utf8)
        URLSession.shared.dataTask(with: r) { [weak self] _, _, err in
            Task { @MainActor in
                guard let self else { return }
                self.inFlight = false
                if err != nil { self.cursorMode = false }   // server gone: fall back to arrow keys
            }
        }.resume()
    }

    private func pulse() { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
}
