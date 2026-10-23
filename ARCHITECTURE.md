# Architecture

tinyTV has two sides: one **core** that does the work, and many **remotes** that only send commands.

## Core (always-on Mac; parts run on Linux)

| Part | Folder | Port | Job |
|---|---|---|---|
| `tinyTVCore.app` | `core/` | 8891 | Phone API (`/api/*`), pages `/`, `/kino`; state for every remote |
| MQTT client | `core/MQTT.swift`, `core/TV.swift` | → TV 36669 | Hisense VIDAA keys, volume, apps. TLS with a client certificate. One client id at a time |
| Media server | `core/Server.swift` | 8892 | Files, HLS and transcodes for the TV with HTTP Range |
| Casting | `core/Cast.swift` | DLNA | SetAVTransportURI / Play / Seek; ffmpeg decides copy vs encode (VideoToolbox) |
| Screen relay | `core/Screen.swift` | 8893 | MPEG-TS in from a Mac or the core itself, out to the TV from the last keyframe |
| TV page | `core/LowLatency.swift` | 8895 | A page opened once in the TV browser for lower-latency playback |
| Кіно store | `core/Kino.swift` | - | History, lists, positions per film, Discover queue |
| LAN remote | `core/Server.swift` | 80 / 8897 | The same API and pages for the home Wi-Fi, announced as `tinytv.local` (dns-sd) |
| Source mixing | `core/audiosync.py`, `core/switchplan.py` | - | Voice from one source on the picture of another: offset/tempo map from shared music and effects; planned switch at a future point ahead of the buffer |
| Torrent keeper | `core/keeper.py` | - | Deletes watched temporary torrents (>= 90 %) unless kept |
| Media library | `core/Kino.swift` (`Library`) | - | Videos on the core's disks matched to IMDb titles |
| Discover | `core/discover.py` | - | IMDb datasets + Wikidata + Wikipedia posters, stdlib only |
| Torrent engine | `engine/server.mjs` | 8890 | webtorrent; sequential pieces from the TV's position, buffer state, background downloads |
| Providers hooks | `core/Providers.swift` | - | Empty unless a provider is compiled in |

## Remotes (send commands, keep no state)

| Remote | Folder | Talks to |
|---|---|---|
| Phone web app | `remote/web/phone.html`, `kino.html` | core :8891 |
| Lock screen and Apple Watch | `remote/web/np.js` (Media Session) | the phone page |
| Mac menu bar | `remote/mac/TinyTVApp.swift` | core :8891 (`"core"` in config) |
| Watch here | `remote/mac/Watch.swift` | plays the TV's source in a small always-on-top window |
| LAN | any browser at `http://tinytv.local` | core :80 |
| Siri | `docs/siri.md` (Shortcuts → HTTP) | core :8891 |

## Data flow: a magnet

1. A remote posts the magnet to `/api/open`.
2. The core hands it to the engine (`/add`) and polls `/state` every second.
3. When the buffer from the TV's position is enough, the core probes the stream (ffprobe).
4. Light stream: DLNA plays the engine URL as is. Heavy stream (above the TV's Wi-Fi): ffmpeg re-encodes on the GPU into the media server.
5. Position goes back to the Кіно store, so "continue" works from any remote.

## Install and setup

`install.sh` (idempotent) builds, installs the apps to `~/Applications/tinyTV`, writes LaunchAgents
`dev.tinytv.core` and `dev.tinytv.tvcast` only when they change, and creates `config.json` only when it is missing.
`AGENTS.md` and `skills/tinytv-setup/SKILL.md` guide a coding agent through the TV, network and services.

## Optional providers

Providers live in `providers/<name>/` and are compiled in only with `PROVIDERS="<name>" scripts/build.sh`.
They fill hooks in `core/Providers.swift` (torrent search, free-text search, magnet lookup, availability) or extend `Kino`
(catalog commands; `catalogStreams` gives a voice to the Source sheet). `tinysearch` is a separate service
(`providers/tinysearch`, installed with `install.sh --with tinysearch`). The core never calls a third-party catalog or index on its own. See [providers/README.md](providers/README.md).

## Config

`~/Library/Application Support/tinyTV/config.json` on each machine. Examples: [core](config.core.example.json), [remote](config.remote.example.json). A config with `"core"` makes that machine a remote.
Secrets (the TV client certificate, tokens) stay outside the repo; `.gitignore` blocks the usual names.
