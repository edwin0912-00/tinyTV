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
    /// Free-text search (music, series, software) across the indexes, no film-name filter.
    static var anySearch: ((String) async -> [[String: Any]])?
    /// One cheap index for the background "can this be watched" check in Discover (rate-limited by the core).
    /// Returns rows, or an error dictionary = "refused, try later" (not "no torrents").
    static var availabilityIndex: ((String, String) async -> Any)?
    /// Second index by the original title, when the first one has nothing.
    static var availabilityFallback: ((String) async -> [[String: Any]])?

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

    static func searchAny(_ q: String) async -> [[String: Any]] { await anySearch?(q) ?? [] }

    static func availability(title: String, original: String) async -> Any {
        await availabilityIndex?(title, original) ?? [[String: Any]]()
    }

    static func availabilityByOriginal(_ original: String) async -> [[String: Any]] { await availabilityFallback?(original) ?? [] }
}
