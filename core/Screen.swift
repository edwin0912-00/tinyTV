// Screen to TV. The core on the core host serves every stream to the TV (owner's decision 2026-10-20), so:
//   Mac screen:    tinyTV on the Mac captures (ScreenCaptureKit) -> ffmpeg h264_videotoolbox -> MPEG-TS over TCP to the core host :8893
//   the core host screen: the core captures the same way and sends to its own :8893
// LiveRelay on the core host keeps the newest seconds in memory and serves the TV from the latest keyframe (live edge),
// not from the start of the stream, so the delay does not grow with the stream's age.
import Foundation
import Network
import ScreenCaptureKit
import CoreMedia

/// Owner: "треба різні режими мати, з різними затримками і якістю". Latency measured per preset in DECISIONS.md.
struct ScreenPreset {
    let id: String, label: String
    let maxW: Double, maxH: Double, fps: Int, codec: String, mbps: Int, gop: Int, mux: String
    static let all = [
        ScreenPreset(id: "fast", label: "Fast", maxW: 1280, maxH: 720, fps: 30, codec: "h264_videotoolbox", mbps: 4, gop: 15, mux: "6M"),
        ScreenPreset(id: "balanced", label: "Balanced", maxW: 1920, maxH: 1080, fps: 30, codec: "h264_videotoolbox", mbps: 12, gop: 30, mux: "10M"),
        ScreenPreset(id: "quality", label: "Quality", maxW: 3840, maxH: 2160, fps: 30, codec: "hevc_videotoolbox", mbps: 25, gop: 60, mux: "30M"),
    ]
    static func named(_ id: String) -> ScreenPreset { all.first { $0.id == id } ?? all[1] }
}

/// One capture session: screen, window or a new virtual display (extend) with system audio, or system audio alone.
final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    enum Mode: String { case mirror, extend, audio }
    private var fps = 30
    private var stream: SCStream?
    private var ff: Process?
    private var video: FileHandle?
    private var audio: FileHandle?
    private var fifo = ""
    private let q = DispatchQueue(label: "tinytv.screen.out")
    /// Audio has its own queue and clock: a video write blocked by ffmpeg must never stall audio, or both wait forever.
    private let aq = DispatchQueue(label: "tinytv.screen.audio")
    private var audioTimer: DispatchSourceTimer?
    private let lock = NSLock()
    private var frame: CVPixelBuffer?
    private var timer: DispatchSourceTimer?
    private var start = Date()
    private var samples = 0          // audio frames written (48 kHz)
    private var size = (w: 0, h: 0)
    var onEnd: (@Sendable (String?) -> Void)?
    private var virtualDisplay = false
    private var frames = 0
    var running: Bool { ff?.isRunning == true }

    /// Windows that can be shown on the TV: on screen, titled, not tiny, not our own.
    static func windows() async -> [(id: UInt32, title: String)] {
        guard let c = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return [] }
        return c.windows.filter { w in
            w.windowLayer == 0 && w.frame.width > 300 && w.frame.height > 200
                && w.owningApplication?.bundleIdentifier.hasPrefix("dev.tinytv") != true
        }.map { w in
            let app = w.owningApplication?.applicationName ?? ""
            let t = w.title ?? ""
            return (w.windowID, t.isEmpty ? app : "\(app) · \(t)")
        }
    }

    /// `to`: "host:port" of the relay. `window`: a window id, or nil for the main display.
    func start(window: UInt32?, mode: Mode = .mirror, preset: ScreenPreset, to dest: String, ffmpeg: String) async throws {
        signal(SIGPIPE, SIG_IGN)   // a dead ffmpeg must fail the write, not kill tinyTV
        fps = preset.fps
        var content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let cfg = SCStreamConfiguration()
        let filter: SCContentFilter
        var w: Double, h: Double
        if mode == .extend {
            // The TV as a second display: a 1920x1080-point HiDPI virtual display (same private API as kindle-screen).
            let id = tinytv_vd_create(1920, 1080)
            guard id != 0 else { throw NSError(domain: "tinyTV", code: 3, userInfo: [NSLocalizedDescriptionKey: "Can't add a display"]) }
            virtualDisplay = true
            for _ in 0..<20 where !content.displays.contains(where: { $0.displayID == id }) {
                try? await Task.sleep(nanoseconds: 250_000_000)
                content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            }
            guard let d = content.displays.first(where: { $0.displayID == id }) else {
                throw NSError(domain: "tinyTV", code: 3, userInfo: [NSLocalizedDescriptionKey: "The new display didn't appear"])
            }
            filter = SCContentFilter(display: d, excludingWindows: [])
            w = 3840; h = 2160
            if let m = CGDisplayCopyDisplayMode(id) { w = Double(m.pixelWidth); h = Double(m.pixelHeight) }
        } else if let window, let win = content.windows.first(where: { $0.windowID == window }) {
            filter = SCContentFilter(desktopIndependentWindow: win)
            w = win.frame.width * 2; h = win.frame.height * 2
        } else {
            var displays = content.displays
            if displays.isEmpty {
                // Lid closed, no monitor (the core host): add a 1280x720-point HiDPI display for the TV, removed on stop.
                let id = tinytv_vd_create(1280, 720)
                virtualDisplay = id != 0
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                displays = (try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true))?.displays ?? []
                NSLog("tinyTV screen: virtual display %u, %d displays", id, displays.count)
            }
            guard let d = displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? displays.first else {
                throw NSError(domain: "tinyTV", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display"])
            }
            // Nothing excluded: the delay clock (a tinyTV window) must reach the TV.
            filter = SCContentFilter(display: d, excludingWindows: [])
            w = Double(CGDisplayPixelsWide(d.displayID)); h = Double(CGDisplayPixelsHigh(d.displayID))
            if let mode = CGDisplayCopyDisplayMode(d.displayID) { w = Double(mode.pixelWidth); h = Double(mode.pixelHeight) }
        }
        // Fit into the preset's size, even sizes (NV12 + H.264/HEVC).
        let k = min(1, preset.maxW / w, preset.maxH / h)
        size = (Int(w * k / 2) * 2, Int(h * k / 2) * 2)
        cfg.width = size.w; cfg.height = size.h
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        if mode == .audio { cfg.width = 64; cfg.height = 64; cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1) }
        cfg.queueDepth = 4
        cfg.showsCursor = true
        cfg.capturesAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 2
        cfg.excludesCurrentProcessAudio = true

        // Audio goes through a FIFO, video through stdin.
        fifo = NSTemporaryDirectory() + "tinytv-audio-\(UUID().uuidString.prefix(8)).f32"
        unlink(fifo); mkfifo(fifo, 0o600)
        let p = Process(); p.executableURL = URL(fileURLWithPath: ffmpeg)
        let audioIn = ["-f", "f32le", "-ar", "48000", "-ac", "2", "-thread_queue_size", "1024", "-i", fifo]
        if mode == .audio {
            // Audio alone: AAC in ADTS, sent raw through the relay; the TV plays it as audio/aac.
            p.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin"] + audioIn
                + ["-c:a", "aac", "-b:a", "192k", "-f", "adts", "-flush_packets", "1", "tcp://\(dest)"]
        } else {
            let tenBit = preset.codec.hasPrefix("hevc")
            let videoIn: [String] = ["-f", "rawvideo", "-pix_fmt", "nv12", "-s", "\(size.w)x\(size.h)", "-framerate", "\(fps)",
                                     "-thread_queue_size", "64", "-i", "pipe:0"]
            let enc: [String] = ["-c:v", preset.codec, "-realtime", "1", "-profile:v", tenBit ? "main" : "high",
                                 "-b:v", "\(preset.mbps)M", "-maxrate", "\(preset.mbps)M", "-bufsize", "\(max(1, preset.mbps / 6))M",
                                 "-g", "\(preset.gop)", "-bf", "0", "-c:a", "aac", "-b:a", "160k"]
            // Constant mux rate (null-packet padding): at the ~1.3 Mbit/s of a still screen the TV paused to rebuffer.
            let mux: [String] = ["-f", "mpegts", "-muxdelay", "0", "-muxpreload", "0", "-flush_packets", "1",
                                 "-muxrate", TV.config["screen_muxrate"] ?? preset.mux, "tcp://\(dest)"]
            var args: [String] = ["-hide_banner", "-loglevel", "error", "-nostdin"]
            args += videoIn; args += audioIn; args += enc; args += mux
            p.arguments = args
        }
        let inPipe = Pipe(); p.standardInput = mode == .audio ? FileHandle.nullDevice : inPipe
        let err = Pipe(); p.standardError = err; p.standardOutput = FileHandle.nullDevice
        let tail = Tail()
        err.fileHandleForReading.readabilityHandler = { tail.add(String(decoding: $0.availableData, as: UTF8.self)) }
        p.terminationHandler = { [weak self] pr in
            err.fileHandleForReading.readabilityHandler = nil
            let msg = tail.text.trimmingCharacters(in: .whitespacesAndNewlines)
            NSLog("tinyTV screen ffmpeg ended %d %@", pr.terminationStatus, msg)
            self?.stop()
            self?.onEnd?(pr.terminationStatus == 0 || pr.terminationStatus == 15 ? nil : (msg.isEmpty ? "ffmpeg stopped" : msg))
        }
        try p.run()
        ff = p
        // Feed frames at once: ffmpeg reads the first video frames before it opens the audio FIFO.
        start = Date(); samples = 0
        if mode != .audio {
            video = inPipe.fileHandleForWriting
            let t = DispatchSource.makeTimerSource(queue: q)
            t.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / fps), leeway: .milliseconds(2))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume(); timer = t
        }
        let at = DispatchSource.makeTimerSource(queue: aq)
        at.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(5))
        at.setEventHandler { [weak self] in self?.fillSilence() }
        at.resume(); audioTimer = at
        // Opening a FIFO for writing blocks until ffmpeg opens it for reading.
        let path = fifo
        let fh: FileHandle? = await withCheckedContinuation { k in
            DispatchQueue.global().async { k.resume(returning: FileHandle(forWritingAtPath: path)) }
        }
        guard let fh, p.isRunning else { stop(); throw NSError(domain: "tinyTV", code: 2, userInfo: [NSLocalizedDescriptionKey: "ffmpeg didn't start"]) }
        lock.withLock { audio = fh; samples = 0 }   // the next fill writes silence back to the first video frame

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        if mode != .audio { try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "tinytv.screen.v")) }
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "tinytv.screen.a"))
        try await s.startCapture()
        stream = s
        q.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            // Mean and max luma of the newest frame: tells a dark desktop from a black (asleep) display.
            var mean = -1, peak = -1
            if let px = self.lock.withLock({ self.frame }) {
                CVPixelBufferLockBaseAddress(px, .readOnly)
                if let b = CVPixelBufferGetBaseAddressOfPlane(px, 0) {
                    let st = CVPixelBufferGetBytesPerRowOfPlane(px, 0), h = CVPixelBufferGetHeightOfPlane(px, 0), w = CVPixelBufferGetWidthOfPlane(px, 0)
                    var sum = 0, n = 0, mx = 0
                    for y in Swift.stride(from: 0, to: h, by: 8) { for x in Swift.stride(from: 0, to: w, by: 8) {
                        let v = Int(b.load(fromByteOffset: y * st + x, as: UInt8.self)); sum += v; n += 1; mx = max(mx, v) } }
                    mean = n > 0 ? sum / n : -1; peak = mx
                }
                CVPixelBufferUnlockBaseAddress(px, .readOnly)
            }
            NSLog("tinyTV screen: %d frames in 3 s, %dx%d, %@, luma mean %d max %d", self.lock.withLock { self.frames }, self.size.w, self.size.h,
                  mode == .mirror ? (window.map { "window \($0)" } ?? "main display") : mode.rawValue, mean, peak)
        }
    }

    /// Order matters: ffmpeg dies first, so writes blocked on its pipes fail at once; FileHandle.close
    /// waits for a blocked write and would hang the caller (it hung the core's main thread once).
    func stop() {
        timer?.cancel(); timer = nil
        audioTimer?.cancel(); audioTimer = nil
        let s = stream; stream = nil
        Task { try? await s?.stopCapture() }
        // SIGKILL follows if ffmpeg is stuck (blocked in open or write) and ignores SIGTERM.
        if let p = ff, p.isRunning {
            p.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        }
        ff = nil
        let v = video, a = audio, path = fifo
        video = nil; lock.withLock { audio = nil }
        DispatchQueue.global().async {
            // A writer still waiting in open() on the FIFO is released by a reader.
            if !path.isEmpty { let fd = open(path, O_RDONLY | O_NONBLOCK); if fd >= 0 { close(fd) }; unlink(path) }
            try? v?.close(); try? a?.close()
        }
        if virtualDisplay { virtualDisplay = false; DispatchQueue.main.async { tinytv_vd_destroy() } }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("tinyTV screen capture stopped: %@", error.localizedDescription)
        q.async { [weak self] in self?.stop(); self?.onEnd?(error.localizedDescription) }
    }

    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            guard let px = sb.imageBuffer else { return }  // idle frames carry no pixels
            lock.lock(); frame = px; frames += 1; lock.unlock()
        case .audio:
            writeAudio(sb)
        default: break
        }
    }

    private func tick() {
        guard let video else { return }
        lock.lock(); let px = frame; lock.unlock()
        var out = Data(capacity: size.w * size.h * 3 / 2)
        if let px, CVPixelBufferGetWidth(px) == size.w, CVPixelBufferGetHeight(px) == size.h {
            CVPixelBufferLockBaseAddress(px, .readOnly)
            for plane in 0..<2 {
                guard let base = CVPixelBufferGetBaseAddressOfPlane(px, plane) else { continue }
                let stride = CVPixelBufferGetBytesPerRowOfPlane(px, plane)
                let rows = plane == 0 ? size.h : size.h / 2
                for r in 0..<rows { out.append(base.advanced(by: r * stride).assumingMemoryBound(to: UInt8.self), count: size.w) }
            }
            CVPixelBufferUnlockBaseAddress(px, .readOnly)
        } else {
            // No frame yet: black (Y 16, UV 128).
            out.append(Data(repeating: 16, count: size.w * size.h))
            out.append(Data(repeating: 128, count: size.w * size.h / 2))
        }
        try? video.write(contentsOf: out)
    }

    /// Keeps audio on the wall clock: silence fills gaps (SCK sends nothing while the machine is quiet).
    private func fillSilence() {
        let due = Int(Date().timeIntervalSince(start) * 48000)
        lock.lock(); let gap = due - samples; let open = audio != nil; lock.unlock()
        if open, gap > 4800 { writePCM(Data(count: gap * 8), frames: gap) }
    }

    private func writeAudio(_ sb: CMSampleBuffer) {
        let n = CMSampleBufferGetNumSamples(sb)
        // SCK delivers non-interleaved float32: one buffer per channel. A one-buffer list fails silently
        // (the stream carried only the silence fill, measured at -91 dB), so size it for two.
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(list.unsafeMutablePointer) }
        var block: CMBlockBuffer?
        guard n > 0, CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil, bufferListOut: list.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: 2),
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block) == noErr else { return }
        var data = Data(count: n * 8)
        data.withUnsafeMutableBytes { raw in
            let o = raw.bindMemory(to: Float.self)
            if list.count >= 2, let l = list[0].mData?.assumingMemoryBound(to: Float.self), let r = list[1].mData?.assumingMemoryBound(to: Float.self) {
                for i in 0..<n { o[2 * i] = l[i]; o[2 * i + 1] = r[i] }
            } else if let m = list[0].mData?.assumingMemoryBound(to: Float.self) {
                let ch = Int(list[0].mNumberChannels)
                for i in 0..<n { o[2 * i] = m[i * ch]; o[2 * i + 1] = m[i * ch + (ch > 1 ? 1 : 0)] }
            }
        }
        // Too far ahead of the clock (after a silence fill): drop rather than drift.
        let due = Int(Date().timeIntervalSince(start) * 48000)
        lock.lock(); let ahead = samples - due; lock.unlock()
        if ahead > 9600 { return }
        writePCM(data, frames: n)
    }

    private func writePCM(_ d: Data, frames: Int) {
        lock.lock(); samples += frames; let a = audio; lock.unlock()
        aq.async { try? a?.write(contentsOf: d) }
    }
}

/// the core host :8893 accepts one MPEG-TS stream at a time (from the Mac or the core itself) and fans it out to the TV.
/// Only LAN and tailnet peers may send.
final class LiveRelay: @unchecked Sendable {
    static let shared = LiveRelay()
    static let port: NWEndpoint.Port = 8893
    private let q = DispatchQueue(label: "tinytv.relay")
    private var listener: NWListener?
    private var source: NWConnection?
    private var chunks: [(at: Int, data: Data)] = []
    private var end = 0                       // absolute byte count received
    private var keyAt: Int?                   // absolute offset of the newest keyframe packet
    private var pat: Data?, pmt: Data?
    private var carry = Data()
    private(set) var generation = 0
    /// Seconds from capture to bytes on the core host are tiny; this tracks when the last bytes arrived.
    private(set) var lastData = Date.distantPast
    var live: Bool { q.sync { source != nil && keyAt != nil } }
    /// A live video stream (not the audio-only raw mode): what the TV page can remux.
    var video: Bool { q.sync { source != nil && keyAt != nil && !raw } }
    /// Raw mode (audio-only ADTS): no TS parsing, the TV starts at the newest byte.
    private var raw = false
    private var mime = "video/mp2ts"
    /// In-process readers (the TV page's fMP4 remux, LowLatency.swift). nil = this stream ended.
    private var taps: [Int: @Sendable (Data?) -> Void] = [:]
    private var tapN = 0

    /// A tap gets PAT + PMT, the bytes from the newest keyframe, then every new byte, on the relay queue (must not block).
    func tap(_ f: @escaping @Sendable (Data?) -> Void) -> Int? {
        q.sync {
            guard source != nil, !raw, let k = keyAt else { return nil }
            var d = (pat ?? Data()) + (pmt ?? Data())
            for c in chunks where c.at + c.data.count > k { d.append(c.data[(c.data.startIndex + max(0, k - c.at))...]) }
            f(d)
            tapN += 1; taps[tapN] = f
            return tapN
        }
    }
    func untap(_ id: Int) { q.async { self.taps[id] = nil } }
    private func endTaps() { let t = taps; taps = [:]; t.values.forEach { $0(nil) } }

    func start() {
        let p = NWParameters.tcp; p.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: p, on: LiveRelay.port) else { NSLog("tinyTV relay: cannot listen on 8893"); return }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: q); listener = l
    }

    private static func allowed(_ e: NWEndpoint) -> Bool {
        guard case .hostPort(let h, _) = e else { return false }
        let s = "\(h)".split(separator: "%").first.map(String.init) ?? ""
        if s == "127.0.0.1" || s == "::1" || s.hasPrefix("192.168.") || s.hasPrefix("10.") { return true }
        let o = s.split(separator: ".").compactMap { Int($0) }
        return o.count == 4 && o[0] == 100 && (64...127).contains(o[1])   // Tailscale CGNAT range
    }

    private func accept(_ c: NWConnection) {
        guard LiveRelay.allowed(c.endpoint) else { c.cancel(); return }
        source?.cancel(); endTaps()
        source = c; chunks = []; end = 0; keyAt = nil; pat = nil; pmt = nil; carry = Data(); generation += 1
        NSLog("tinyTV relay: stream from %@", "\(c.endpoint)")
        c.start(queue: q)
        let gen = generation
        func read() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) { [weak self] d, _, done, err in
                guard let self, self.generation == gen else { return }
                if let d, !d.isEmpty { self.ingest(d) }
                if done || err != nil { self.source = nil; self.endTaps(); NSLog("tinyTV relay: stream ended"); c.cancel(); return }
                read()
            }
        }
        read()
    }

    func reset(raw r: Bool = false) {
        q.sync { source?.cancel(); source = nil; endTaps(); generation += 1; chunks = []; end = 0; keyAt = nil; raw = r; mime = r ? "audio/aac" : "video/mp2ts" }
    }

    /// Stores bytes and notes PAT, PMT and keyframe packets (random access indicator on the video PID).
    private func ingest(_ d: Data) {
        if raw {
            chunks.append((end, d)); end += d.count; keyAt = end; lastData = Date()
            while let f = chunks.first, end - f.at > 2_000_000, chunks.count > 1 { chunks.removeFirst() }
            return
        }
        let all = carry + d
        let whole = all.count / 188 * 188
        let pk = all.prefix(whole)
        carry = all.suffix(from: all.startIndex + whole)
        guard !pk.isEmpty else { return }
        let base = end
        pk.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            var i = 0
            while i + 188 <= b.count {
                if b[i] == 0x47 {
                    let pid = (Int(b[i + 1]) & 0x1f) << 8 | Int(b[i + 2])
                    if pid == 0 { pat = Data(b[i..<i + 188]) }
                    else if pid == 0x1000 { pmt = Data(b[i..<i + 188]) }
                    else if pid == 0x100, (b[i + 3] >> 4) & 0x2 != 0, b[i + 4] > 0, b[i + 5] & 0x40 != 0 { keyAt = base + i }
                }
                i += 188
            }
        }
        chunks.append((base, Data(pk))); end += pk.count; lastData = Date()
        if !taps.isEmpty { let d = Data(pk); taps.values.forEach { $0(d) } }
        // Keep ~16 MB (about 10 s at 12 Mbit/s).
        while let f = chunks.first, end - f.at > 16_000_000, chunks.count > 1 { chunks.removeFirst() }
    }

    private func bytes(from: Int) -> Data? {
        guard from < end else { return nil }
        var out = Data()
        for c in chunks where c.at + c.data.count > from {
            let s = max(0, from - c.at)
            out.append(c.data[(c.data.startIndex + s)...])
            if out.count > 1 << 20 { break }
        }
        return out
    }

    /// A TV connection: headers, PAT + PMT, then from the newest keyframe on.
    func serve(_ c: NWConnection, head: Bool) {
        let h = "HTTP/1.1 200 OK\r\nContent-Type: \(q.sync { mime })\r\ntransferMode.dlna.org: Streaming\r\nConnection: close\r\n\r\n"
        c.send(content: Data(h.utf8), completion: .contentProcessed { _ in })
        if head { c.cancel(); return }
        q.async { [self] in
            let gen = generation
            var at = keyAt ?? end
            var sent = 0
            let t0 = Date()
            for s in 1...12 {
                q.asyncAfter(deadline: .now() + .seconds(s)) { NSLog("tinyTV relay: TV conn %.0fs sent %d KB (stream %d KB ahead)", Date().timeIntervalSince(t0), sent / 1000, (self.end - at) / 1000) }
            }
            let first = raw ? Data() : (pat ?? Data()) + (pmt ?? Data())
            if !first.isEmpty { c.send(content: first, completion: .contentProcessed { _ in }) }
            func pump() {
                guard generation == gen else { c.cancel(); return }
                if let d = bytes(from: at) {
                    at += d.count; sent += d.count
                    c.send(content: d, completion: .contentProcessed { [weak self] err in
                        if err != nil { c.cancel() } else { self?.q.async { pump() } }
                    })
                } else if source == nil {
                    c.cancel()
                } else {
                    q.asyncAfter(deadline: .now() + .milliseconds(10)) { pump() }
                }
            }
            pump()
        }
    }
}
