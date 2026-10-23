---
name: tinytv-setup
description: Set up or repair a tinyTV home install - the core host Mac, the TV (Hisense VIDAA pairing, Wake-on-LAN, Wi-Fi/DFS, static DHCP), the LAN and Tailscale remote, the torrent engine and the optional tinySearch/Transmission and HDRezka providers. Use when someone installs tinyTV, when the TV or remote "does not work", or after a router or TV change.
---

# tinyTV setup

Work from the repo root. Each step: run the **check** first. If it already passes, skip the step.
Never guess: show the command output in your answer. Ask the owner before anything in **[ask]**.

## 0. What the owner wants

Ask once: which Mac is the always-on core host; TV model; Hisense keys wanted (needs a certificate) or casting only;
remote outside home (Tailscale) yes/no; optional providers (hdrezka, trackers, tinysearch) yes/no.
Defaults: this Mac, casting + keys, LAN only, no providers.

## 1. Machine and tools

- Check: `./install.sh --dry-run`
- Expected: lines 1-2 all `✓`; no `✗`.
- Fix: missing tools -> **[ask]** then `./install.sh` (it asks before `brew install`). No Xcode tools ->
  `xcode-select --install`, wait, run again. `✗ This Mac is a remote` -> this Mac is configured as a remote:
  install on the core host instead (or `--force` if the owner moves the core here).

## 2. Find the TV

- Check: `node scripts/tinytv-setup.mjs discover`
- Expected: the TV with its IP; Hisense shows `MQTT :36669 open`.
- Nothing found:
  1. TV on and on the same network as the core host? `ping -c2 <TV-IP>` from the router's client list.
  2. SSDP blocked (macOS Local Network permission, guest/isolated Wi-Fi): the script falls back to a /24 scan of
     port 36669; casting-only TVs need SSDP - allow Local Network for Terminal/node in System Settings -> Privacy.
  3. TV in ARP but no port answers -> TV network services dead: TV menu -> Network -> reconnect. Check again.
- Then: `node scripts/tinytv-setup.mjs config --write` (creates config.json with `tv` and `tv_mac` only if missing).
- Check: `cat ~/Library/Application\ Support/tinyTV/config.json` has `tv` and `tv_mac`.

## 3. Keep the TV reachable [ask: router changes]

- Static DHCP lease: TV MAC (`tv_mac`) and the core host MAC -> fixed IPs in the router. Check: after a router
  restart `arp -n <TV-IP>` still shows the TV MAC.
- 5 GHz channel: not DFS (use 36-48). Check: TV reachable for an hour (`nc -z -G 2 <TV-IP> 36669` every few minutes).
- TV menu: network standby / Wake on LAN ON; sleep timer OFF if the owner wants the TV always controllable.
- Wake-on-LAN check (TV in standby, nothing playing): `curl -s -X POST localhost:8891/api/power` then within ~5 s
  `nc -z -G 2 <TV-IP> 36669` succeeds. After a long power cut a TV may need one press of its power button.

## 4. Hisense pairing [ask: the owner must read the PIN from the TV]

- Check: `curl -s localhost:8891/api/state` -> `"connected": true`. If true, skip.
- Steps: docs/hisense-pairing.md (certificate is the owner's to obtain; never commit it), then `./install.sh --pair`;
  write the PIN shown on the TV into `~/.tinytv/pin.txt` when asked; make `remotenow.p12` as the doc says.
- Expected after a core restart (`launchctl kickstart -k gui/$UID/dev.tinytv.core`): `"connected": true`, volume value.
- Only one client id per TV: stop any other core using the same `client_id`.

## 5. Services

- Run: `./install.sh` (idempotent; never overwrites config.json).
- Check: `launchctl print gui/$UID/dev.tinytv.core | grep state` and `.../dev.tinytv.tvcast` -> `running`;
  `curl -s localhost:8891/api/state`, `curl -s localhost:8890/state` -> JSON.
- Logs: `~/Library/Logs/tinyTVCore.log`, `~/Library/Logs/tvcast.log`.

## 6. Remotes

- LAN: `curl -s -o /dev/null -w '%{http_code}' http://tinytv.local/` -> `200` (or `:8897` if port 80 was taken).
  Phone: open `http://tinytv.local/`, Share -> Add to Home Screen. Watch: control from the lock-screen Now Playing.
- Mac remote (another Mac): install only the menu bar app, config `{"core": "http://<core-host>.local:8891"}`.
- Tailscale [ask]: Tailscale on the core host and the phone, then `./install.sh --tailscale`.
  Check: `tailscale serve status` lists `:8443`; the phone opens `https://<core>.<tailnet>.ts.net:8443/` on cellular.

## 7. Optional providers [ask: legal disclaimer in providers/README.md]

- Build with them: `./install.sh --with hdrezka,trackers` (Swift providers) and/or `--with tinysearch`.
- tinySearch check: `curl -s localhost:8896/api/server` -> JSON; `python3 providers/tinysearch/tsearch.py "big buck bunny"`
  lists rows. Transmission RPC stays on 127.0.0.1:9091.
- HDRezka: background at most one request per 10 s; a bot check (Anubis/"Проверяем, что вы не бот") means wait -
  never automate or bypass it. Premium qualities without an account give a 60 s preview only.

## 8. Hand back

Report: each step's check output (one line each), what you changed, what the owner must still do (e.g. pairing PIN).
Run before any commit: `node tests/match.test.mjs`, `(cd providers/tinysearch && python3 -m unittest discover -s tests)`,
`scripts/build.sh`, and the secret scan from CONTRIBUTING.md.
