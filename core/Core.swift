// tinyTV core: headless, runs permanently on core host as a LaunchAgent (owner's decision 2026-10-20).
// Holds the only MQTT client (tinytv_core), casting, the LAN media server :8892 and the phone API :8891.
import AppKit

@main
struct TinyTVCore {
    static func main() {
        // Tools copied by copy-tools.py: OpenSSL must not read /opt/homebrew/etc (external disk, unreadable here).
        let etc = NSHomeDirectory() + "/tinyTV/tools/etc"
        if FileManager.default.fileExists(atPath: etc) {
            setenv("OPENSSL_CONF", etc + "/openssl.cnf", 1); setenv("SSL_CERT_FILE", etc + "/cert.pem", 1)
        }
        // A restart leaves the old core's jobs running (2026-10-24: 6 ffmpeg up to a day old holding ~10 GB of deleted
        // .ts and the Wi-Fi; 5 keeper.py racing on one state file): stop ours that lost their parent, drop old streams.
        // keeper.py first: its running mux (ffmpeg, audiosync.py) becomes an orphan and goes with the next two patterns.
        for pat in ["tinyTVCore.app/Contents/Resources/keeper.py", NSHomeDirectory() + "/tinyTV/tools/bin/ffmpeg", "tinyTVCore.app/Contents/Resources/audiosync.py"] {
            let ps = Process(); ps.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            ps.arguments = ["-P", "1", "-f", pat]; try? ps.run(); ps.waitUntilExit()
        }
        let cache = NSHomeDirectory() + "/Library/Caches/tinyTV"
        for f in (try? FileManager.default.contentsOfDirectory(atPath: cache)) ?? [] where f.hasPrefix("live-") && f.hasSuffix(".ts") {
            try? FileManager.default.removeItem(atPath: cache + "/" + f)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        MainActor.assumeIsolated {
            _ = TV.shared
            NSLog("tinyTV core up: TV %@, phone API 127.0.0.1:8891, media :8892, client cert %@", TV.shared.host,
                  MQTT.identity() == nil ? "MISSING" : "loaded")
        }
        app.run()
    }
}
