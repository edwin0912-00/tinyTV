# Contributing

Thanks for helping. Small, focused pull requests are easiest to review.

1. Build both ways before you send a change:
   `scripts/build.sh` and `PROVIDERS="hdrezka trackers" scripts/build.sh`.
2. Run `node scripts/tinytv-setup.mjs check`.
3. Never commit certificates, tokens, IP addresses, host names or paths from your home (`.gitignore` blocks the usual files).
4. Third-party sites go in `providers/`, off by default, with the rules in `providers/README.md`
   (no bot-check bypass, at most one background request per 10 s per site).
5. Write comments that say why, and measured numbers when a choice came from a measurement.

New TV models: open an issue with the output of `node scripts/tinytv-setup.mjs discover` (remove your MAC addresses).
