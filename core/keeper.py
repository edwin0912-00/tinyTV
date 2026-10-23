#!/usr/bin/python3
"""Torrents started for watching are temporary (owner 2026-10-24): after they are watched (>= 90 %) and not marked
"↓ лишити на диску", their files are deleted for good, no Trash. Downloads added with «Скачати» are never touched.

  keeper.py MIXDIR      (the core starts one; it loops every 30 s)
MIXDIR/watch-torrents.json  {hash: {"kind": "transmission"|"engine", "files": [paths], "max": 0..1}}  (switchplan + this)
MIXDIR/keep.json            {hash: true}  (the core writes it from the dock's ↓)
MIXDIR/progress.json        {path: 0..1}  how much of each downloading file is in (the Media list shows "63 %")
Kept + a voice from another source ("mix"): once the release is complete, the voice is aligned over the whole film and
muxed in as the first audio track (video copied), "<name> [UA <voice>].mkv" replaces the release (owner 2026-10-24).
"""
import glob, json, os, re, subprocess, sys, time, urllib.request
HERE = os.path.dirname(os.path.abspath(__file__))
FF = os.path.expanduser("~/tinyTV/tools/bin/ffmpeg")

D = sys.argv[1]
REG, KEEP = os.path.join(D, "watch-torrents.json"), os.path.join(D, "keep.json")
API, RPC = "http://127.0.0.1:8891/api/", "http://127.0.0.1:9091/transmission/rpc"
sid = ""


def load(p):
    try: return json.load(open(p))
    except (OSError, ValueError): return {}


def save(p, d):
    with open(p + ".tmp", "w") as f: json.dump(d, f)
    os.replace(p + ".tmp", p)


def rpc(method, **args):
    global sid
    for _ in range(2):
        req = urllib.request.Request(RPC, json.dumps({"method": method, "arguments": args}).encode(), {"X-Transmission-Session-Id": sid})
        try: return json.load(urllib.request.urlopen(req, timeout=15))["arguments"]
        except urllib.error.HTTPError as e:
            if e.code != 409: raise
            sid = e.headers.get("X-Transmission-Session-Id", "")


def api(cmd, body=None):
    req = urllib.request.Request(API + cmd, json.dumps(body).encode() if body is not None else None, {"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=30))


def gone(p):
    """A finished Transmission file leaves .incomplete and drops ".part"."""
    return [p, p.replace("/.incomplete/", "/", 1)[:-5]] if "/.incomplete/" in p and p.endswith(".part") else [p]


def delete(h, e):
    if e["kind"] == "engine":
        api("kino/download/remove", {"hash": h}); return
    t = (rpc("torrent-get", ids=[h], fields=["files", "wanted", "downloadDir"])["torrents"] or [None])[0]
    if not t: return
    mine = {os.path.basename(q) for p in e["files"] for q in gone(p)}
    idx = [i for i, f in enumerate(t["files"]) if os.path.basename(f["name"]) in mine]
    others = [i for i, w in enumerate(t["wanted"]) if w and i not in idx and t["files"][i]["bytesCompleted"] > 0]
    if not others:   # nothing else of this release is wanted: the torrent and its data go
        rpc("torrent-remove", ids=[h], **{"delete-local-data": True}); return
    # A season pack with other episodes kept: only this episode's file
    rpc("torrent-set", ids=[h], **{"files-unwanted": idx})
    for p in e["files"]:
        for q in gone(p):
            if os.path.exists(q): os.remove(q)


def video_of(h, e):
    """The finished file of this release, or None while it downloads."""
    if e["kind"] == "engine":
        l = api("kino/downloads", {})
        t = next((x for x in l.get("torrents", []) if (x.get("hash") or "").lower() == h), None)
        if not t or not t.get("done"): return None
        root = os.path.join(l.get("folder", ""), t["name"])
        names = {os.path.basename(p) for p in e["files"]}
        cands = [root] if os.path.isfile(root) else [f for f in glob.glob(glob.escape(root) + "/**/*", recursive=True) if os.path.basename(f) in names]
        return cands[0] if cands else None
    t = (rpc("torrent-get", ids=[h], fields=["files", "wanted", "downloadDir"])["torrents"] or [None])[0]
    if not t: return None
    names = {os.path.basename(q) for p in e["files"] for q in gone(p)}
    for f, w in zip(t["files"], t["wanted"]):
        if w and os.path.basename(f["name"]) in names and f["bytesCompleted"] == f["length"]:
            p = os.path.join(t["downloadDir"], f["name"])
            if os.path.exists(p): return p
    return None


def mux(h, e, video):
    """Align the chosen voice over the whole film and put it in the file as the first, default track."""
    m = e["mix"]
    stem = os.path.splitext(os.path.basename(video))[0]
    voice = m.get("label", "").replace("HDRezka · ", "").strip() or "UA"
    out = os.path.join("/Volumes/External/Torrent" if video.startswith("/Volumes/External/Torrent/") else os.path.dirname(video),
                       f"{stem} [{voice}].mkv")
    full, st = os.path.join(D, f"full-{h}.ac3"), os.path.join(D, f"full-{h}.json")
    e["save"] = {"state": "align"}; save(REG, load_reg_merge(h, e))
    subprocess.run(["/usr/bin/python3", os.path.join(HERE, "audiosync.py"), "align", video, "0", m["dubcopy"], str(m.get("dubtrack", 0)), full, st, D],
                   timeout=3 * 3600, capture_output=True)
    if load(st).get("state") != "done":
        e["save"] = {"state": "failed", "error": "озвучка не вирівнялась"}; return False
    e["save"] = {"state": "mux"}; save(REG, load_reg_merge(h, e))
    tmp = out + ".part"
    r = subprocess.run([FF, "-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i", video, "-f", "ac3", "-i", full,
                        "-map", "0:v", "-map", "1:a", "-map", "0:a?", "-map", "0:s?", "-c", "copy",
                        "-disposition:a", "0", "-disposition:a:0", "default", "-metadata:s:a:0", "language=ukr",   # only the voice is default "-metadata:s:a:0", f"title={voice}",
                        "-f", "matroska", tmp], capture_output=True, timeout=3 * 3600)
    if r.returncode != 0 or not os.path.exists(tmp): return False
    os.replace(tmp, out)
    for x in (full, st): 
        if os.path.exists(x): os.remove(x)
    # The release itself goes: the muxed file has its picture and all its tracks.
    if e["kind"] == "engine": api("kino/download/remove", {"hash": h})
    else: rpc("torrent-remove", ids=[h], **{"delete-local-data": True})
    e["muxed"] = out; e["save"] = {"state": "done", "file": out}
    return True


def load_reg_merge(h, e):
    """The registry with this entry's progress, for the dock while a long align runs."""
    r = load(REG); r[h] = e; return r


def dl_pct(h, e):
    if e["kind"] == "engine":
        t = next((x for x in api("kino/downloads", {}).get("torrents", []) if (x.get("hash") or "").lower() == h), None)
        return (t or {}).get("progress") or 0
    t = (rpc("torrent-get", ids=[h], fields=["files", "wanted"])["torrents"] or [None])[0]
    if not t: return 0
    names = {os.path.basename(q) for p in e["files"] for q in gone(p)}
    fs = [f for f, w in zip(t["files"], t["wanted"]) if w and os.path.basename(f["name"]) in names]
    return sum(f["bytesCompleted"] for f in fs) / max(1, sum(f["length"] for f in fs))


def progress():
    """Share of each downloading file that is in, for the Media list."""
    out = {}
    for t in rpc("torrent-get", fields=["files", "wanted", "downloadDir"])["torrents"]:
        for f, w in zip(t["files"], t["wanted"]):
            if w and f["length"] and f["bytesCompleted"] < f["length"]:
                out[os.path.join(t["downloadDir"], f["name"])] = round(f["bytesCompleted"] / f["length"], 3)
    l = api("kino/downloads", {})
    for t in l.get("torrents", []):
        if not t.get("done"): out[os.path.join(l.get("folder", ""), t["name"])] = round(t.get("progress") or 0, 3)
    save(os.path.join(D, "progress.json"), out)


while True:
    try:
        reg, keep, s = load(REG), load(KEEP), api("state")
        c = s.get("cast", {})
        title, pos, dur = c.get("title") or "", float(c.get("position") or 0), float(c.get("duration") or 0)
        used = [title] + list(c.get("inputs") or []) + [c.get("mix", {}).get("dub") or ""]
        m = re.search(r"btih:([0-9a-fA-F]{40})", c.get("link") or "")
        if m and m[1].lower() not in reg:   # a torrent the TV engine plays: temporary too
            reg[m[1].lower()] = {"kind": "engine", "files": [title], "max": 0}
        mx = c.get("mix") or {}
        for h, e in list(reg.items()):
            names = {os.path.basename(q) for p in e["files"] for q in gone(p)}
            active = any(os.path.basename(u.replace(".part", "")) in {n.replace(".part", "") for n in names} for u in used if u)
            e["active"] = active
            if active and dur > 0: e["max"] = max(e.get("max", 0), pos / dur)
            # The voice chosen over this release (picture side): remembered for the mux.
            pic = any(os.path.basename(u.replace(".part", "")) in {n.replace(".part", "") for n in names} for u in [title] + list(c.get("inputs") or [])[:1] if u)
            if pic and mx.get("track"):
                copy = mx["track"] + ".dub.mka"
                e["mix"] = {"dubcopy": copy if os.path.exists(copy) else mx.get("dub", ""), "dubtrack": 0 if os.path.exists(copy) else mx.get("dubTrack", 0),
                            "label": mx.get("label", "")}
            if keep.get(h) and e.get("mix") and not e.get("muxed"):
                # «Зберегти цю пару на потім»: download to the end, then (after watching) align + mux.
                v = video_of(h, e)
                if not v: e["save"] = {"state": "download", "pct": round(dl_pct(h, e), 3)}
                elif active: e["save"] = {"state": "after", "pct": 1}
                elif mux(h, e, v): save(REG, reg)
            if not active and not keep.get(h) and e.get("max", 0) >= 0.9:
                delete(h, e); del reg[h]
        save(REG, reg)
        progress()
    except Exception as ex:   # the core restarting, Transmission busy: try again next round
        print("keeper:", ex, file=sys.stderr, flush=True)
    time.sleep(30)
