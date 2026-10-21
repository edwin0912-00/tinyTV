// HDRezka -> TV. yt-dlp has no HDRezka extractor and the site shows a bot check ("Проверяем, что вы не бот!")
// to plain HTTP clients. So the page opens in our own WebKit view with persistent cookies: if the check appears,
// a small window shows it and the owner passes it once (we never solve it). Then the page's own player data gives
// the streams: "#h..." strings padded with base64 junk, decoded below into "[1080p]url or url,[720p]...".
import AppKit
import WebKit

@MainActor
final class Rezka: NSObject, WKNavigationDelegate {
    static let shared = Rezka()
    static func handles(_ s: String) -> Bool { URL(string: s)?.host?.contains("rezka") == true }

    private var web: WKWebView?
    private var window: NSWindow?
    private var done: ((Result<(url: String, title: String), Error>) -> Void)?
    private var poll: Timer?

    struct Failure: LocalizedError { let errorDescription: String? }

    /// Resolves an HDRezka page (with #t:..-s:..-e:.. for a series episode) to the best direct stream URL.
    func resolve(_ link: String, _ completion: @escaping (Result<(url: String, title: String), Error>) -> Void) {
        poll?.invalidate()
        done = completion
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()   // keeps the bot-check cookie between uses
        let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 680), configuration: cfg)
        w.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        w.navigationDelegate = self
        web = w
        guard let u = URL(string: link) else { return finish(.failure(Failure(errorDescription: "Bad link"))) }
        w.load(URLRequest(url: u))
        // Give up after 2 minutes (e.g. the check was never passed).
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            if self?.done != nil { self?.finish(.failure(Failure(errorDescription: "HDRezka didn't load"))) }
        }
    }

    func webView(_ w: WKWebView, didFinish _: WKNavigation!) { Task { await inspect() } }

    private func inspect() async {
        guard let w = web else { return }
        if (w.title ?? "").contains("не бот") || (w.title ?? "").lowercased().contains("captcha") {
            showCheck()
            poll?.invalidate()
            poll = .scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in await self?.inspect() } }
            return
        }
        poll?.invalidate(); poll = nil
        window?.orderOut(nil)
        // Runs inside the page: same origin and cookies, so the episode request works like the site's own player.
        let js = """
        const html = document.documentElement.outerHTML;
        const title = (document.querySelector('.b-post__title h1') || {}).textContent || document.title;
        const init = html.match(/initCDN(Movies|Series)Events\\(\\s*(\\d+)\\s*,\\s*(\\d+)\\s*,\\s*(\\d+)?\\s*,?\\s*(\\d+)?/);
        const h = location.hash.match(/t:(\\d+)-s:(\\d+)-e:(\\d+)/);
        let streams = null;
        if (h && init) {
          const body = new URLSearchParams({id: init[2], translator_id: h[1], season: h[2], episode: h[3], action: 'get_stream'});
          const r = await fetch('/ajax/get_cdn_series/?t=' + Date.now(), {method: 'POST', body,
            headers: {'Content-Type': 'application/x-www-form-urlencoded', 'X-Requested-With': 'XMLHttpRequest'}});
          const j = await r.json(); streams = j.url || null;
        }
        if (!streams) { const m = html.match(/"streams":"((?:[^"\\\\]|\\\\.)*)"/); if (m) streams = JSON.parse('"' + m[1] + '"'); }
        return {streams, title: title.trim()};
        """
        do {
            let r = try await w.callAsyncJavaScript(js, contentWorld: .page) as? [String: Any]
            guard let raw = r?["streams"] as? String, let best = Rezka.best(Rezka.decode(raw)) else {
                return finish(.failure(Failure(errorDescription: "No stream on that HDRezka page")))
            }
            finish(.success((best, r?["title"] as? String ?? "HDRezka")))
        } catch {
            NSLog("tinyTV rezka script error: %@ | title: %@", String(describing: error), w.title ?? "")
            finish(.failure(Failure(errorDescription: "HDRezka page script failed")))
        }
    }

    private func showCheck() {
        guard window == nil || window?.isVisible == false, let w = web else { return }
        let win = window ?? NSWindow(contentRect: w.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "HDRezka — pass the check once"
        win.contentView = w
        win.isReleasedWhenClosed = false
        win.center(); win.level = .floating
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }

    private func finish(_ r: Result<(url: String, title: String), Error>) {
        poll?.invalidate(); poll = nil
        window?.orderOut(nil)
        let d = done; done = nil
        web?.stopLoading(); web = nil
        d?(r)
    }

    /// "#h" + base64 with "//_//" separators and base64 of 2-3 char junk from @#!^$ inserted. Strip, then decode.
    static func decode(_ s: String) -> String {
        guard s.hasPrefix("#h") else { return s }
        var t = String(s.dropFirst(2)).replacingOccurrences(of: "//_//", with: "")
        let junk = ["@", "#", "!", "^", "$"]
        var codes: [String] = []
        for a in junk { for b in junk {
            codes.append(Data((a + b).utf8).base64EncodedString())
            for c in junk { codes.append(Data((a + b + c).utf8).base64EncodedString()) }
        } }
        for c in codes { t = t.replacingOccurrences(of: c, with: "") }
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// "[360p]a or b,[1080p Ultra]c or d" -> highest quality, preferring the plain .mp4 (seekable) over the HLS one.
    static func best(_ list: String) -> String? {
        let items = list.split(separator: ",").compactMap { part -> (Int, String)? in
            guard let close = part.firstIndex(of: "]") else { return nil }
            let q = Int(part[part.index(after: part.startIndex)..<close].prefix { $0.isNumber }) ?? 0
            let urls = part[part.index(after: close)...].components(separatedBy: " or ").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let u = urls.first(where: { $0.hasSuffix(".mp4") }) ?? urls.first, u.hasPrefix("http") else { return nil }
            return (q + (part.contains("Ultra") ? 1 : 0), u)
        }
        return items.max { $0.0 < $1.0 }?.1
    }
}
