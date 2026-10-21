# Optional providers

**Off by default.** The core build does not contain any provider code or address.
A provider is compiled in only when you name it:

```bash
PROVIDERS="trackers" scripts/build.sh
PROVIDERS="hdrezka trackers" scripts/build.sh
```

## Disclaimer

Providers talk to third-party websites that tinyTV does not run or control. Some of them index copyrighted
material. You decide whether to enable one, and you are responsible for what you search, stream or download and
for following the law and the site's terms where you live. tinyTV does not host, index or distribute media.

Rules every provider follows:

1. No bot-check, CAPTCHA or paywall bypass. When a site asks for one, the provider stops and reports it.
2. Background requests to one site: at most one per 10 seconds, with a long pause when the site starts refusing.
3. No accounts or passwords in the repo. A login, if any, stays in your own browser profile.

## Included

| Provider | Folder | Adds |
|---|---|---|
| `hdrezka` | `hdrezka/` | Кіно catalog: search, title pages, voiceovers, seasons, episodes, qualities; HDRezka links in "Open" |
| `trackers` | `trackers/` | Torrent search: jac.red, apibay, Knaben, and rutracker through your own logged-in Chrome (config `rutracker_chrome_profile`) |

## Writing a provider

Two shapes exist today:

1. **Index provider** (no state): fill the hooks in `core/Providers.swift` from a `register()` called by
   `Providers.registerAll()`:

   ```swift
   Providers.torrentSearch = { title, original in [[String: Any]] }   // rows: title, quality, size, seeds, peers, tracker, magnet|topic, hash
   Providers.magnetLookup = { topic in String? }
   Providers.availabilityIndex = { title, original in [[String: Any]] } // one cheap index for Discover
   ```

2. **Catalog provider**: an `extension Kino` with `func hdrezka(_ cmd:, _ b:) async -> Any?` style routing for the
   `kino/*` commands it serves; return `nil` for commands it does not own.

Next step (help welcome): replace the catalog extension with a `CatalogProvider` protocol
(`search`, `title`, `episodes`, `streams`, `find`) so several catalogs can live side by side, and move providers to
separate repos loaded at run time (a small HTTP contract instead of compile-time Swift).
