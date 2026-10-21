// Optional providers. The core never searches a third-party catalog or torrent index on its own:
// each provider lives in providers/<name>/, is OFF by default and is compiled in only when you build with
// PROVIDERS="hdrezka trackers" (build.sh adds -D PROVIDER_<NAME> and the provider's files).
// A provider fills these hooks at start; with none, "Кіно" keeps history, lists, Discover and downloads.
import Foundation

@MainActor
enum Providers {
    /// Torrent search: title (+ original title) -> rows {title, quality, size, seeds, peers, tracker, magnet|topic, hash}.
    static var torrentSearch: ((String, String) async -> [[String: Any]])?
    /// Tracker topic id -> magnet, for indexes that list a page instead of a magnet.
    static var magnetLookup: ((String) async -> String?)?
    /// One cheap index for the background "can this be watched" check in Discover (rate-limited by the core).
    static var availabilityIndex: ((String, String) async -> [[String: Any]])?

    static var enabled: [String] {
        var e: [String] = []
        #if PROVIDER_HDREZKA
        e.append("hdrezka")
        #endif
        #if PROVIDER_TRACKERS
        e.append("trackers")
        #endif
        return e
    }

    static func registerAll() {
        #if PROVIDER_TRACKERS
        Trackers.register()
        #endif
    }

    static var checksAvailability: Bool { !enabled.isEmpty }

    static func searchTorrents(title: String, original: String) async -> Any {
        guard let s = torrentSearch else { return ["error": "Torrent search is an optional provider (providers/trackers), not enabled", "items": []] }
        return await s(title, original)
    }

    static func magnet(topic: String) async -> String? { await magnetLookup?(topic) }

    static func availability(title: String, original: String) async -> [[String: Any]] {
        await availabilityIndex?(title, original) ?? []
    }
}
