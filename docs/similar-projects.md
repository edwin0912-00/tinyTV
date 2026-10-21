# Similar projects and what tinyTV takes from them

tinyTV is not a library server. It is a **remote plus a casting core for a TV that has no Chromecast or AirPlay**.

| Project | What it is | How tinyTV differs | Worth taking |
|---|---|---|---|
| Plex / Jellyfin | Library server + client apps on the TV | Needs an app on the TV; VIDAA has few. tinyTV pushes to the TV's own DLNA player and adds TV keys | Jellyfin's DLNA profiles per TV model (codec limits) |
| Kodi | Full media center on the playback device | tinyTV keeps the TV as it is and controls it from the phone | Kodi's JSON-RPC shape for a stable remote API |
| Stremio | Catalog + add-on protocol, plays in its own app | Same "add-on" idea, but tinyTV casts to a plain TV | **Add-on manifest over HTTP** for providers (catalog / meta / stream) |
| Popcorn Time | Torrent catalog + player, desktop | tinyTV streams on a server and casts; catalog is optional | Nothing new beyond sequential download |
| Seanime | Anime server, torrent streaming, Go | Anime-specific, plays in its own player | Debrid support as an optional provider; clear "does not host media" notice |
| TorrServer + Lampa | Torrent-to-HTTP server + TV web app | Lampa runs on the TV; tinyTV runs on the phone and pushes | TorrServer's HTTP API as an alternative engine backend |
| webtor (self-hosted) | Browser torrent streaming in Docker | Browser player vs TV casting | Docker packaging for the engine |
| go2tv | Cast files/URLs to DLNA, GUI + CLI, Go | Casting only; no remote, no torrents | Its DLNA quirks list and subtitle handling |
| castnow | CLI cast to Chromecast | Chromecast only | Keyboard controls idea for the CLI |
| hisensetv, ha_hisense_tv, Home_Assistant_Hisense_TV, hisense_vidaa | Hisense MQTT libraries / Home Assistant | tinyTV is a standalone app, not HA | Key and app lists per firmware; the cert extraction notes |

## Plan from this

1. Provider contract over HTTP, close to Stremio add-ons, so providers can live in other repos.
2. Engine interface so TorrServer can replace webtorrent.
3. DLNA profiles per TV (max bitrate, codecs, HDR) instead of one hard-coded profile.
4. Docker image for the engine and the Linux parts.

Sources: Jellyfin, Kodi, Stremio, Seanime (github.com/5rahim/seanime), TorrServer (github.com/YouROK/TorrServer),
webtor (github.com/webtor-io/self-hosted), go2tv (github.com/alexballas/go2tv), castnow,
hisensetv (hisensetv.readthedocs.io), ha_hisense_tv (github.com/sehaas/ha_hisense_tv),
Home_Assistant_Hisense_TV (github.com/tiagofreire-pt/Home_Assistant_Hisense_TV), hisense_vidaa (github.com/stevene1919/hisense_vidaa).
