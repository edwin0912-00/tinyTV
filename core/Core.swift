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
