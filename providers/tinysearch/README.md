# tinySearch - пошук торентів

- `searchd.py` - служба на tinyTV Core (launchd `dev.tinytv.searchd`, 127.0.0.1:8896, tailnet https :8444). Черга завдань,
  джерела паралельно, кожне не частіше разу на 10 с, кеш 10 хв, історія 60 пошуків у
  `~/Library/Application Support/tinySearch/jobs.json`, лог `~/Library/Logs/searchd.log`.
- `search.html` - сторінка телефону: https://<core-host>.<tailnet>.ts.net:8444 (на iPhone: Поділитись → На початковий екран).
- `mac/` - панель Мака tinySearch (SwiftUI, рядок меню). `mac/build.sh` ставить у ~/Applications.
  Налагодження: `tinySearch --shot out.png "запит" [--tv]` - шукає, знімає вікно, виходить.
- `tsearch.py` - симлінк на скіл `~/.agents/skills/torrent-search/scripts/tsearch.py` (одне джерело правди).
  Агенти: `tsearch.py "що" --job --from <імʼя>`.
- `deploy.sh` - копіює на tinyTV Core і перезапускає службу. Ядро tinyTV не чіпає.
- Джерела і доступ: `~/tinyTV/docs/torrent-sources.md`.
- `mcp.py` - коннектор MCP `tinysearch` для будь-якого агента: `POST /mcp` (Streamable HTTP, JSON, без сесій).
  Адреса в tailnet `https://<core-host>.<tailnet>.ts.net:8444/mcp`, на tinyTV Core `http://127.0.0.1:8896/mcp`.
  Інструменти: search, act, downloads, sources, recent. Підключено (2026-10-22): Claude Code, Codex і Antigravity на Маку;
  Claude Code, Codex і agent на tinyTV Core. agent бачить коннектор після перезапуску шлюзів.

## Торент-клієнт (2026-10-23)

- Встановити на будь-якому Маку: `cp config.example.json config.json`, поправити (`name`, `download_dir`, `engine`/`core`
  - null без ТВ, `peers`), `./install.sh`. Ставить Transmission 4.1.3 (brew; на tinyTV Core - `TDAEMON=~/bin/transmission-daemon`,
  бо brew там на зовнішньому диску), launchd `dev.tinytv.transmission` і `dev.tinytv.searchd`, tailnet https :8444.
- Модулі: `trclient.py` (Transmission RPC), `torrents.py` (один список: Transmission + рушій ТВ, «Залишити собі»),
  `group.py` (картки творів), `picker.py` (найкращий реліз), `hostcfg.py` (config.json).
- API: `/api/server`, `/api/torrents`, `/api/torrents/<id>/files`, `POST /api/torrents/add`, `POST /api/torrents/<id>`, `/api/client`.
- Тести: `/usr/bin/python3 -m unittest discover -s tests` (100). Деплой на tinyTV Core: `./deploy.sh` (перезапуск kickstart -k).
