#!/usr/bin/python3
"""Sync a dub from another source to a film's video: offset and tempo from the shared music and effects.

  audiosync.py map    VIDEO VTRACK AUDIO ATRACK DURATION        -> {"ratio", "segments": [{"t", "c"}]}
  audiosync.py verify VIDEO VTRACK AUDIO ATRACK DURATION MAP [EVERY]  -> errors over the whole film
  audiosync.py align  VIDEO VTRACK DUB DTRACK OUT.ac3 STATUS.json [WORK_DIR]
      -> OUT.ac3 (raw CBR AC3: frame k at byte k * frame) grows ahead of the player: the dub cut and shifted onto the video's seconds, AC3 for the TV.
         STATUS.json: {"state": "sync|ready|done|error", "until": rendered video second, "ratio", "segments"}.

Model: the dub at second s plays with the video at second t, s = ratio * t + c (c per segment: cuts differ).
ratio 1.04271 = a 25 fps (PAL) dub against 23.976 fps video. Sources are files or http(s) URLs.
"""
import json, subprocess, sys, os, time
import numpy as np

FS = 8000
FF = os.path.expanduser("~/tinyTV/tools/bin/ffmpeg")
# 1, PAL speed-up (25 / 23.976) and back, 24 / 23.976 and back, 25 / 24 and back.
RATIOS = [1.0, 25 / (24000 / 1001), (24000 / 1001) / 25, 24 / (24000 / 1001), (24000 / 1001) / 24, 25 / 24, 24 / 25]


def pcm(src, track, start, dur):
    """Mono 8 kHz float samples of [start, start + dur]; zeros before 0 and after the end."""
    lead = max(0.0, -start)
    start, dur = max(0.0, start), dur - lead
    n = int(round((dur + lead) * FS))
    if dur <= 0:
        return np.zeros(n, np.float32)
    cmd = [FF, "-hide_banner", "-loglevel", "error", "-nostdin"]
    if src.startswith("http"):
        cmd += ["-reconnect", "1", "-reconnect_streamed", "1", "-rw_timeout", "20000000"]
    cmd += ["-ss", f"{start:.3f}", "-i", src, "-t", f"{dur:.3f}", "-map", f"0:a:{track}", "-ac", "1", "-ar", str(FS), "-f", "f32le", "-"]
    try:   # a torrent part not downloaded yet: no reference here, the offset stays
        raw = subprocess.run(cmd, capture_output=True, timeout=30 if src.startswith("http") else 180).stdout
    except subprocess.TimeoutExpired:
        raw = b""
    x = np.frombuffer(raw, np.float32)
    out = np.zeros(n, np.float32)
    k = int(round(lead * FS))
    out[k:k + len(x)] = x[:n - k]
    return out


def dub(src, track, t0, dur, ratio, offset):
    """The dub mapped onto video seconds [t0, t0 + dur] by the model (like asetrate in the player)."""
    s0 = ratio * t0 + offset
    x = pcm(src, track, s0, ratio * dur + 0.05)
    if ratio == 1.0:
        return x[:int(round(dur * FS))]
    n = int(round(dur * FS))
    return np.interp(np.arange(n) * ratio, np.arange(len(x)), x).astype(np.float32)


def gcc(a, b, max_lag):
    """Lag (s) where b matches a (b[n + lag] ~ a[n]) and a peak quality; GCC-PHAT on 150-3500 Hz."""
    n = 1 << int(np.ceil(np.log2(len(a) + len(b))))
    A, B = np.fft.rfft(a, n), np.fft.rfft(b, n)
    R = np.conj(A) * B
    R /= np.abs(R) + 1e-9
    f = np.fft.rfftfreq(n, 1 / FS)
    R[(f < 150) | (f > 3500)] = 0
    cc = np.fft.irfft(R, n)
    m = int(max_lag * FS)
    lags = np.r_[np.arange(0, min(m, len(b)) + 1), np.arange(-min(m, len(a)), 0)]
    vals = cc[lags % n]
    i = int(np.argmax(vals))
    k = lags[i]
    # sub-sample peak
    y0, y1, y2 = cc[(k - 1) % n], cc[k % n], cc[(k + 1) % n]
    d = 0.5 * (y0 - y2) / (y0 - 2 * y1 + y2) if (y0 - 2 * y1 + y2) != 0 else 0
    # quality: peak against the noise floor of the searched lags (away from the peak)
    far = np.abs(lags - k) > FS // 20
    q = float(y1 / (np.std(vals[far]) + 1e-12)) if far.any() else 0.0
    return (k + d) / FS, q


def probe(video, vt, audio, at, t, win, ratio, offset, search):
    """Measured dub second for video second t (window win s), searching +-search s around the model."""
    a = pcm(video, vt, t, win)
    b = dub(audio, at, t - search, win + 2 * search, ratio, offset)
    lag, q = gcc(a, b, 2 * search)
    # a[n] ~ b[n + lag]: video second t is model video second t - search + lag
    return ratio * (t - search + lag) + offset, q


GOOD = 12.0   # peak quality that means a real match (noise ~5-9)


def head(video, vt, audio, at, first=()):
    """Ratio and offset from the start of the film: a wide search (dubs add or cut logos, overtures).
    `first`: try these seconds before (a torrent still downloading has data only near the planned point)."""
    best = None
    for t in tuple(first) + (60.0, 600.0, 1200.0):
        for r in RATIOS:
            s, q = probe(video, vt, audio, at, t, 30, r, 0.0, 600)
            if best is None or q > best[2]:
                best = (r, s - r * t, q, t)
        if best[2] >= GOOD:
            break
    return best


def mapping(video, vt, audio, at, duration, step=60.0):
    """The whole film as segments [{"t": video second, "c": offset}]: s = ratio * t + c inside each.
    A release with an extra scene, intermission or logo shifts the offset; the walk finds where."""
    duration = float(duration)
    r, c, q, t0 = head(video, vt, audio, at)
    if q < GOOD:
        return {"ok": False, "error": "no match", "q": round(q, 1)}
    # Precise offset at the head.
    s, q = probe(video, vt, audio, at, t0, 60, r, c, 1)
    c = s - r * t0
    segs = [{"t": 0.0, "c": c}]
    last_good, t = t0, t0 + step
    while t < duration - 30:
        s, q = probe(video, vt, audio, at, t, 20, r, c, 2)
        if q >= GOOD:
            d = s - r * t - c
            # Releases differ by single frames at reel joins (42 ms at 24 fps): a new segment from the middle.
            if 0.02 < abs(d) < 0.3:
                c += d
                segs.append({"t": round((last_good + t) / 2, 1), "c": c})
            last_good = t
        else:
            s2, q2 = probe(video, vt, audio, at, t, 30, r, c, 900)
            c2 = s2 - r * t
            if q2 >= GOOD and abs(c2 - c) > 0.3:
                # Bisect the switch between last_good (old offset) and t (new offset) to ~2 s.
                lo, hi = last_good, t
                while hi - lo > 2:
                    m = (lo + hi) / 2
                    _, qa = probe(video, vt, audio, at, m, 8, r, c, 0.3)
                    _, qb = probe(video, vt, audio, at, m, 8, r, c2, 0.3)
                    lo, hi = (m, hi) if qa >= qb else (lo, m)
                segs.append({"t": round((lo + hi) / 2, 1), "c": c2})
                c, last_good = c2, t
        t += step
    for x in segs:
        x["c"] = round(x["c"], 4)
    return {"ok": True, "ratio": r, "segments": segs}


def at(segs, t):
    return [x for x in segs if x["t"] <= t][-1]["c"]


def verify(video, vt, audio, at_, duration, ratio, segs, every=300):
    duration, ratio, every = float(duration), float(ratio), float(every)
    rows, t = [], 30.0
    while t < duration - 40:
        c = at(segs, t + 10)
        s, q = probe(video, vt, audio, at_, t, 20, ratio, c, 1.5)
        rows.append({"t": round(t), "err_ms": round((s - (ratio * t + c)) * 1000, 1), "q": round(q, 1)})
        t += every
    good = [x["err_ms"] for x in rows if x["q"] >= GOOD]
    g = np.abs(np.array(good)) if good else np.array([np.nan])
    return {"probes": rows, "good": len(good), "of": len(rows),
            "max_ms": round(float(g.max()), 1), "median_ms": round(float(np.median(g)), 1),
            "within_80": int((g <= 80).sum())}


SR = 48000
CHUNK = 120.0   # video seconds mapped and rendered per step
WIN, HOP, NEAR = 10.0, 5.0, 1.0
AC3_DELAY = 256   # the AC3 encoder's priming samples: read that much ahead so the track lands on time


def ffprobe(src, *entries):
    r = subprocess.run([FF.replace("ffmpeg", "ffprobe"), "-v", "error", "-show_entries", ",".join(entries), "-of", "json", src],
                       capture_output=True, timeout=60)
    return json.loads(r.stdout or b"{}")


class Reader:
    """The dub as 48 kHz PCM on the video's clock (asetrate undoes a PAL speed-up, pitch too), read in order."""
    def __init__(self, src, track, ratio, ch):
        af = (f"asetrate={SR * ratio:.3f}," if ratio != 1.0 else "") + f"aresample={SR}"
        self.ch, self.pos = ch, 0
        self.p = subprocess.Popen([FF, "-hide_banner", "-loglevel", "error", "-nostdin", "-i", src, "-map", f"0:a:{track}",
                                   "-af", af, "-ac", str(ch), "-f", "s16le", "-"], stdout=subprocess.PIPE)

    def read(self, n):
        raw = self.p.stdout.read(n * 2 * self.ch) if n > 0 else b""
        x = np.frombuffer(raw, np.int16).reshape(-1, self.ch)
        self.pos += n
        if len(x) < n:   # the dub ends before the film: silence
            x = np.vstack([x, np.zeros((n - len(x), self.ch), np.int16)])
        return x


def fade(x, inn, out, n=240):
    x = x.astype(np.float32)
    n = min(n, len(x) // 2)
    if n:
        r = np.linspace(0, 1, n, dtype=np.float32)[:, None]
        if inn: x[:n] *= r
        if out: x[-n:] *= r[::-1]
    return x


def playhead():
    try:
        return float(open(os.environ["MIX_PLAYHEAD"]).read())
    except (KeyError, OSError, ValueError):
        return None


def align(video, vt, dub_src, dt, out, status, work=None):
    st = {"state": "sync", "until": 0.0}
    def save(**k):
        st.update(k); tmp = status + f".{os.getpid()}.tmp"   # two runs never share a temp file
        with open(tmp, "w") as f: json.dump(st, f)
        os.replace(tmp, status)
    save()
    duration = float(ffprobe(video, "format=duration").get("format", {}).get("duration", 0) or 0)
    # A stream (HDRezka, the torrent engine) is copied to a local file first: one sequential read, then fast seeks.
    dl = None
    if dub_src.startswith("http"):
        local = os.path.join(work or os.path.dirname(out), os.path.basename(out) + ".dub.mka")
        prog = local + ".progress"
        # HDRezka's CDN sometimes does not answer (2026-10-24: "Connection … voidboost … timed out"): 3 tries, 2/4/8 s apart.
        import threading
        state = {"done": False, "failed": False}
        def copy(src=dub_src, track=dt):
            for k in range(3):
                r = subprocess.run([FF, "-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-rw_timeout", "15000000",
                                    "-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_on_network_error", "1",
                                    "-i", src, "-map", f"0:a:{track}", "-c", "copy", "-progress", prog, local], capture_output=True)
                if r.returncode == 0 and os.path.exists(local) and os.path.getsize(local) > 100_000:
                    state["done"] = True; return
                time.sleep(2 ** (k + 1))
            state["failed"] = True
        threading.Thread(target=copy, daemon=True).start()
        dl = True
        dub_src, dt = local, 0
        def have():
            if state["failed"]: return -1
            if state["done"]: return 1e9
            try:
                t = [l for l in open(prog).read().split("\n") if l.startswith("out_time_us=")]
                return int(t[-1].split("=")[1]) / 1e6 if t else 0.0
            except (OSError, ValueError): return 0.0
        for _ in range(3000):
            if have() > 1300 or have() < 0 or state["done"]: break
            time.sleep(0.2)
        if have() < 0:
            return save(state="error", error="dub")
    else:
        have = lambda: 1e9
    def wait_dub(u):
        while 0 <= have() < u + 30: time.sleep(0.3)
    ph = playhead()
    r, c, q, t0 = head(video, vt, dub_src, dt, (ph + 30, ph + 90) if ph else ())
    if q < GOOD:
        return save(state="error", error="no match", q=round(q, 1))
    s, _ = probe(video, vt, dub_src, dt, t0, 60, r, c, 1)
    c = s - r * t0
    a = (ffprobe(dub_src, "stream=channels").get("streams") or [{}])[dt].get("channels", 2)
    ch = min(int(a or 2), 6)
    segs = [{"t": 0.0, "c": c}]
    save(state="sync", ratio=r, segments=segs, q=round(q, 1))
    # Raw CBR AC3: frame k (32 ms) starts at byte k * frame, so the player starts anywhere with -skip_initial_bytes,
    # no seek (a seek in a growing file hangs ffmpeg: it reads the end, which is not written yet).
    kbps = 640 if ch > 2 else 256
    save(kbps=kbps, frame=kbps * 1000 * 1536 // SR // 8)
    rd = Reader(dub_src, dt, r, ch)
    enc = subprocess.Popen([FF, "-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-f", "s16le", "-ar", str(SR), "-ac", str(ch),
                            "-i", "-", "-c:a", "ac3", "-b:a", f"{kbps}k", "-f", "ac3", out], stdin=subprocess.PIPE)
    lost, last_good, pend = 0, t0, None   # pend: good windows that disagree with the current offset
    T = 0.0
    while T < duration:
        L = min(CHUNK, duration - T)
        # The TV's second (the core writes it): a seek far ahead renders the part behind it with the last offset (fast).
        # Never wait for the TV: the TV may itself wait for this track (measured 2026-10-23: both stood still).
        head_at = playhead()
        behind = head_at is not None and T + L < head_at - 60
        # A planned switch (MIX_PLAN): the release is in only around the switch point - map 10 min after it, render the
        # rest with the last offset (measured 2026-10-24: mapping the empty rest took 75 s and missed the point).
        if os.environ.get("MIX_PLAN") and head_at is not None and T > head_at + 600:
            behind = True
        # A video from the TV's torrent engine: a read far ahead moves the engine's window away from what the TV plays
        # and the TV stops (measured 2026-10-24: a probe at 1:52:00 froze the TV at 15:23). Map only what is near.
        if video.startswith("http://127.0.0.1:8890") and head_at is not None and T > head_at + 90:
            behind = True
        # Map: 10 s windows every 5 s, searching +-1 s around the current offset.
        if T + L > 30 and not behind:
            wait_dub(r * (T + L) + c)
            A = pcm(video, vt, T, L + WIN)
            B = dub(dub_src, dt, T - NEAR, L + WIN + 2 * NEAR, r, c)
            base = c
            for k in range(int(L // HOP)):
                tau = T + k * HOP
                i = int(k * HOP * FS)
                lag, qq = gcc(A[i:i + int(WIN * FS)], B[i:i + int((WIN + 2 * NEAR) * FS)], 2 * NEAR)
                cm = r * (lag - NEAR) + base
                if qq < GOOD:
                    lost += 1
                    if lost % 6 == 0:   # each 30 s without a match: a cut, an intermission, a new scene - search wide
                        s2, q2 = probe(video, vt, dub_src, dt, tau + WIN, 30, r, c, 900)
                        c2 = s2 - r * (tau + WIN)
                        # Music repeats (themes, credits): a far match counts only if a later window confirms it.
                        ok2 = q2 >= 1.25 * GOOD and abs(c2 - c) > 0.3
                        if ok2:
                            _, q3 = probe(video, vt, dub_src, dt, tau + WIN + 40, 20, r, c2, 0.3)
                            ok2 = q3 >= GOOD
                        if ok2:
                            wait_dub(r * duration)
                            lo, hi = last_good, tau + WIN
                            while hi - lo > 2:
                                m = (lo + hi) / 2
                                _, qa = probe(video, vt, dub_src, dt, m, 8, r, c, 0.3)
                                _, qb = probe(video, vt, dub_src, dt, m, 8, r, c2, 0.3)
                                lo, hi = (m, hi) if qa >= qb else (lo, m)
                            b = max(round((lo + hi) / 2, 2), segs[-1]["t"] + 0.1)
                            if b < T:  # already rendered: apply from here on
                                b = T + k * HOP
                            segs.append({"t": b, "c": c2}); c = c2; lost = 0
                            break   # re-map the rest of this chunk around the new offset
                    continue
                lost = 0
                center = tau + WIN / 2
                if abs(cm - c) > 0.015:
                    # A frame-level shift (reel join) or a short local edit: three good windows in a row agree.
                    pend = [x for x in pend if abs(x[1] - cm) < 0.012] + [(center, cm, qq)] if pend else [(center, cm, qq)]
                    # Short edits (10 s, 2 frames - measured in Lawrence of Arabia): two strong windows are enough.
                    if len(pend) >= 3 or (len(pend) == 2 and min(x[2] for x in pend) >= 1.5 * GOOD):
                        cm = float(np.median([x[1] for x in pend]))
                        b = max(round((pend[0][0] + last_good) / 2, 2), segs[-1]["t"] + 0.1, T)
                        segs.append({"t": b, "c": cm}); c = cm; pend = None
                        last_good = center
                else:
                    pend = None
                    last_good = center
        # Render [T, T + L): each segment piece takes dub samples n + k, k = c / r * SR (dub on the video clock).
        n0, n1 = int(round(T * SR)), int(round((T + L) * SR))
        pieces = []
        cuts = [x for x in segs if T < x["t"] < T + L]
        starts = [n0] + [int(round(x["t"] * SR)) for x in cuts] + [n1]
        for j in range(len(starts) - 1):
            na, nb = starts[j], starts[j + 1]
            k = int(round(at(segs, na / SR) / r * SR)) + AC3_DELAY
            m = na + k
            jump = m != rd.pos
            if m > rd.pos:
                rd.read(m - rd.pos)          # the dub has extra here: skip it
            elif m < rd.pos:                 # the video has extra here: silence while the dub catches up
                g = min(rd.pos - m, nb - na)
                pieces.append(np.zeros((g, ch), np.float32)); na += g
            if nb > na:
                x = fade(rd.read(nb - na), jump, j < len(starts) - 2)
                pieces.append(x)
        y = np.clip(np.vstack(pieces), -32768, 32767).astype(np.int16)
        enc.stdin.write(y.tobytes()); enc.stdin.flush()
        T += L
        for x in segs: x["c"] = round(x["c"], 4)
        save(state="ready" if T >= min(duration, 60) else "sync", until=round(T, 1), segments=segs)
    rd.p.kill(); enc.stdin.close(); enc.wait()
    save(state="done", until=round(duration, 1), segments=segs)


if __name__ == "__main__":
    cmd, v, vt, a, at_, d = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4], int(sys.argv[5]), sys.argv[6]
    if cmd == "align":
        align(v, vt, a, at_, d, sys.argv[7], *sys.argv[8:]); sys.exit(0)
    if cmd == "map":
        out = mapping(v, vt, a, at_, d)
    else:   # verify: the map's JSON as the 7th argument
        m = json.loads(sys.argv[7])
        out = verify(v, vt, a, at_, d, m["ratio"], m["segments"], *sys.argv[8:])
    print(json.dumps(out, ensure_ascii=False))
