// Remote mode (this Mac): the tinyTV core runs permanently on core host (MQTT, casting, media server, phone API).
// The menu bar app mirrors the core's /api/state once a second and sends every command to its API.
// Owner's decision 2026-10-20: "all media servers permanently on core host, not here".
import Foundation

@MainActor
final class Remote {
    static let shared = Remote()
    private var core: URL!
    private weak var tv: TV?
    private var timer: Timer?
    private(set) var uploading = false

    func start(_ core: URL, _ tv: TV) {
        self.core = core; self.tv = tv
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in Task { @MainActor in Remote.shared.poll() } }
    }

    private var inFlight = false
    private var misses = 0

    private func poll() {
        guard !inFlight, let core else { return }
        inFlight = true
        var r = URLRequest(url: core.appendingPathComponent("api/state")); r.timeoutInterval = 4
        URLSession.shared.dataTask(with: r) { d, _, _ in
            let o = d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            Task { @MainActor in Remote.shared.got(o) }
        }.resume()
    }

    private func got(_ o: [String: Any]?) {
        inFlight = false
        guard let o else {
            // core host unreachable: show the TV as unreachable instead of stale state.
            misses += 1
            if misses >= 3 { tv?.apply(["connected": false, "offline": true]); tv?.serverUp = false }
            return
        }
        misses = 0; tv?.serverUp = true
        tv?.apply(o)
        if let c = o["cast"] as? [String: Any] { Caster.shared.apply(c) }
        if let m = o["movie"] as? [String: Any], let on = m["on"] as? Bool { Caster.shared.applyMovie(on) }
        syncScreen()
    }

    // MARK: Mac screen -> core host relay

    private var capture: ScreenCapture?
    private var starting = false
    private var sent = ""   // screen|window|preset of the running capture

    /// The core says what it wants ("mac" + optional window); this Mac starts or stops sending.
    private func syncScreen() {
        let c = Caster.shared
        let want = c.screen.hasPrefix("mac")
        let key = "\(c.screen)|\(c.screenWindow.map(String.init) ?? "")|\(c.screenPreset)"
        if want, !starting, capture?.running != true || sent != key {
            capture?.stop()
            guard let ff = Caster.tool("ffmpeg") else { return c.uploadStatus("На цьому Mac немає ffmpeg", nil, failed: true) }
            let cap = ScreenCapture(); capture = cap; starting = true; sent = key
            let mode = ScreenCapture.Mode(rawValue: String(c.screen.split(separator: "-").dropFirst().first ?? "")) ?? .mirror
            let dest = TV.config["ingest"] ?? "\(core.host ?? "127.0.0.1"):8893"
            cap.onEnd = { err in Task { @MainActor in
                if let err { Caster.shared.uploadStatus("Показ екрана: \(err)", nil, failed: true) }
            } }
            Task {
                do { try await cap.start(window: c.screenWindow, mode: mode, preset: ScreenPreset.named(c.screenPreset), to: dest, ffmpeg: ff) }
                catch {
                    NSLog("tinyTV screen capture failed: %@", error.localizedDescription)
                    c.uploadStatus("Немає доступу до екрана: дозвольте запис екрана для tinyTV (Налаштування › Приватність)", nil, failed: true)
                    Remote.post("cast/stop")
                }
                starting = false
            }
        } else if !want, let cap = capture {
            cap.stop(); capture = nil
        }
    }

    /// Fire-and-forget command; the next poll shows the result.
    static func post(_ cmd: String, _ body: [String: Any] = [:]) {
        guard let core = shared.core else { return }
        var r = URLRequest(url: core.appendingPathComponent("api/" + cmd)); r.httpMethod = "POST"; r.timeoutInterval = 8
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: r) { d, _, _ in
            let o = d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            if let o { Task { @MainActor in Remote.shared.got(o) } }
        }.resume()
    }

    /// A file dropped on this Mac: stream it to core host (~/Movies/tinyTV), then the core casts it.
    func upload(_ file: URL) {
        guard let core, !uploading else { return }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0 else { return Caster.shared.uploadStatus("Не можу прочитати цей файл", nil, failed: true) }
        uploading = true
        Caster.shared.uploadStatus("Надсилаю на tinyTV Core…", 0)
        var r = URLRequest(url: core.appendingPathComponent("api/upload")); r.httpMethod = "POST"
        r.timeoutInterval = 3600
        r.setValue(file.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "file", forHTTPHeaderField: "X-Name")
        let delegate = UploadProgress()
        let task = URLSession.shared.uploadTask(with: r, fromFile: file) { _, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            Task { @MainActor in
                Remote.shared.uploading = false
                Caster.shared.uploadStatus(ok ? "" : "Не вдалося надіслати на tinyTV Core", nil, failed: !ok)
            }
        }
        task.delegate = delegate
        task.resume()
    }
}

private final class UploadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private var last = Date.distantPast
    func urlSession(_ s: URLSession, task: URLSessionTask, didSendBodyData _: Int64, totalBytesSent sent: Int64, totalBytesExpectedToSend total: Int64) {
        guard Date().timeIntervalSince(last) > 0.3, total > 0 else { return }
        last = Date()
        let p = Double(sent) / Double(total)
        Task { @MainActor in Caster.shared.uploadStatus("Надсилаю на tinyTV Core… \(Int(p * 100))%", p) }
    }
}
