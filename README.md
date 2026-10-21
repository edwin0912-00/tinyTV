<p align="center"><img src="assets/cover.svg" alt="tinyTV" width="100%"></p>

# tinyTV

**One remote and media server for an ordinary TV.** [Українською ↓](#українською)

Smart TVs without Chromecast or AirPlay are hard to use: one remote for the TV, another app for YouTube, a USB stick for files, and no easy way to play a torrent. tinyTV puts one small server on an always-on Mac and turns your phone, your Apple Watch and your Mac menu bar into the remote for all of it.

> Screenshot placeholders: `docs/screenshots/phone-remote.png`, `docs/screenshots/kino.png`, `docs/screenshots/mac-panel.png`, `docs/screenshots/watch.png`

## What it does

| | |
|---|---|
| **TV keys** | Hisense VIDAA over its local MQTT broker (port 36669): keys, volume, power, apps, Wake-on-LAN |
| **Cast to any TV** | DLNA/UPnP to any TV that is a media renderer; the core serves files with HTTP Range |
| **Torrents** | Magnet or `.torrent` plays at once: sequential download from the TV's position, buffer gauge, GPU re-encode (VideoToolbox) when the stream is too heavy for the TV's Wi-Fi |
| **YouTube** | yt-dlp fetches video and sound in parallel, the core casts one file |
| **Files** | Movies on the core host, or dropped on the Mac panel |
| **Screen** | Mac or core screen on the TV (ScreenCaptureKit → h264), three latency modes |
| **Кіно / Discover** | History and "continue where you stopped" across sources; lists from IMDb datasets + Wikidata, posters from Wikipedia |
| **Remotes** | Phone web app (home screen), Now Playing on the lock screen and Apple Watch, Mac menu bar panel, Siri Shortcuts |

Catalog sources and torrent search are **not** part of the core. They are optional providers in [`providers/`](providers/README.md), off by default.

## How it fits together

```
 phone / watch / Mac panel / Siri  ──HTTP :8891──►  core (always-on Mac)  ──MQTT TLS :36669──►  Hisense VIDAA
                                                      │  media server :8892  ──DLNA────────────►  any DLNA TV
                                                      └─ engine (Node, webtorrent) :8890
```

Details: [ARCHITECTURE.md](ARCHITECTURE.md).

## Quick start

1. Find your TV and see what it can do:

   ```bash
   node scripts/tinytv-setup.mjs discover
   ```

2. Install the tools (ffmpeg, yt-dlp, Node deps). The script asks before it runs brew or apt:

   ```bash
   node scripts/tinytv-setup.mjs install
   ```

3. Write the config for the core host (`~/Library/Application Support/tinyTV/config.json`). Core: [config.core.example.json](config.core.example.json). A Mac remote: [config.remote.example.json](config.remote.example.json) (only `"core"`).
4. Hisense only: pair once. Follow [docs/hisense-pairing.md](docs/hisense-pairing.md). The certificate is not in this repo.
5. Build and run (macOS 14+, Xcode command line tools):

   ```bash
   scripts/build.sh
   ```

6. Start the torrent engine on the core host: `node engine/server.mjs`.
7. Open `http://<core-host>:8891/` on your phone and add it to the home screen.

Linux: the engine, DLNA casting and the web pages run. The Swift core and menu bar app are macOS only for now.

## Status

Personal project, used every day on one Hisense 55A56EEVS. Other VIDAA models and other DLNA TVs should work for casting; key control depends on the TV firmware. Issues and pull requests are welcome: [CONTRIBUTING.md](CONTRIBUTING.md).

---

## Українською

**Один пульт і медіасервер для звичайного ТВ.**

ТВ без Chromecast і AirPlay незручний: окремий пульт, окремий YouTube, флешка для файлів, і торент не відкрити. tinyTV ставить один маленький сервер на Мак, що завжди увімкнений. Телефон, Apple Watch і панель у рядку меню Мака стають пультом до всього.

**Що вміє**

1. Кнопки Hisense VIDAA через локальний MQTT (порт 36669): клавіші, гучність, живлення, Wake-on-LAN.
2. Трансляція DLNA на будь-який ТВ, що є медіарендерером.
3. Торенти: magnet грає одразу, буфер від секунди ТВ, перекодування на GPU для важких файлів.
4. YouTube через yt-dlp, локальні файли, екран Мака на ТВ.
5. «Кіно»: історія й «продовжити з того ж місця»; «Відкрити» зі списками IMDb і Wikidata.
6. Пульти: сторінка на телефоні, екран блокування й Apple Watch, панель Мака, Siri.

Джерела каталогів і пошук торентів не входять у ядро. Це окремі плагіни в `providers/`, вимкнені за замовчуванням.

**Швидкий старт**

1. `node scripts/tinytv-setup.mjs discover` - знайти ТВ.
2. `node scripts/tinytv-setup.mjs install` - поставити ffmpeg, yt-dlp і залежності.
3. Записати конфіг за зразком `config.core.example.json` (на Маку-пульті - `config.remote.example.json`).
4. Для Hisense: спарити за інструкцією `docs/hisense-pairing.md`.
5. `scripts/build.sh` - зібрати ядро й панель Мака.

---

MIT © Edwin Novak · Built with [Claude Code](https://claude.com/claude-code)
