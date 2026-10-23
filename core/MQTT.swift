// Minimal MQTT 3.1.1 client over TLS (QoS 0 only) for the Hisense VIDAA broker on :36669.
// The TV asks for a client certificate (RemoteNOW, bundled as remotenow.p12) and uses a self-signed CA.
import Foundation
import Network
import Security

final class MQTT {
    static let trace = CommandLine.arguments.contains("--trace")
    var onMessage: ((String, Data) -> Void)?
    var onState: ((Bool) -> Void)?
    private var conn: NWConnection?
    private var buf = Data()
    private let q = DispatchQueue(label: "tinytv.mqtt")
    private var pinger: DispatchSourceTimer?
    /// Last byte from the TV. A sleeping TV or a dead Wi-Fi link leaves a half-open socket that never errors.
    private var lastRx = Date()
    private let host: String, clientID: String, user: String, pass: String

    init(host: String, clientID: String, user: String, pass: String) {
        self.host = host; self.clientID = clientID; self.user = user; self.pass = pass
    }

    static func identity() -> SecIdentity? {
        guard let url = Bundle.main.url(forResource: "remotenow", withExtension: "p12"),
              let data = try? Data(contentsOf: url) else { return nil }
        var items: CFArray?
        let st = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: "tinytv"] as CFDictionary, &items)
        guard st == errSecSuccess, let arr = items as? [[String: Any]], let first = arr.first,
              let id = first[kSecImportItemIdentity as String] else { return nil }
        return (id as! SecIdentity)
    }

    func connect() {
        let tls = NWProtocolTLS.Options()
        let so = tls.securityProtocolOptions
        if let id = MQTT.identity(), let sid = sec_identity_create(id) { sec_protocol_options_set_local_identity(so, sid) }
        sec_protocol_options_set_min_tls_protocol_version(so, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(so, .TLSv12)
        // The TV's CA is self-signed and the cert names 127.0.0.1: trust it on the LAN.
        sec_protocol_options_set_verify_block(so, { _, _, done in done(true) }, q)
        let c = NWConnection(host: NWEndpoint.Host(host), port: 36669, using: NWParameters(tls: tls))
        conn = c; buf.removeAll(); lastRx = Date()
        c.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            if MQTT.trace { NSLog("tinyTV mqtt state %@", String(describing: st)) }
            switch st {
            case .ready: self.sendConnect(); self.receive()
            case .failed, .cancelled: self.drop()
            default: break
            }
        }
        c.start(queue: q)
        // A sleeping TV never refuses: the connection just waits. Give up after 6 s and retry.
        q.asyncAfter(deadline: .now() + 6) { [weak self, weak c] in
            guard let self, let c, self.conn === c, c.state != .ready else { return }
            c.cancel()
        }
    }

    private func drop() {
        pinger?.cancel(); pinger = nil
        conn?.cancel(); conn = nil
        onState?(false)
        q.asyncAfter(deadline: .now() + 3) { [weak self] in if self?.conn == nil { self?.connect() } }
    }

    func publish(_ topic: String, _ payload: String = "") {
        var v = str(topic); v.append(payload.data(using: .utf8)!)
        send(0x30, v)
    }

    func subscribe(_ topic: String) {
        var v = Data([0, 1]); v.append(str(topic)); v.append(0)
        send(0x82, v)
    }

    // MARK: wire format

    private func str(_ s: String) -> Data {
        let d = s.data(using: .utf8)!
        return Data([UInt8(d.count >> 8), UInt8(d.count & 0xff)]) + d
    }

    private func send(_ header: UInt8, _ body: Data) {
        var p = Data([header]); var n = body.count
        repeat { var b = UInt8(n % 128); n /= 128; if n > 0 { b |= 0x80 }; p.append(b) } while n > 0
        p.append(body)
        conn?.send(content: p, completion: .contentProcessed { _ in })
    }

    private func sendConnect() {
        var v = str("MQTT"); v.append(contentsOf: [4, 0xC2, 0, 60])  // v3.1.1, user+pass+clean, keepalive 60 s
        v.append(str(clientID)); v.append(str(user)); v.append(str(pass))
        send(0x10, v)
    }

    private func receive() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] d, _, done, err in
            guard let self else { return }
            if let d { self.lastRx = Date(); self.buf.append(d); self.parse() }
            if done || err != nil { self.drop() } else { self.receive() }
        }
    }

    private func parse() {
        while buf.count >= 2 {
            var mult = 1, len = 0, i = 1
            while true {
                guard i < buf.count else { return }
                let b = Int(buf[buf.startIndex + i]); len += (b & 0x7f) * mult; mult *= 128; i += 1
                if b & 0x80 == 0 { break }
            }
            guard buf.count >= i + len else { return }
            let h = buf[buf.startIndex], body = buf.subdata(in: buf.startIndex + i ..< buf.startIndex + i + len)
            buf = buf.subdata(in: buf.startIndex + i + len ..< buf.endIndex)
            switch h >> 4 {
            case 2:  // CONNACK
                if MQTT.trace { NSLog("tinyTV connack %@", body as NSData) }
                let ok = body.count >= 2 && body[body.startIndex + 1] == 0
                if ok { startPing() }
                onState?(ok)
            case 3:  // PUBLISH (QoS 0 from the TV)
                guard body.count >= 2 else { continue }
                let tl = Int(body[body.startIndex]) << 8 | Int(body[body.startIndex + 1])
                guard body.count >= 2 + tl else { continue }
                var off = 2 + tl
                if (h >> 1) & 3 > 0 { off += 2 }
                let topic = String(decoding: body.subdata(in: body.startIndex + 2 ..< body.startIndex + 2 + tl), as: UTF8.self)
                let payload = body.subdata(in: body.startIndex + min(off, body.count) ..< body.endIndex)
                onMessage?(topic, payload)
            default: break
            }
        }
    }

    private func startPing() {
        pinger?.cancel()
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 15, repeating: 15)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            // No reply (not even to the previous ping) for 45 s: the link is dead, reconnect.
            if Date().timeIntervalSince(self.lastRx) > 45 { if MQTT.trace { NSLog("tinyTV mqtt watchdog: reconnect") }; self.conn?.cancel(); return }
            self.send(0xC0, Data())
        }
        t.resume(); pinger = t
    }
}
