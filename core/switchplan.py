#!/usr/bin/python3
"""Planned picture switch (owner 2026-10-24): HDRezka plays on; the torrent downloads from a FUTURE point P on, the dub
is aligned for P ahead, and at P the core cuts to the torrent picture with the same voice (kino/mix "video" + "from").

  switchplan.py PLAN.json STATUS.json
PLAN: {"kind": "picture"|"sound", "magnet", "duration", "mixdir", "episode": "s02e18"|null,
  picture: "dub" (HDRezka stream), "mix" (kino/mix body without video/from, with "key");
  sound: "video", "vtrack" (what plays now), "label" - the release's Ukrainian track goes over the current picture}
STATUS (read by the core for the dock): {"state": "meta|measure|buffering|syncing|ready|done|failed|cancelled",
  "at": P, "eta": unix time of P, "rate", "bitrate", "ready": 0..1, "error"}
A file STATUS.cancel stops it. Never stalls the picture: buffer not ready by P -> P moves 2 min later.
"""
import base64, json, os, re, subprocess, sys, time, urllib.request

RPC = "http://127.0.0.1:9091/transmission/rpc"
API = "http://127.0.0.1:8891/api/"
HERE = os.path.dirname(os.path.abspath(__file__))
BUFFER, LATER, MIN_LEFT = 60.0, 30.0, 120.0   # owner 2026-10-24: 1 min of buffer, then the switch
plan, status = json.load(open(sys.argv[1])), sys.argv[2]
st = {"state": "meta"}
sid = ""


def mixname(key):
    """The core's cache name for an aligned pair (Cast.swift mix())."""
    h = 2166136261
    for b in key.encode():
        h = ((h ^ b) * 16777619) & 0xFFFFFFFF
    return "mix-" + "".join(ch if ch.isascii() and ch.isalnum() else "_" for ch in key)[:60] + "-%08x" % h


def resolve(p):
    """Transmission moves a finished file out of .incomplete and drops ".part": follow it."""
    if p and not os.path.exists(p) and "/.incomplete/" in p and p.endswith(".part"):
        q = p.replace("/.incomplete/", "/", 1)[:-5]
        if os.path.exists(q): return q
    return p


def save(**k):
    st.update(k); tmp = status + ".tmp"
    with open(tmp, "w") as f: json.dump(st, f)
    os.replace(tmp, status)


def stop(state, error=None):
    save(state=state, **({"error": error} if error else {})); sys.exit(0)


def rpc(method, **args):
    global sid
    for _ in range(2):
        req = urllib.request.Request(RPC, json.dumps({"method": method, "arguments": args}).encode(), {"X-Transmission-Session-Id": sid})
        try:
            return json.load(urllib.request.urlopen(req, timeout=15))["arguments"]
        except urllib.error.HTTPError as e:
            if e.code != 409: raise
            sid = e.headers.get("X-Transmission-Session-Id", "")


def api(cmd, body=None):
    req = urllib.request.Request(API + cmd, json.dumps(body).encode() if body is not None else None, {"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=60))


def cast():
    return api("state").get("cast", {})


def check_cancel():
    if os.path.exists(status + ".cancel"): stop("cancelled")


def pieces_done(t, a, b):
    bits = base64.b64decode(t["pieces"])
    return all(bits[i >> 3] & (0x80 >> (i & 7)) for i in range(max(0, a), min(b, t["pieceCount"] - 1) + 1))


save()
title0 = cast().get("title", "")
h = (re.search(r"btih:([0-9a-zA-Z]+)", plan["magnet"]) or [None, ""])[1].lower()
rpc("torrent-add", filename=plan["magnet"], paused=False)
F = ["id", "name", "files", "pieces", "pieceCount", "pieceSize", "rateDownload", "downloadDir", "percentDone", "metadataPercentComplete"]
t = None
for _ in range(240):   # metadata from peers: up to 2 min
    check_cancel()
    t = (rpc("torrent-get", ids=[h], fields=F)["torrents"] or [None])[0]
    if t and t.get("metadataPercentComplete") == 1 and t.get("files"): break
    time.sleep(0.5)
else:
    stop("failed", "Роздача не дала метаданих за 2 хв")
# The episode's file (SxxEyy) or the largest; only it is downloaded.
files = t["files"]
ep = plan.get("episode")
cands = [i for i, f in enumerate(files) if ep and ep in f["name"].lower().replace(" ", "").replace(".", "")] or range(len(files))
fi = max(cands, key=lambda i: files[i]["length"])
f = files[fi]
rpc("torrent-set", ids=[t["id"]], **{"files-wanted": [fi], "files-unwanted": [i for i in range(len(files)) if i != fi]})
start = sum(x["length"] for x in files[:fi])   # the file's first byte in the torrent
# Started for watching: temporary unless "↓" keeps it (keeper.py deletes it after viewing).
regp = os.path.join(plan["mixdir"], "watch-torrents.json")
try: reg = json.load(open(regp))
except (OSError, ValueError): reg = {}
reg.setdefault(h, {"kind": "transmission", "files": [], "max": 0})
dl = t.get("downloadDir") or "/Volumes/External/Torrent"
for q in (os.path.join(dl, ".incomplete", f["name"] + ".part"), os.path.join(dl, f["name"])):
    if q not in reg[h]["files"]: reg[h]["files"].append(q)
if plan.get("kind") == "prepare":
    # «Підготувати» (owner 2026-10-24): kept, downloaded in order from the start (watchable up to where it is, as online),
    # the voice copied now; keeper.py aligns it over the whole film and muxes it in when the file is complete.
    dubcopy = os.path.join(plan["mixdir"], f"prepare-{h}.dub.mka")
    reg[h]["mix"] = {"dubcopy": dubcopy, "dubtrack": 0, "label": plan.get("label", "")}
with open(regp + ".tmp", "w") as fp: json.dump(reg, fp)
os.replace(regp + ".tmp", regp)
if plan.get("kind") == "prepare":
    kp = os.path.join(plan["mixdir"], "keep.json")
    try: k = json.load(open(kp))
    except (OSError, ValueError): k = {}
    k[h] = True
    with open(kp + ".tmp", "w") as fp: json.dump(k, fp)
    os.replace(kp + ".tmp", kp)
    rpc("torrent-set", ids=[t["id"]], sequential_download=True, sequential_download_from_piece=start // t["pieceSize"])
    subprocess.run([os.path.expanduser("~/tinyTV/tools/bin/ffmpeg"), "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                    "-reconnect", "1", "-i", plan["dub"], "-map", "0:a:0", "-c", "copy", dubcopy], timeout=900)
    stop("prepared")
ps, length, D = t["pieceSize"], f["length"], float(plan["duration"])
piece = lambda sec: int((start + max(0.0, min(sec, D)) / D * length) // ps)
first, last = start // ps, (start + length - 1) // ps


def get():
    return rpc("torrent-get", ids=[t["id"]], fields=F)["torrents"][0]


def wait_pieces(a, b, limit):
    for _ in range(int(limit * 2)):
        check_cancel()
        if pieces_done(get(), a, b): return True
        time.sleep(0.5)
    return False


# Head (header) and tail (Matroska index), then measure the rate for 30 s.
save(state="meta", file=f["name"])
for a, b in ((first, first + 1), (last - 1, last)):
    rpc("torrent-set", ids=[t["id"]], sequential_download=True, sequential_download_from_piece=a)
    if not wait_pieces(a, b, 120): stop("failed", "Не скачались голова і хвіст файлу за 2 хв")
kind = plan.get("kind", "picture")
dt = 0
if kind == "sound":
    # The release's Ukrainian track, read from the header that is in now.
    tt = get(); path0 = os.path.join(tt["downloadDir"], ".incomplete", f["name"] + ".part")
    if not os.path.exists(path0): path0 = os.path.join(tt["downloadDir"], f["name"])
    pr = subprocess.run([os.path.expanduser("~/tinyTV/tools/bin/ffprobe"), "-v", "error", "-select_streams", "a", "-show_entries",
                         "stream_tags=language,title", "-of", "json", path0], capture_output=True, timeout=60)
    sts = json.loads(pr.stdout or b"{}").get("streams", [])
    ua = [i for i, x in enumerate(sts) if (x.get("tags", {}).get("language", "").lower() in ("ukr", "uk"))
          or any(w in x.get("tags", {}).get("title", "").lower() for w in ("укр", "ukr", "україн", "украин"))]
    if not ua: stop("failed", "У роздачі немає української доріжки")
    dt = ua[0]
save(state="measure")
rates = []
for _ in range(30):
    check_cancel(); rates.append(get()["rateDownload"]); time.sleep(1)
R = sorted(rates)[len(rates) // 3] or 1   # lower third: a cautious rate
B = length / D
if R < 1.3 * B: stop("failed", f"Роздача повільна: {R / 1e6:.1f} МБ/с при бітрейті {B / 1e6:.1f} МБ/с")

c = cast(); pos = float(c.get("position") or 0)
# Time to get 1 min of video at P (+ 30 s before it) at the measured rate, + the sync (~20 s), + 10 s margin.
L = (BUFFER + 30) * B / R + 20 + 10
P = round(pos + L)
if P > D - MIN_LEFT: stop("failed", "До кінця серії замало часу для переходу")


def plan_at(P):
    rpc("torrent-set", ids=[t["id"]], sequential_download=True, sequential_download_from_piece=piece(P - 30))
    save(state="buffering", at=P, eta=time.time() + (P - float(cast().get("position") or 0)), rate=R, bitrate=B, ready=0)


plan_at(P)
# Picture: the HDRezka dub, one sequential copy now (~25 s), aligned when the buffer at P is in.
if kind == "picture":
    dub = os.path.join(plan["mixdir"], "plan-dub.mka")
    subprocess.run([os.path.expanduser("~/tinyTV/tools/bin/ffmpeg"), "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                    "-reconnect", "1", "-i", plan["dub"], "-map", "0:a:0", "-c", "copy", dub], timeout=600)
synced = None
while True:
    check_cancel()
    c = cast()
    if c.get("title", "") != title0: stop("cancelled", "На ТВ увімкнули інше")
    pos, tt = float(c.get("position") or 0), get()
    if not c.get("playing") and abs(P - pos) > 2:   # paused (owner): the switch happens where it stands
        P = round(pos); plan_at(P); synced = None
    a, b = piece(P - 30), piece(P + BUFFER)
    bits = base64.b64decode(tt["pieces"])
    have = sum(1 for i in range(a, b + 1) if bits[i >> 3] & (0x80 >> (i & 7)))
    save(ready=round(have / (b - a + 1), 2), eta=time.time() + (P - pos))
    path = os.path.join(tt["downloadDir"], f["name"])
    if not os.path.exists(path): path = os.path.join(tt["downloadDir"], ".incomplete", f["name"] + ".part")
    if not os.path.exists(path): path = os.path.join(os.path.dirname(tt["downloadDir"]), f["name"])
    if have == b - a + 1 and synced != P:
        # Align the dub for P now (the part behind P renders without mapping, fast).
        save(state="syncing")
        if kind == "picture":
            key, video, vt, dsrc, dtr = os.path.basename(path) + "|" + plan["mix"]["key"] + "#0", path, 0, dub, 0
        else:   # the release's track over the current picture (the core's key: title|file#track)
            key, video, vt, dsrc, dtr = title0 + "|" + path + "#" + str(dt), resolve(plan["video"]), int(plan.get("vtrack", 0)), path, dt
        name = mixname(key)
        out, sj = os.path.join(plan["mixdir"], name + ".ac3"), os.path.join(plan["mixdir"], name + ".json")
        for x in (out, sj):
            if os.path.exists(x): os.remove(x)
        with open(sj + ".pos", "w") as fp: fp.write(str(P))
        env = dict(os.environ, MIX_PLAYHEAD=sj + ".pos", MIX_PLAN="1")
        subprocess.run(["/usr/bin/python3", os.path.join(HERE, "audiosync.py"), "align", video, str(vt), dsrc, str(dtr), out, sj, plan["mixdir"]], env=env, timeout=900)
        synced = P; save(state="ready", synced_path=path)
    if pos >= P - 1.5 or (not c.get("playing") and synced == P):
        if synced == P:
            # The file may have finished and moved meanwhile: use where it is now, under the core's key for that path.
            old, path = st.get("synced_path", path), resolve(st.get("synced_path", path))
            if kind == "sound" and path != old:
                for ext in (".ac3", ".json"):
                    a = os.path.join(plan["mixdir"], mixname(title0 + "|" + old + "#" + str(dt)) + ext)
                    if os.path.exists(a): os.replace(a, os.path.join(plan["mixdir"], mixname(title0 + "|" + path + "#" + str(dt)) + ext))
            st["synced_path"] = path
            # Late (the TV passed P): cut at the TV's second, never jump back.
            at = max(P, round(pos + 1))
            if kind == "picture":
                body = dict(plan["mix"], video=st.get("synced_path", path), **{"from": at}); body.pop("key", None)
            else:
                body = {"path": st.get("synced_path", path), "track": dt, "label": plan.get("label", "")}
            r = api("kino/mix", body)
            if r.get("error"): stop("failed", r["error"])
            stop("done")
        # Not ready: HDRezka plays on, the point moves 2 min later (never a stalled picture).
        P += LATER
        if P > D - MIN_LEFT: stop("failed", "Буфер не встиг до кінця серії")
        plan_at(P)
    time.sleep(0.5 if P - pos < 5 else 2)
