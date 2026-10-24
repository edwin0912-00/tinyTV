# Changelog

## 0.3.1 - 2026-10-24

- Kino in a calmer, Apple Music-like look: plain rows, covers, large titles; red only for actions.
- Home: Continue (unfinished only), History, Bookmarks, Downloads; a fifth tab, Media.
- One voice list everywhere; real audio tracks of a release read from the file (engine `/tracks`).
- Search: recent searches and recently watched when empty; suggestions while typing.
- Watch on the iPhone: the tap unlocks the player, start at the right second, server stream on error;
  the lock-screen silent track no longer pauses the new video; the player reports its steps (`kino/clientlog`).
- Mac: the open player stays a panel above the tabs (full-screen player only on touch screens).
- Covers: a poster library with a fallback by IMDb id or title (`core/Posters.swift`).
- App icon for the Mac app and the home-screen page.

## 0.3.0 - 2026-10-24

- One-command install: `install.sh` (idempotent, `--dry-run`, never overwrites config; finds the TV by SSDP, port and MAC).
- Setup agent: `AGENTS.md` (also `CLAUDE.md`, `GEMINI.md`) and `skills/tinytv-setup` with a check for every step.
- LAN remote for the whole home Wi-Fi: `http://tinytv.local` (port 80, or 8897).
- Source sheet: picture and voice from different sources, aligned sound, planned switch ahead of the buffer.
- Release matching by episode and audio language, with tests (`tests/match.test.mjs`).
- Watch here on the Mac (small always-on-top window), on the phone; Kino dock and remote panel; bookmarks with resume.
- TV discovery by MAC after a router restart; media library; torrent keeper.
- tinySearch as an optional provider: search service, Transmission client, MCP connector.
- Public secret scan: `scripts/secret-scan.py`.

## 0.2.0 - 2026-10-21

- First open-source snapshot: core, remotes, engine; HDRezka and trackers as optional providers.
