# Changelog

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
