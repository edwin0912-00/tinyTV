#!/usr/bin/python3
"""Copies ffmpeg, ffprobe and yt-dlp (with Python and every non-system library) to ~/tinyTV/tools on the core host.

Optional. Only for a core host whose Homebrew lives on an external disk: services started by launchd
(tinyTVCore) may get no access to it (measured: ffmpeg hung in dyld open(), `ls` there returned nothing).
Copies on the internal disk need no permission. Run on the core host over SSH (the SSH session can read the disk):
    /usr/bin/python3 ~/tinyTV/copy-tools.py
Re-run after `brew upgrade ffmpeg yt-dlp`.
"""
import os, shutil, subprocess, glob, sys

HOME = os.path.expanduser("~")
OUT = os.path.join(HOME, "tinyTV/tools")
LIB = os.path.join(OUT, "lib")
BIN = os.path.join(OUT, "bin")
SYSTEM = ("/usr/lib/", "/System/")


def deps(path):
    out = subprocess.run(["otool", "-L", path], capture_output=True, text=True).stdout.splitlines()[1:]
    return [l.strip().split(" (")[0] for l in out]


def rpaths(path):
    out = subprocess.run(["otool", "-l", path], capture_output=True, text=True).stdout.splitlines()
    return [out[i + 2].split()[1] for i, l in enumerate(out) if "LC_RPATH" in l]


def resolve(ref, owner):
    if ref.startswith("@rpath/"):
        for rp in rpaths(owner):
            base = rp.replace("@loader_path", os.path.dirname(owner)).replace("@executable_path", os.path.dirname(owner))
            cand = os.path.join(base, ref[len("@rpath/"):])
            if os.path.exists(cand):
                return os.path.realpath(cand)
        return None
    if ref.startswith("@loader_path/"):
        cand = os.path.join(os.path.dirname(owner), ref[len("@loader_path/"):])
        return os.path.realpath(cand) if os.path.exists(cand) else None
    if ref.startswith("@"):
        return None
    return os.path.realpath(ref) if os.path.exists(ref) else None


def is_macho(p):
    try:
        with open(p, "rb") as f:
            return f.read(4) in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe")
    except OSError:
        return False


copied = {}  # real source path -> copy in LIB


def fix(target, origin):
    """Point every non-system dependency of `target` (copied from `origin`) at copies in LIB."""
    if not os.access(target, os.W_OK):
        os.chmod(target, 0o755)
    for ref in deps(target):
        if ref.startswith(SYSTEM) or os.path.basename(ref) == os.path.basename(target) and ref.startswith("@rpath"):
            continue
        real = resolve(ref, origin)
        if not real or real.startswith(SYSTEM) or real.startswith(OUT + "/"):
            continue
        name = os.path.basename(real)
        dst = os.path.join(LIB, name)
        if real not in copied:
            copied[real] = dst
            shutil.copy2(real, dst)
            os.chmod(dst, 0o755)
            subprocess.run(["install_name_tool", "-id", "@loader_path/" + name, dst], capture_output=True)
            fix(dst, real)
            sign(dst)
        rel = os.path.relpath(LIB, os.path.dirname(target))
        subprocess.run(["install_name_tool", "-change", ref, "@loader_path/" + (rel + "/" if rel != "." else "") + name, target],
                       capture_output=True)


def sign(p):
    subprocess.run(["codesign", "--force", "--sign", "-", p], capture_output=True)


def main():
    shutil.rmtree(OUT, ignore_errors=True)
    os.makedirs(LIB); os.makedirs(BIN)
    for tool in ("ffmpeg", "ffprobe"):
        src = os.path.realpath("/opt/homebrew/bin/" + tool)
        dst = os.path.join(BIN, tool)
        shutil.copy2(src, dst)
        fix(dst, src)
        sign(dst)

    # yt-dlp: Homebrew's own venv (site-packages) + its Python, copied as a tree.
    ytd = os.path.realpath("/opt/homebrew/bin/yt-dlp")
    venv = ytd.rsplit("/bin/", 1)[0]                                  # .../yt-dlp/<v>/libexec (a venv)
    site = glob.glob(venv + "/lib/python3.*/site-packages")[0]
    pyver = site.split("/lib/")[-1].split("/")[0]                     # python3.14
    pyexe = os.path.realpath(venv + "/bin/python3")
    fw = pyexe.split("/bin/")[0]                                      # .../Python.framework/Versions/3.14
    py = os.path.join(OUT, "python")
    shutil.copytree(fw, py, symlinks=True)
    shutil.copytree(site, os.path.join(OUT, "site-packages"), symlinks=False)
    for root, _, files in os.walk(OUT):
        if root.startswith(LIB):
            continue
        for f in files:
            p = os.path.join(root, f)
            if os.path.islink(p) or not is_macho(p):
                continue
            origin = p.replace(py, fw) if p.startswith(py) else p
            fix(p, origin if os.path.exists(origin) else p)
            sign(p)
    # Homebrew bakes its lib dirs (external disk) into ctypes' search path: point them at our lib copy.
    dyld = glob.glob(py + "/lib/python3.*/ctypes/macholib/dyld.py")[0]
    src = open(dyld).read()
    import re
    src = re.sub(r"'(/Volumes/[^']*|/opt/homebrew[^']*)'", repr(LIB), src)
    open(dyld, "w").write(src)
    for c in glob.glob(os.path.dirname(dyld) + "/__pycache__/dyld.*"):
        os.remove(c)
    # sysconfig's build-time paths point at /opt/homebrew too; yt-dlp's plugin search stats them and hung.
    gone = os.path.join(OUT, "no-homebrew")
    for f in glob.glob(py + "/lib/python3.*/_sysconfig*") + glob.glob(py + "/lib/python3.*/config-*/*.json"):
        if os.path.isfile(f) and not f.endswith(".pyc"):
            t = open(f).read()
            t = re.sub(r"/Volumes/[^\"\']*?/opt/homebrew", gone, t).replace("/opt/homebrew", gone)
            open(f, "w").write(t)
    for c in glob.glob(py + "/lib/python3.*/__pycache__/_sysconfig*"):
        os.remove(c)
    # OpenSSL reads its config and CA file from /opt/homebrew/etc (external disk too): copy them; the core and the
    # wrapper point OPENSSL_CONF / SSL_CERT_FILE here.
    etc = os.path.join(OUT, "etc"); os.makedirs(etc)
    for f in ("openssl.cnf", "cert.pem"):
        shutil.copy2(os.path.realpath("/opt/homebrew/etc/openssl@3/" + f), os.path.join(etc, f))
    node = sorted(glob.glob(HOME + "/.local/share/madeforthisjob/.tools/node-v*-darwin-arm64/bin/node"))[-1]
    os.symlink(node, os.path.join(BIN, "node"))
    with open(os.path.join(BIN, "yt-dlp"), "w") as f:
        f.write(f"""#!/bin/sh
# yt-dlp from Homebrew, copied to the internal disk by copy-tools.py.
D="$(cd "$(dirname "$0")/.." && pwd)"
export PYTHONHOME="$D/python" PYTHONPATH="$D/site-packages" PYTHONNOUSERSITE=1
export OPENSSL_CONF="$D/etc/openssl.cnf" SSL_CERT_FILE="$D/etc/cert.pem"
# -S: no site/sitecustomize (Homebrew's add /opt/homebrew paths, which launchd services can't read: it hung).
exec "$D/python/Resources/Python.app/Contents/MacOS/Python" -S -m yt_dlp "$@"
""")
    os.chmod(os.path.join(BIN, "yt-dlp"), 0o755)
    print("copied", len(copied), "libraries to", LIB)


if __name__ == "__main__":
    sys.exit(main())
