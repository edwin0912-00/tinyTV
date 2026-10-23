// "Грати тут" on this Mac (owner 2026-10-22). Two planes: the core says what and from which second; the window
// plays the source itself (YouTube's HLS manifest, a direct link), core host HLS only as the fallback. The window acts
// like PiP: no title strip, always on top, the video's aspect, snaps to the Dock / top / sides with a spring;
// double click = full screen. The panel's mini card (WatchMini) controls it, so it never gets lost.
import AppKit
import AVKit
import SwiftUI

@MainActor
final class Watch: ObservableObject {
    static let shared = Watch()
    @Published var title = ""
    @Published var status = ""
    @Published var pos = 0.0   // the film's own seconds (1:1), not the stream's
    @Published var dur = 0.0
    @Published var playing = false
    @Published var active = false   // the window is open with something in it (the panel shows the mini card)
    let player = AVPlayer()
    private var want = true   // the viewer's own play/pause; a stall at the edge of a growing stream must not pause it
    private var from = 0.0, direct = false, timeObs: Any?, ticket: [String: Any] = [:], lastSave = Date.distantPast
    private var window: NSWindow?, snapping = false, moveEnd: DispatchWorkItem?
    private var base: String { TV.config["core"] ?? "http://127.0.0.1:8891" }

    /// The panel's "Тут": what the TV plays; a path (debug: --watch <file on tinyTV Core>) plays that file instead.
    func here(path: String? = nil) { request(path.map { $0.hasPrefix("http") ? ["page": $0] : ["path": $0] } ?? ["now": true]) }

    private func request(_ src: [String: Any]) {
        open(); status = "Готую…"
        let pip = CommandLine.arguments.contains("--pip")   // debug: start in the small form
        post("kino/here/start", src) { o in var o = o; o["src"] = src; if pip { o["pip"] = true }; Watch.shared.show(o) }
    }

    private func post(_ cmd: String, _ body: [String: Any], _ done: (@MainActor ([String: Any]) -> Void)? = nil) {
        var r = URLRequest(url: URL(string: base + "/api/" + cmd)!); r.httpMethod = "POST"; r.timeoutInterval = 150
        r.setValue("application/json", forHTTPHeaderField: "Content-Type"); r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: r) { d, _, _ in
            let o = d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? ["error": "Ядро недоступне"]
            nonisolated(unsafe) let reply = o
            Task { @MainActor in done?(reply) }
        }.resume()
    }

    /// A ticket from the core {direct | url, from, dur, title, key, src} or {error} (also from the Kino page).
    func show(_ r: [String: Any]) {
        open()
        if let e = r["error"] as? String { status = e; return }
        let d = r["direct"] as? String
        // Debug --force-fallback: the direct link fails on purpose, to test the core host HLS fallback.
        let dd = d != nil && CommandLine.arguments.contains("--force-fallback") ? "http://127.0.0.1:9/none.m3u8" : d
        guard let u = URL(string: dd ?? (base + (r["url"] as? String ?? ""))), d != nil || r["url"] != nil else { status = "Потік не готовий"; return }
        ticket = r; direct = d != nil
        title = r["title"] as? String ?? title; window?.title = title
        status = ""; from = direct ? 0 : r["from"] as? Double ?? 0; dur = r["dur"] as? Double ?? 0
        let start = r["from"] as? Double ?? 0
        player.replaceCurrentItem(with: AVPlayerItem(url: u))
        if direct, start > 5 { player.seek(to: CMTime(seconds: start, preferredTimescale: 600)) }
        player.play(); want = true; active = true
        setMini(r["pip"] as? Bool == true, animated: false)
        if timeObs == nil {
            timeObs = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { t in
                MainActor.assumeIsolated { Watch.shared.tick(t.seconds) }
            }
        }
        // The source did not open here in 8 s (e.g. a link tied to another IP): core host HLS instead.
        if direct, let src = r["src"] as? [String: Any] {
            let item = player.currentItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                guard self.player.currentItem === item, item?.status != .readyToPlay || self.player.currentTime().seconds < 0.5 else { return }
                self.status = "Напряму не вийшло, граю через tinyTV Core…"
                var s = src; s["hls"] = true; self.request(s)
            }
        }
    }

    private func tick(_ t: Double) {
        pos = from + t; playing = player.rate > 0
        // core host HLS still growing: AVPlayer stops at its edge and stays paused when new segments arrive.
        if want, !playing, let it = player.currentItem, it.status == .readyToPlay, it.isPlaybackLikelyToKeepUp { player.play() }
        if dur <= 0, let d = player.currentItem?.duration.seconds, d.isFinite { dur = d }
        if let w = window, small == nil, let size = player.currentItem?.presentationSize, size.width > 0, aspect != size {
            aspect = size
            w.contentAspectRatio = size
            var f = w.frame; f.size.height = f.width * size.height / size.width; w.setFrame(f, display: true); snap(animated: false)
        }
        // Control plane: the second goes back to the core every 10 s ("Продовжити" anywhere).
        guard playing, pos > 5, Date().timeIntervalSince(lastSave) > 10 else { return }
        lastSave = Date()
        if let id = ticket["rz"] as? String { post("kino/progress", ["id": id, "position": pos, "duration": dur]) }
        else if let h = ticket["hash"] as? String { post("kino/media/progress", ["hash": h, "position": pos, "duration": dur, "name": title]) }
        else if let k = ticket["key"] as? String ?? (ticket["path"] as? String).map({ "file:" + $0 }) {
            post("kino/media/progress", ["key": k, "position": pos, "duration": dur, "name": title]) }
    }

    func open() {
        if window == nil {
            let vf = NSScreen.main?.visibleFrame ?? .init(x: 0, y: 0, width: 1440, height: 900)
            let w = NSWindow(contentRect: .init(x: vf.maxX - 652, y: vf.minY + 12, width: 640, height: 360),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false; w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true; w.level = .floating; w.backgroundColor = .black
            // Like real PiP: on every desktop (Space), so it never stays behind on another one.
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.contentView = NSHostingView(rootView: WatchView(w: self))
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated { let s = Watch.shared; s.player.pause(); s.player.replaceCurrentItem(with: nil); s.active = false }
            }
            NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated { Watch.shared.moved() }
            }
            window = w
        }
        window?.title = title.isEmpty ? "tinyTV" : title
        front()
    }

    func front() { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }

    /// After a drag ends: pull to the nearest edge within 90 pt of the visible frame (Dock, menu bar excluded).
    private func moved() {
        guard !snapping, small == nil else { return }
        moveEnd?.cancel()
        let job = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if NSEvent.pressedMouseButtons != 0 { self.moved(); return }
            self.snap(animated: true)
        }
        moveEnd = job; DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: job)
    }

    private func snap(animated: Bool) {
        guard let w = window, !w.styleMask.contains(.fullScreen), let vf = (w.screen ?? NSScreen.main)?.visibleFrame else { return }
        let m: CGFloat = 12, pull: CGFloat = 90
        var f = w.frame
        if f.minX - vf.minX < pull { f.origin.x = vf.minX + m } else if vf.maxX - f.maxX < pull { f.origin.x = vf.maxX - f.width - m }
        if f.minY - vf.minY < pull { f.origin.y = vf.minY + m } else if vf.maxY - f.maxY < pull { f.origin.y = vf.maxY - f.height - m }
        guard f != w.frame else { return }
        guard animated else { w.setFrame(f, display: true); return }
        snapping = true
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.32; c.allowsImplicitAnimation = true
            c.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1)   // a snappy overshoot, like a magnet
            w.animator().setFrame(f, display: true)
        } completionHandler: { MainActor.assumeIsolated { Watch.shared.snapping = false } }
    }

    /// 1:1 seeking: direct sources and what the stream has made - a plain seek; further - the core restarts it there.
    func seek(_ at: Double) {
        let x = max(0, dur > 0 ? min(at, dur) : at)
        let have = player.currentItem?.seekableTimeRanges.last.map { $0.timeRangeValue.end.seconds } ?? 0
        if direct || (x >= from && x - from <= have - 2) { player.seek(to: CMTime(seconds: x - from, preferredTimescale: 600)); return }
        status = "Перемотую…"
        post("kino/phone/seek", ["at": Int(x)]) { o in var o = o; o["src"] = Watch.shared.ticket["src"]; Watch.shared.show(o) }
    }

    func toggle() { want = !playing; want ? player.play() : player.pause() }

    /// Double click: the whole screen and back, on this desktop (a native full-screen Space would leave the others).
    private var small: NSRect?
    func fill() {
        guard let w = window, let sc = w.screen ?? NSScreen.main else { return }
        let target = small ?? sc.frame
        if small == nil { small = w.frame; w.contentAspectRatio = .zero; w.level = .statusBar } else { small = nil; w.level = .floating }
        snapping = true
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.28; c.allowsImplicitAnimation = true
            c.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            w.animator().setFrame(target, display: true)
        } completionHandler: { MainActor.assumeIsolated { let s = Watch.shared; s.snapping = false; if s.small == nil { s.aspect = .zero } } }
    }
    private var aspect: NSSize = .zero

    weak var host: PlayerHost?
    /// One player, two forms (owner: "два вікна, нахуя?"): the normal window, or our own small floating screen
    /// top right (no window buttons). macOS's own PiP opened a second window and closing one closed both.
    @Published var mini = false
    func pip() { setMini(!mini, animated: true) }
    func setMini(_ on: Bool, animated: Bool) {
        guard let w = window, let vf = (w.screen ?? NSScreen.main)?.visibleFrame else { return }
        if small != nil { fill() }   // leave the full-screen form first
        mini = on
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach { w.standardWindowButton($0)?.isHidden = on }
        let ar = aspect.width > 0 ? aspect.height / aspect.width : 9.0 / 16
        let width: CGFloat = on ? 360 : 640, height = (width * ar).rounded()
        let f = on ? NSRect(x: vf.maxX - width - 12, y: vf.maxY - height - 12, width: width, height: height)
                   : NSRect(x: vf.maxX - width - 12, y: vf.minY + 12, width: width, height: height)
        snapping = true
        NSAnimationContext.runAnimationGroup { c in
            c.duration = animated ? 0.3 : 0; c.allowsImplicitAnimation = true
            c.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            w.animator().setFrame(f, display: true)
        } completionHandler: { MainActor.assumeIsolated { Watch.shared.snapping = false } }
    }
    func close() { window?.close() }
}

/// AVPlayerView draws the video; an AVPlayerLayer under it drives PiP from our own button (AVPlayerView has no start
/// call). Double click = full screen (owner).
final class PlayerHost: NSView {
    let view = AVPlayerView()
    init(player: AVPlayer) {
        super.init(frame: .zero); wantsLayer = true
        view.player = player; view.controlsStyle = .none; view.allowsPictureInPicturePlayback = false
        view.autoresizingMask = [.width, .height]; addSubview(view)
        let dbl = NSClickGestureRecognizer(target: self, action: #selector(full)); dbl.numberOfClicksRequired = 2
        view.addGestureRecognizer(dbl)
    }
    required init?(coder: NSCoder) { nil }
    override var mouseDownCanMoveWindow: Bool { true }
    override func layout() { super.layout(); view.frame = bounds }
    @objc private func full() { MainActor.assumeIsolated { Watch.shared.fill() } }
}

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> PlayerHost {
        let h = PlayerHost(player: player); Watch.shared.host = h; return h
    }
    func updateNSView(_ v: PlayerHost, context: Context) {}
}

/// Film-time scrubber shared by the window and the panel's mini card.
struct WatchBar: View {
    @ObservedObject var w: Watch
    var compact = false
    @State private var scrub: Double?
    var body: some View {
        HStack(spacing: compact ? 6 : 10) {
            Button { w.toggle() } label: {
                Image(systemName: w.playing ? "pause.fill" : "play.fill").font(.system(size: compact ? 11 : 14)).frame(width: 26, height: 26)
            }.buttonStyle(.plain)
            Text(clock(scrub ?? w.pos)).monospacedDigit()
            Slider(value: Binding(get: { scrub ?? w.pos }, set: { scrub = $0 }), in: 0...max(1, w.dur)) { editing in
                if !editing, let s = scrub { w.seek(s); scrub = nil }
            }
            .controlSize(compact ? .mini : .small)
            Text(w.dur > 0 ? clock(w.dur) : "").monospacedDigit()
        }
        .font(.system(size: compact ? 10 : 11))
    }
}

struct WatchView: View {
    @ObservedObject var w: Watch
    @State private var hover = false
    @State private var idle: DispatchWorkItem?

    var body: some View {
        PlayerView(player: w.player)
            .overlay { if !w.status.isEmpty { Text(w.status).font(.system(size: 13)).padding(10).background(.black.opacity(0.6), in: Capsule()) } }
            // Owner: no strip above the video - the controls appear on the video only while the pointer is on it.
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 6) {
                    Button { w.pip() } label: {
                        Image(systemName: w.mini ? "arrow.up.left.and.arrow.down.right" : "pip.enter").font(.system(size: 12, weight: .semibold)).padding(7).background(.black.opacity(0.55), in: Circle())
                    }
                    .buttonStyle(.plain).help(w.mini ? "У вікно" : "Малий екран (PiP)").accessibilityLabel(w.mini ? "Back to the window" : "Picture in Picture")
                    if w.mini {
                        Button { w.close() } label: {
                            Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).padding(8).background(.black.opacity(0.55), in: Circle())
                        }
                        .buttonStyle(.plain).help("Закрити").accessibilityLabel("Close")
                    }
                }
                .padding(8)
                .opacity(hover ? 1 : 0)
            }
            .overlay(alignment: .bottom) {
                WatchBar(w: w).foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 12).padding(.vertical, 6).background(.black.opacity(0.55), in: Capsule()).padding(10)
                    .opacity(hover || !w.playing ? 1 : 0)
            }
            .animation(.easeOut(duration: 0.2), value: hover)
            .onContinuousHover { p in
                if case .active = p { hover = true; idle?.cancel()
                    let j = DispatchWorkItem { hover = false }; idle = j; DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: j)
                } else { hover = false }
            }
            .ignoresSafeArea()
            .frame(minWidth: 320, minHeight: 180)
            .background(.black)
            .environment(\.colorScheme, .dark)
    }
}

/// The panel's card while the window plays (owner: "PiP губиться під вікнами"): pause, scrubber, show, PiP.
struct WatchMini: View {
    @ObservedObject var w = Watch.shared
    var body: some View {
        if w.active {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "macwindow").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(w.title).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { w.front() } label: { Image(systemName: "rectangle.on.rectangle").font(.system(size: 11)) }
                        .buttonStyle(.plain).help("Показати вікно").accessibilityLabel("Show the window")
                    Button { w.pip() } label: { Image(systemName: "pip.enter").font(.system(size: 11)) }
                        .buttonStyle(.plain).help("Малий екран (PiP)").accessibilityLabel("Picture in Picture")
                }
                WatchBar(w: w, compact: true)
            }
            .padding(10)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
