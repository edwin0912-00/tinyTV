// Movie light: while something cast plays, the room light (any HTTP light bridge, config "light_url") dims; on pause or stop it comes back.
// Off by default; the owner turns it on (change the light only when the user asks).
// The light is never switched on by this: if it was off, it stays off.
import Foundation

@MainActor
final class MovieLight {
    static let shared = MovieLight()
    static let dimTo = 3                      // percent while playing
    var on = UserDefaults.standard.bool(forKey: "movieLight") { didSet { UserDefaults.standard.set(on, forKey: "movieLight"); if !on { raise() } } }
    /// The light before dimming. Saved on disk: a core restart between dim and pause once left the light at 3 %.
    private var saved: (brightness: Int, scheduleWasRunning: Bool)? {
        get {
            guard let d = UserDefaults.standard.dictionary(forKey: "movieLightSaved"), let b = d["b"] as? Int else { return nil }
            return (b, d["s"] as? Bool ?? false)
        }
        set {
            if let n = newValue { UserDefaults.standard.set(["b": n.brightness, "s": n.scheduleWasRunning], forKey: "movieLightSaved") }
            else { UserDefaults.standard.removeObject(forKey: "movieLightSaved") }
        }
    }
    private var pending: Task<Void, Never>?
    private(set) var lastError = ""

    private var base: URL? { TV.config["light_url"].flatMap(URL.init(string:)) }

    /// Called on every play/pause/stop change; acts once the state holds for 2 s (start-up flickers through states).
    func castChanged(playing: Bool) {
        guard on else { return }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            if playing { await dim() } else { raise() }
        }
    }

    private func dim() async {
        guard saved == nil, let st = await get("state"), st["on"] as? Bool == true,
              let b = (st["brightness"] as? NSNumber)?.intValue, b > MovieLight.dimTo else { return }
        let sched = await get("schedule")
        saved = (b, sched?["enabled"] as? Bool == true && sched?["paused_until"] is NSNull)
        await call("set?brightness=\(MovieLight.dimTo)")
    }

    private func raise() {
        guard let s = saved else { return }
        saved = nil
        Task {
            await call("set?brightness=\(s.brightness)")
            // The schedule paused when we dimmed; let it lead again if it was leading before.
            if s.scheduleWasRunning { await call("schedule/resume") }
        }
    }

    private func request(_ path: String) -> URLRequest? {
        guard let base, let u = URL(string: base.absoluteString + "/" + path) else { return nil }
        var r = URLRequest(url: u); r.timeoutInterval = 45
        if let t = TV.config["light_auth"] { r.setValue(t.hasPrefix("Bearer ") ? t : "Bearer " + t, forHTTPHeaderField: "Authorization") }
        return r
    }

    private func get(_ path: String) async -> [String: Any]? {
        guard let r = request(path), let (d, _) = try? await URLSession.shared.data(for: r) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    /// One call, no retries (bridge rule 7): an error is reported in the state.
    private func call(_ path: String) async {
        guard let r = request(path) else { return }
        let resp = try? await URLSession.shared.data(for: r)
        let code = (resp?.1 as? HTTPURLResponse)?.statusCode ?? 0
        lastError = code == 200 ? "" : "Light bridge error \(code)"
        if code != 200 { NSLog("tinyTV movie light: %@ -> %d", path, code) }
    }
}
