# tinyTV - setup and troubleshooting guide for coding agents

This file has three names (AGENTS.md, CLAUDE.md, GEMINI.md): one text for every agent.
Full step-by-step skill: [skills/tinytv-setup/SKILL.md](skills/tinytv-setup/SKILL.md).

## What you are working on

- **Core host:** an always-on Mac. Runs `tinyTVCore.app` (LaunchAgent `dev.tinytv.core`, API :8891, media :8892,
  screen relay :8893, TV page :8895, LAN remote :80 or :8897 as `tinytv.local`) and the torrent engine
  (`dev.tinytv.tvcast`, `engine/server.mjs`, :8890). Optional: tinySearch (`dev.tinytv.searchd` :8896, Transmission :9091).
- **Remotes:** phone pages, Apple Watch through the phone's Now Playing, the Mac menu bar app (config `"core"`), Siri.
- **TV:** any DLNA renderer for casting; Hisense VIDAA also gets keys over MQTT TLS :36669 (client certificate + PIN).
- Architecture: [ARCHITECTURE.md](ARCHITECTURE.md). Install: `./install.sh` (`--dry-run` first).

## Rules

1. Never change the TV while something plays on it unless the owner asked. Check: `curl -s localhost:8891/api/state`;
   `"cast".title` empty = idle.
2. One MQTT client id per TV (`client_id` in config). A second core with the same id kicks the first one off.
3. Third-party sites (HDRezka, trackers): at most one background request per site per 10 s; never bypass Cloudflare,
   Anubis or CAPTCHA; no paid APIs. A bot check = stop and tell the owner.
4. Never commit certificates, `config.json`, `kino.json`, tokens, host names, IPs or MACs. Run the secret scan in
   CONTRIBUTING.md before every commit.
5. Measure before you conclude: every check below has a command and an expected result. Report the numbers.
6. Ask before: `brew install`, rebooting the router or TV, changing router settings, Tailscale serve, pairing.

## Quick diagnosis (run in this order; stop at the first failing line)

| # | Check | Command | Expected |
|---|---|---|---|
| 1 | Core runs | `launchctl print gui/$UID/dev.tinytv.core \| grep state` | `state = running` |
| 2 | Core answers | `curl -s -m 3 localhost:8891/api/state \| head -c 200` | JSON with `"connected"` |
| 3 | Engine answers | `curl -s -m 3 localhost:8890/state \| head -c 100` | JSON |
| 4 | TV on the network | `node scripts/tinytv-setup.mjs discover` | the TV with its IP |
| 5 | TV ports | `nc -z -G 2 <TV-IP> 36669` | `succeeded` |
| 6 | TV MAC matches config | `arp -n <TV-IP>` | the `tv_mac` from config.json |
| 7 | Keys paired | `/api/state` | `"connected": true` |
| 8 | LAN remote | `curl -s -o /dev/null -w '%{http_code}' http://tinytv.local/` | `200` |

## Known failures (symptom -> cause -> fix -> check)

- **TV answers ARP but no port (ping and 36669 silent):** the TV's network services are dead, often after a router
  restart or Wi-Fi drop. Some routers answer ARP for absent hosts (proxy ARP), so ARP alone proves nothing.
  Fix: on the TV, Settings -> Network -> reconnect (or reset network). Check: row 5 succeeds.
- **TV gets a new address after a router restart:** the core finds it again by MAC, then by port 36669. Lasting fix:
  a static DHCP lease for the TV MAC and the core host in the router. Check: `arp -n` shows the same IP after a restart.
- **TV drops off Wi-Fi and does not come back:** 5 GHz on a DFS channel (52-144) makes clients leave on radar events.
  Fix: pin the router's 5 GHz channel to 36-48. Check: the TV stays reachable for an hour.
- **Wake-on-LAN does not wake the TV:** enable network standby / Wake on LAN in the TV menu; send WoL from the core
  host (same LAN), to both MACs (Wi-Fi and Ethernet). After a long power cut some TVs need one press of the power button.
- **"TLS needs a client certificate":** pairing not done. Follow docs/hisense-pairing.md, then `./install.sh --pair`.
- **Picture stutters on big files:** the TV's Wi-Fi is the limit (measured ~48 Mbit/s on a 55A56EEVS). The core
  re-encodes above ~36 Mbit/s on the GPU; check ffmpeg has `hevc_videotoolbox` (`node scripts/tinytv-setup.mjs check`).
- **The TV cannot open HTTPS links itself:** everything goes through the core over plain HTTP on the LAN. Expected.
- **Remote not reachable outside home:** Tailscale on the core host, then `./install.sh --tailscale`
  (publishes https :8443 -> :8891). Check: `tailscale serve status` lists 8443.
- **tinySearch:** `curl -s localhost:8896/api/server` returns JSON; Transmission RPC only on 127.0.0.1:9091.
  Logs: `~/Library/Logs/searchd.log`.
- **HDRezka provider:** "bot check" = wait (the core retries at most once per 2 min, only on an action); premium
  qualities without an account give only 60 s of video. Never automate the check.

## Code map

`core/` Swift core · `remote/web/` phone pages (served live from the app's Resources) · `remote/mac/` menu bar app ·
`engine/` torrent engine · `providers/` optional sources (off by default) · `scripts/` build, deploy, setup, pairing ·
`tests/` (`node tests/match.test.mjs`) · `providers/tinysearch/tests` (`python3 -m unittest discover -s tests`).
Build both ways before you hand back: `scripts/build.sh` and `PROVIDERS="hdrezka trackers" scripts/build.sh`.
