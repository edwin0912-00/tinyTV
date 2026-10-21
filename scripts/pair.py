"""Pair this Mac with the Hisense VIDAA TV (standard profile, RemoteNOW cert).

Connects, asks the TV to show a PIN, waits for the PIN in $TINYTV_DIR/pin.txt,
sends it, requests tokens and saves them to $TINYTV_DIR/state/session.json.
Usage: python3 scripts/pair.py TV_IP     (TINYTV_DIR defaults to ~/.tinytv)
Needs: pip install paho-mqtt; the certificate pair in $TINYTV_DIR/certs (docs/hisense-pairing.md);
git clone https://github.com/stevene1919/hisense_vidaa $TINYTV_DIR/vendor/hisense_vidaa
Credential math is taken from github.com/stevene1919/hisense_vidaa (MIT).
"""
import json, os, re, ssl, sys, time, uuid, pathlib
import paho.mqtt.client as mqtt

ROOT = pathlib.Path(os.environ.get("TINYTV_DIR", pathlib.Path.home() / ".tinytv"))
SRC = ROOT / "vendor/hisense_vidaa/custom_components/hisense_vidaa/crypto.py"
ns = {}
exec(SRC.read_text().split("from .protocol.certs import")[0], ns)

TV = sys.argv[1] if len(sys.argv) > 1 else sys.exit("usage: pair.py TV_IP")
MAC = ":".join(re.findall("..", f"{uuid.getnode():012x}"))
# Measured 2026-10-20: this TV accepts only the legacy static login (other profiles rc=5).
cid, user, pwd = os.environ.get("TINYTV_CLIENT_ID", "tinytv_core"), "hisenseservice", "multimqttservice"
ui, ps, mob = (f"/remoteapp/tv/ui_service/{cid}/", f"/remoteapp/tv/platform_service/{cid}/",
               f"/remoteapp/mobile/{cid}/")
PIN = ROOT / "pin.txt"
OUT = ROOT / "state"; OUT.mkdir(exist_ok=True)
log = lambda *a: print(time.strftime("%H:%M:%S"), *a, flush=True)
state = {"rc": None, "auth": None, "token": None}

def on_connect(c, u, f, rc, *a):
    state["rc"] = rc; log("connect rc", rc, "client_id", cid)
    c.subscribe([(mob + "#", 0), ("/remoteapp/mobile/broadcast/#", 0)])
    c.publish(ui + "actions/gettvstate", "")

def on_message(c, u, m):
    p = m.payload.decode(errors="replace")
    log("<", m.topic, p[:300])
    if m.topic.endswith("ui_service/data/authenticationcode"):
        state["auth"] = p
    if m.topic.endswith("platform_service/data/tokenissuance"):
        state["token"] = p

c = mqtt.Client(mqtt.CallbackAPIVersion.VERSION1, client_id=cid, protocol=mqtt.MQTTv311)
c.tls_set(certfile=str(ROOT / "certs/rcm_certchain_pem.cer"),
          keyfile=str(ROOT / "certs/rcm_pem_privkey.pkcs8"), cert_reqs=ssl.CERT_NONE)
c.tls_insecure_set(True)
c.username_pw_set(user, pwd)
c.on_connect, c.on_message = on_connect, on_message
c.connect(TV, 36669, 30); c.loop_start()

PIN.unlink(missing_ok=True)
deadline = time.time() + 600
log("waiting for PIN in", PIN)
while time.time() < deadline and not PIN.exists():
    if state["rc"] not in (None, 0): sys.exit(f"broker refused rc={state['rc']}")
    time.sleep(0.3)
if not PIN.exists(): sys.exit("no PIN within 10 min")
pin = PIN.read_text().strip()
c.publish(ui + "actions/authenticationcode", json.dumps({"authNum": int(pin)}))
log("> PIN sent")
for _ in range(50):
    if state["auth"]: break
    time.sleep(0.2)
log("auth reply:", state["auth"])
c.publish(ps + "data/gettoken", '{"refreshtoken": ""}')
c.publish(ui + "actions/authenticationcodeclose", "")
for _ in range(75):
    if state["token"]: break
    time.sleep(0.2)
(OUT / "session.json").write_text(json.dumps(
    {"tv": TV, "mac": MAC, "client_id": cid, "auth": state["auth"], "token": state["token"]}, indent=1))
log("saved", OUT / "session.json", "token" if state["token"] else "NO TOKEN")
c.loop_stop(); c.disconnect()
