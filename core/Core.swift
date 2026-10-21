// tinyTV core: headless, runs permanently on an always-on Mac (the "core host") as a LaunchAgent.
// Holds the only MQTT client, casting, the LAN media server :8892 and the phone API :8891.
import AppKit

@main
struct TinyTVCore {
    static func main() {
        // Tools copied by scripts/copy-tools.py (optional): OpenSSL must not read a Homebrew etc on an external disk.
        let etc = NSHomeDirectory() + "/tinyTV/tools/etc"
        if FileManager.default.fileExists(atPath: etc) {
            setenv("OPENSSL_CONF", etc + "/openssl.cnf", 1); setenv("SSL_CERT_FILE", etc + "/cert.pem", 1)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        MainActor.assumeIsolated {
            Providers.registerAll()
            _ = TV.shared
            NSLog("tinyTV core up: TV %@, phone API 127.0.0.1:8891, media :8892, client cert %@", TV.shared.host,
                  MQTT.identity() == nil ? "MISSING" : "loaded")
        }
        app.run()
    }
}
