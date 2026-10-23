# tinySearch (optional provider, off by default)

A torrent search service plus a real torrent client (Transmission) for the core host:

- `searchd.py` - Python stdlib service on 127.0.0.1:8896: a job queue, all sources in parallel, **each source at most
  once per 10 s**, 10 min cache, history of 60 searches. Phone page `search.html`, Mac menu bar panel `mac/`.
- `mcp.py` - an MCP connector (`POST /mcp`, tools search / act / downloads / sources / recent) so a coding agent can search
  and queue downloads on your core.
- `trclient.py`, `torrents.py` - Transmission RPC and one list for Transmission + the TV engine ("keep for me").
- `tsearch.py` - CLI client: `python3 tsearch.py "what" --job --from <agent name>`.

Install only if you want it: `node scripts/tinytv-setup.mjs` does **not** install it unless you pass `--with tinysearch`
to `./install.sh`. Manual: `cp config.example.json config.json`, edit, `./install.sh` (Transmission via brew, LaunchAgents
`dev.tinytv.transmission` and `dev.tinytv.searchd`, optional Tailscale https :8444).

Disclaimer: the sources are third-party sites. You are responsible for what you search and download and for the law where
you live. No Cloudflare, Anubis or CAPTCHA bypass; no paid APIs. Tests: `python3 -m unittest discover -s tests`.
