// Link -> TV. Measured on 55A56EEVS: the TV ignores URLs in launchapp and in the browser address bar,
// cannot fetch HTTPS media itself, but plays HTTP media pushed over DLNA (MP4, MKV, TS, WebM...)
// after a consent dialog that KEY_OK accepts. So the Mac is always the HTTP source:
//   direct media URL  -> Mac proxies it with Range (seekable at once)
//   YouTube / web page -> yt-dlp finds the streams, ffmpeg joins them live into MPEG-TS (starts in seconds)
//   magnet / .torrent  -> TV Cast engine (~/TVCast, :8890) streams the original file with Range
//   local file         -> served from disk with Range
import Foundation
import Network
import CoreAudio

/// How video goes to the TV. Saved; applies to the next cast and restarts a live one.
struct VideoSettings: Codable, Equatable {
    /// "auto": re-encode only heavy or oversized files; "original": never; "encode": always.
    var mode = "auto"
    var height = 1080          // 2160, 1440, 1080, 720
    var hdr = true             // true: HEVC Main10 keeping HDR10; false: 8-bit SDR (HDR tone-mapped on the GPU)
    var mbps = 10.0            // measured: the TV's Wi-Fi pulls ~48 Mbit/s

    static let key = "videoSettings"
    static func load() -> VideoSettings {
        (UserDefaults.standard.data(forKey: key)).flatMap { try? JSONDecoder().decode(VideoSettings.self, from: $0) } ?? VideoSettings()
    }
    func save() { if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: VideoSettings.key) } }
}

/// Sound to the TV (owner: TV speakers in another room, too much treble): an equalizer in ffmpeg on the core.
/// Five bands (Hz) in dB, presets editable; "flat" = off (sound passes untouched).
struct SoundSettings: Codable, Equatable {
    static let freqs = [60, 250, 1000, 4000, 12000]
    static let presets: [String: [Double]] = ["flat": [0, 0, 0, 0, 0], "soft": [0, 0, 0, -4, -8], "dialog": [-4, -1, 3, 2, -3],
                                               "night": [-6, 0, 2, 1, -4], "bass": [6, 2, 0, 0, -2], "tv": [0, 0, 0, 0, 0]]
    /// The TV's own volume (0-100): the "tv" preset follows it.
    nonisolated(unsafe) static var volume: Double = 30
    var preset = "flat"
    var custom: [Double] = [0, 0, 0, 0, 0]
    var bands: [Double] { preset == "custom" ? custom : preset == "tv" ? tv.bands : (SoundSettings.presets[preset] ?? [0, 0, 0, 0, 0]) }
    var on: Bool { preset == "tv" || bands.contains { $0 != 0 } }

    /// "Динаміки ТВ": the Hisense 55A56E has two small full-range drivers (~2 x 12 W, no woofer). Cheap small drivers:
    /// below ~100 Hz they only distort, 300-500 Hz is the box resonance ("boxy"), 2.5-4 kHz the cone break-up (harsh),
    /// 6-8 kHz sibilance. Quiet listening loses bass and dialogue (equal-loudness curves), loud listening overdrives the
    /// lows: quiet = a bit more body, loud = higher low cut and softer top. t: 0 at volume <= 10, 1 at >= 50.
    /// A starting point, not a measurement of this room: a phone-mic sweep would tune it.
    var tv: (hp: Int, bands: [Double], x: [Double]) {
        let t = min(1, max(0, (SoundSettings.volume - 10) / 40))
        func lerp(_ a: Double, _ b: Double) -> Double { ((a + (b - a) * t) * 2).rounded() / 2 }
        return (Int(90 + 40 * t), [0, lerp(2, -1), 1.5, lerp(-1, -2), lerp(-2, -5)], [-3, lerp(-2, -4), -4])
    }
    /// Extra bands for the small speakers (box 400 Hz, harsh 3 kHz, sibilance 7 kHz) and a low cut; flat unless "tv".
    static let xfreqs = [400, 3000, 7000]
    var hp: Int { preset == "tv" ? tv.hp : 20 }
    var xbands: [Double] { preset == "tv" ? tv.x : [0, 0, 0] }

    /// ffmpeg -af chain with named filters: every band and the compressor stay in the chain (0 dB, ratio 1, low cut 20 Hz)
    /// so a change goes to the running ffmpeg as a command, without a restart (owner: "EQ must change live").
    var chain: String {
        "highpass@hp=f=\(hp):p=2," +
        zip(SoundSettings.freqs, bands).enumerated().map { "equalizer@b\($0.offset)=f=\($0.element.0):t=o:w=1.2:g=\($0.element.1)" }.joined(separator: ",") + "," +
        zip(SoundSettings.xfreqs, xbands).enumerated().map { "equalizer@x\($0.offset)=f=\($0.element.0):t=o:w=1:g=\($0.element.1)" }.joined(separator: ",") +
        ",acompressor@c=threshold=-22dB:ratio=\(ratio):attack=5:release=250,alimiter=limit=0.95"
    }
    var ratio: Double { preset == "night" ? 4 : preset == "tv" ? 2 : 1 }
    /// Lines for ffmpeg's stdin ("c<target> <time> <command> <arg>"), measured live on ffmpeg 8.1.1 (2026-10-21).
    var commands: String {
        "chighpass@hp -1 f \(hp)\n" + bands.enumerated().map { "cequalizer@b\($0.offset) -1 g \($0.element)\n" }.joined()
            + xbands.enumerated().map { "cequalizer@x\($0.offset) -1 g \($0.element)\n" }.joined() + "cacompressor@c -1 ratio \(ratio)\n"
    }
    static let key = "soundSettings"
    static func load() -> SoundSettings {
        (UserDefaults.standard.data(forKey: key)).flatMap { try? JSONDecoder().decode(SoundSettings.self, from: $0) } ?? SoundSettings()
    }
    func save() { if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: SoundSettings.key) } }
}

@MainActor
final class Caster: ObservableObject {
    static let shared = Caster()
    /// Empty when idle. Otherwise a short status for the UI.
    @Published var status = ""
    /// 0...1 while preparing, nil otherwise.
    @Published var progress: Double?
    @Published var failed = false
    /// What the TV is playing from us, with live position from DLNA.
    @Published var title = ""
    /// The link the owner opened (before HDRezka / yt-dlp resolve it): what "+" saves.
    @Published var link = ""
    @Published var playing = false { didSet { if playing != oldValue, !remote { MovieLight.shared.castChanged(playing: playing) } } }
    /// Screen stream the core wants: "" none, "mac" (the Mac remote sends it), "core" (the core captures its own screen).
    @Published var screen = ""
    @Published var screenWindow: UInt32?
    /// End-to-end delay measured with the owner (photo of Mac clock vs TV). Saved.
    @Published var screenLatency = UserDefaults.standard.double(forKey: "screenLatency") {
        didSet { UserDefaults.standard.set(screenLatency, forKey: "screenLatency") }
    }
    private var capture: ScreenCapture?
    /// Screen stream preset (Screen.swift ScreenPreset): "fast", "balanced", "quality". Saved; a change restarts the stream.
    @Published var screenPreset = UserDefaults.standard.string(forKey: "screenPreset") ?? "balanced" { didSet {
        guard screenPreset != oldValue else { return }
        UserDefaults.standard.set(screenPreset, forKey: "screenPreset")
        if remote { if !applying { Remote.post("screen/preset", ["id": screenPreset]) } }
        else if !screen.isEmpty { startScreen(screen, window: screenWindow) }
    } }
    /// Movie light toggle (see Light.swift), mirrored on a remote.
    @Published var movieLight = MovieLight.shared.on { didSet {
        guard movieLight != oldValue else { return }
        if !remote { MovieLight.shared.on = movieLight } else if !applying { Remote.post("movie", ["on": movieLight]) }
    } }
    func applyMovie(_ on: Bool) { applying = true; if on != movieLight { movieLight = on }; applying = false }
    @Published var position: Double = 0
    @Published var duration: Double = 0
    /// Magnet on the TV: engine numbers for the cards - down / rate in bytes per second, ahead and wait in seconds.
    @Published var torrent: [String: Double] = [:]
    private var engineCast = false
    private var bufferHold = false
    @Published var sound = SoundSettings.load() { didSet {
        guard sound != oldValue else { return }
        sound.save()
        if remote { if !applying { Remote.post("sound", ["preset": sound.preset, "custom": sound.custom]) }; return }
        // Apply 1.2 s after the last change (a dragged slider): a stream through ffmpeg restarts at the same second,
        // a direct torrent or file switches to our remux.
        soundApply?.cancel()
        soundApply = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, !self.title.isEmpty, let ff = Caster.tool("ffmpeg") else { return }
            let at = self.displayPosition
            // A running ffmpeg already has the chain: change it in place, the sound never stops.
            if self.liveJob != nil, self.jobEQ, let i = self.jobIn, self.job?.isRunning == true {
                try? i.fileHandleForWriting.write(contentsOf: Data(self.sound.commands.utf8)); return
            }
            if let j = self.liveJob { return self.live(j.ff, inputs: j.inputs, scale: j.scale, from: at) }
            if self.engineCast || self.currentFile != nil { self.live(ff, inputs: [self.currentFile ?? Caster.engineStream], scale: nil, from: at) }
        }
    } }
    private var soundApply: Task<Void, Never>?
    @Published var video = VideoSettings.load() { didSet {
        guard video != oldValue else { return }
        video.save()
        if !remote { return reapply() }
        if !applying { Remote.post("settings", ["mode": video.mode, "height": video.height, "hdr": video.hdr, "mbps": video.mbps]) }
    } }
    /// This Mac is a remote: casting runs in the core on core host (see Remote.swift).
    let remote = TV.config["core"] != nil
    private var applying = false
    /// Source picture, for building the encoder chain.
    private var src = (w: 0.0, h: 0.0, hdr: false, codec: "")
    /// A heavy torrent re-encoded for the TV's Wi-Fi (~48 Mbit/s measured) stays under 25 Mbit/s whatever the setting.
    private var heavyCap = false
    // Owner: "we can do 48". The TV's Wi-Fi measured ~48 Mbit/s and a 30 Mbit/s remux stuttered on its PEAKS, so:
    // average 35, peaks held to 42 (1.2x) with a 2 s buffer - more picture, no peak over the link.
    private var encodeMbps: Double { heavyCap ? min(video.mbps, 35) : video.mbps }
    /// Audio tracks of the current file (index among audio streams) and the chosen one.
    @Published var tracks: [(i: Int, label: String)] = []
    @Published var track = 0
    private var trackCodecs: [String] = []
    private var currentFile: String?
    private var remoteURL: String?   // a direct link the media server proxies to the TV
    /// What was cast, as given (page or stream link): a device plays it straight from the source ("Грати тут").
    private(set) var page = ""
    /// What the TV reads now: "Watch here" and the phone make their own HLS from the same source (owner 2026-10-22).
    var watchInputs: [String] {
        if let j = liveJob { return j.inputs }
        if let f = currentFile { return [f] }
        if engineCast { return [Caster.engineStream] }
        return remoteURL.map { [$0] } ?? []
    }
    /// The TV's own re-encode (growing TS) and the source second it starts at: "Watch here" copies it instead of a
    /// second 4K decode (TV 4K + Mac 1080p of 4K VP9 together ran 0.68x each, measured 2026-10-22).
    var watchLive: (path: String, offset: Double)? { liveJob?.scale != nil ? liveOut.map { ($0.path, offset) } : nil }
    weak var tv: TV?
    private var job: Process?
    private var jobIn: Pipe?
    private var jobEQ = false   // the running ffmpeg has the equalizer chain
    private var eqVolume: Double = -100   // the running ffmpeg's stdin: live equalizer commands
    private var poll: Task<Void, Never>?
    let media = MediaServer()
    private let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/tinyTV")

    init() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !remote { media.start(); LiveRelay.shared.start(); watchAirPlayReceiver(); adoptEngineCast() }
    }

    /// After a core restart the TV may still play a torrent straight from the engine: take it back under control
    /// (card, buffer, position memory) instead of showing nothing.
    private func adoptEngineCast() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            let tv = self.tv ?? TV.shared
            guard title.isEmpty, let p = await DLNA.call(host: tv.host, "GetPositionInfo", ""), p.contains(":8890/stream"),
                  let u = URL(string: "http://127.0.0.1:8890/state"), let (d, _) = try? await URLSession.shared.data(from: u),
                  let st = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let name = st["fileName"] as? String, !name.isEmpty else { return }
            self.tv = tv; title = name; engineCast = true
            if let dur = (st["durationSec"] as? NSNumber)?.doubleValue, dur > 0 { duration = dur }
            engineTracks(); watch()
        }
    }

    // MARK: AirPlay -> TV (core on core host)

    /// Owner: AirPlay to "the core host" (macOS AirPlay Receiver) plays on the TV, the core host's speakers stay silent.
    var airplayToTV = UserDefaults.standard.object(forKey: "airplayToTV") as? Bool ?? true {
        didSet { UserDefaults.standard.set(airplayToTV, forKey: "airplayToTV") }
    }

    /// Our own AirPlay speaker "tinyTV" (shairport-sync on core host, ~/tinyTV/tools/bin) writes raw PCM into a FIFO and
    /// calls /api/airplay on play start and end. The macOS receiver was not usable: the phone did not see it and its
    /// sessions showed no socket on port 7000 (measured), so detection lives in shairport's hooks instead.
    nonisolated static let airplayFIFO = "/tmp/tinytv-airplay.pcm"

    /// The macOS AirPlay Receiver (AirPlay 2) plays through AirPlayXPCHelper. Measured: an iPhone did not stream to
    /// our classic shairport speaker, while capturing the core host's own sound works muted. So: when AirPlayXPCHelper
    /// outputs audio, send the core host's sound to the TV (core-audio mutes the speakers); ~6 s of silence stops it.
    private var receiverActive = false, receiverIdle = 0

    private func watchAirPlayReceiver() {
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task.detached {
                let playing = AudioOutput.isPlaying(processNamed: "AirPlayXPCHelper")
                await MainActor.run { Caster.shared.receiver(playing) }
            }
        }
    }

    private func receiver(_ playing: Bool) {
        if playing {
            receiverIdle = 0
            guard airplayToTV, !receiverActive, screen.isEmpty || screen == "core-audio" else { return }
            receiverActive = true
            NSLog("tinyTV airplay receiver: playing -> TV")
            if screen != "core-audio" { startScreen("core-audio") }
        } else if receiverActive {
            receiverIdle += 1
            guard receiverIdle >= 3 else { return }
            receiverActive = false
            NSLog("tinyTV airplay receiver: stopped")
            if screen == "core-audio" { stop() }
        }
    }

    func airplay(_ on: Bool) {
        if !on { if screen == "airplay" { stop() }; return }
        guard airplayToTV, let ff = Caster.tool("ffmpeg") else { return }
        job?.terminate(); job = nil; liveJob = nil; offset = 0; duration = 0; position = 0
        fetchers.forEach { $0.terminate() }; fetchers = []; fetching = false
        tracks = []; trackCodecs = []; track = 0; currentFile = nil; remoteURL = nil; page = ""
        endScreen()
        screen = "airplay"; title = "AirPlay"
        LiveRelay.shared.reset(raw: true)
        set("AirPlay на ТВ…", nil)
        let p = Process(); p.executableURL = URL(fileURLWithPath: ff)
        let input = Pipe(); p.standardInput = input
        p.arguments = ["-hide_banner", "-loglevel", "error", "-f", "s16le", "-ar", "44100", "-ac", "2", "-i", "pipe:0",
                       "-c:a", "aac", "-b:a", "256k", "-f", "adts", "-flush_packets", "1", "tcp://127.0.0.1:\(LiveRelay.port.rawValue)"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run(); job = p } catch { return fail("Не вдалося запустити AirPlay") }
        AirPlayPipe.shared.sink = input.fileHandleForWriting
        p.terminationHandler = { _ in AirPlayPipe.shared.sink = nil }
        Task {
            for _ in 0..<40 {
                if LiveRelay.shared.live || screen != "airplay" { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            guard screen == "airplay", LiveRelay.shared.live else { return fail("Від AirPlay немає звуку") }
            push(media.add(.live), ext: "aac")
        }
    }

    static func tool(_ name: String) -> String? {
        // ~/tinyTV/tools first: on core host Homebrew sits on an external disk that launchd services can't read (copy-tools.py).
        [NSHomeDirectory() + "/tinyTV/tools/bin/", "/opt/homebrew/bin/", "/usr/local/bin/", "/opt/homebrew/Caskroom/miniconda/base/bin/",
         NSHomeDirectory() + "/.local/bin/"]
            .map { $0 + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Up to 1080p YouTube offers H.264 (copied as is); above that only VP9/AV1, which the Mac re-encodes to HEVC.
    nonisolated static func ytFormat(_ h: Int) -> String {
        // Never AV1: this Mac's GPU can't decode it, so the TV-compatible re-encode failed (measured 2026-10-21:
        // "Function not implemented" in scale_vt, empty stream, TV 404). H.264 up to 1080p plays as is; 4K is VP9.
        // Single-file formats only (protocol https): an m3u8 one is written in pieces and renamed at the end, so the
        // live join found no growing file (measured 2026-10-21, format 614).
        // YouTube: H.264 up to 1080p, played as is. Its 4K exists only as VP9 / AV1, and re-encoding those on this
        // Mac failed (VP9 hwaccel setup error, HEVC encoder -12903, measured 2026-10-21) - so 1080p is the ceiling here.
        let hh = min(h, 1080)
        return "bv*[vcodec^=avc1][height<=\(hh)][protocol=https]+ba[ext=m4a][protocol=https]/b[ext=mp4][height<=\(hh)]/bv*[vcodec^=avc1][protocol=https]+ba[ext=m4a]/b"
    }

    static let mediaExt: Set<String> = ["mp4", "m4v", "mkv", "webm", "mov", "avi", "ts", "m2ts", "mts", "mpg", "mpeg",
                                        "wmv", "flv", "mp3", "m4a", "aac", "flac", "wav", "ogg"]

    func cast(_ raw: String) {
        endScreen()
        fallback = nil; startAt = 0   // a new thing on the TV: the old torrent fallback no longer applies
        job?.terminate(); job = nil; liveJob = nil; offset = 0; duration = 0; endMix()
        fetchers.forEach { $0.terminate() }; fetchers = []; fetching = false
        tracks = []; trackCodecs = []; track = 0; currentFile = nil; remoteURL = nil; page = ""
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines); page = s
        if s.lowercased().hasPrefix("magnet:") { return torrent(s) }
        // A .torrent link on the web: download it next to the engine (same machine), then add the file.
        if s.lowercased().hasPrefix("http"), let u = URL(string: s), u.pathExtension.lowercased() == "torrent" { return torrentFile(u) }
        if s.lowercased().hasSuffix(".torrent") { return torrent(s) }
        if s.hasPrefix("/") || s.hasPrefix("file://") {
            return file(s.hasPrefix("file://") ? (URL(string: s)?.path ?? s) : s)
        }
        let url = s.contains("://") ? s : "https://" + s
        guard let u = URL(string: url) else { return fail("Це не посилання") }
        let ext = u.pathExtension.lowercased()
        if Caster.mediaExt.contains(ext) {
            title = u.lastPathComponent; remoteURL = u.absoluteString
            return push(media.add(.remote(u)), ext: ext)
        }
        // Not YouTube: the page may be a torrent page (tracker); its magnet beats a video search.
        if !(u.host ?? "").contains("youtu") { return magnetOrResolve(u) }
        resolve(url)
    }

    /// The TV Browser takes no address from outside (measured 2026-10-20); the core's page on :8895 does.
    /// Open there; when it is not open, start the TV Browser (its start page / bookmark is that page) and wait for it.
    func webPage(_ u: String) {
        title = ""; set("Відкриваю сторінку на ТВ…", nil)
        Task { @MainActor in
            if !TVPage.shared.open, let tv, let app = tv.apps.first(where: { $0.name == "TV Browser" }) { tv.launch(app) }
            for _ in 0..<20 where !TVPage.shared.open { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            guard TVPage.shared.open else {
                return fail(TV.macIP().map { "Відкрийте закладку tinyTV у браузері ТВ: http://\($0):8895" } ?? "Немає домашньої мережі")
            }
            TVPage.shared.go(u); set("", nil)
        }
    }

    private func magnetOrResolve(_ u: URL) {
        set("Читаю сторінку…", nil)
        Task {
            var r = URLRequest(url: u); r.timeoutInterval = 10
            r.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                        forHTTPHeaderField: "User-Agent")
            if let (d, _) = try? await URLSession.shared.data(for: r) {
                let html = String(decoding: d, as: UTF8.self)
                if let m = html.range(of: #"magnet:\?xt=urn:btih:[^"'<>\s]+"#, options: .regularExpression) {
                    let magnet = String(html[m]).replacingOccurrences(of: "&amp;", with: "&")
                    return torrent(magnet)
                }
                if let t = html.range(of: #"https?://[^"'<>\s]+\.torrent[^"'<>\s]*"#, options: .regularExpression),
                   let tu = URL(string: String(html[t]).replacingOccurrences(of: "&amp;", with: "&")) {
                    return torrentFile(tu)
                }
            }
            resolve(u.absoluteString)
        }
    }

    private func torrentFile(_ u: URL) {
        set("Завантажую торент-файл…", nil)
        Task {
            guard let (tmp, resp) = try? await URLSession.shared.download(from: u), (resp as? HTTPURLResponse)?.statusCode == 200 else {
                return fail("Не вдалося завантажити торент-файл")
            }
            let dest = dir.appendingPathComponent("t-\(UUID().uuidString.prefix(8)).torrent")
            try? FileManager.default.moveItem(at: tmp, to: dest)
            torrent(dest.path)
        }
    }

    /// A remote stream started at a given second (Кіно "continue"). Measured: the TV ignores DLNA Seek on a
    /// proxied HDRezka MP4 (it reports no duration), so the Mac starts the stream at `from` and restarts it to seek.
    func castAt(_ url: String, title t: String, from: Double) {
        guard let ff = Caster.tool("ffmpeg") else { return fail("На сервері немає ffmpeg") }
        endScreen()
        fallback = nil; startAt = 0   // a new thing on the TV: the old torrent fallback no longer applies
        job?.terminate(); job = nil; liveJob = nil; offset = 0; duration = 0; endMix(); position = 0
        fetchers.forEach { $0.terminate() }; fetchers = []; fetching = false
        tracks = []; trackCodecs = []; track = 0; currentFile = nil; remoteURL = nil; page = url; src = (0, 0, false, "avc1")
        title = t
        live(ff, inputs: [url], scale: nil, from: max(0, from))
    }

    func file(_ path: String) {
        if remote { return Remote.shared.upload(URL(fileURLWithPath: path)) }
        endScreen()
        job?.terminate(); job = nil; liveJob = nil; offset = 0; currentFile = path; remoteURL = nil
        let ext = (path as NSString).pathExtension.lowercased()
        guard FileManager.default.isReadableFile(atPath: path) else { return fail("Не можу прочитати цей файл") }
        title = (path as NSString).lastPathComponent
        // Measured: the TV's Wi-Fi pulls ~48 Mbit/s; a 30 Mbit/s 4K remux stutters on its peaks.
        // Heavy files are re-encoded on the fly by the Mac's hardware encoder.
        if let ff = Caster.tool("ffmpeg"), let probe = Caster.tool("ffprobe") {
            let r = Caster.run(probe, ["-v", "error", "-select_streams", "v:0", "-show_entries", "format=bit_rate,duration:stream=width,height,color_transfer,codec_name",
                                       "-of", "default=nw=1", path])
            let lines = String(decoding: r.out, as: UTF8.self).split(separator: "\n").map { $0.split(separator: "=", maxSplits: 1).map(String.init) }
            let raw = Dictionary(lines.filter { $0.count == 2 }.map { ($0[0], $0[1]) }, uniquingKeysWith: { a, _ in a })
            let kv = raw.compactMapValues(Double.init)
            src = (kv["width"] ?? 0, kv["height"] ?? 0, ["smpte2084", "arib-std-b67"].contains(raw["color_transfer"] ?? ""), raw["codec_name"] ?? "")
            duration = kv["duration"] ?? 0
            loadTracks(probe, path)
            if shouldEncode(bitrate: kv["bit_rate"] ?? 0) { return live(ff, inputs: [path], scale: encodeFilter(), from: 0) }
        }
        // The TV picks the first audio track itself and may not decode DTS/E-AC3: remux live when that matters.
        if needsAudioWork, let ff = Caster.tool("ffmpeg") { return live(ff, inputs: [path], scale: nil, from: 0) }
        push(media.add(.file(URL(fileURLWithPath: path))), ext: ext)
    }

    private func shouldEncode(bitrate: Double) -> Bool {
        guard src.w > 0 else { return false }
        switch video.mode {
        case "original": return false
        case "encode": return true
        default: return bitrate > 25_000_000 || src.h > Double(video.height) + 8 || (src.hdr && !video.hdr)
        }
    }

    /// GPU chain: VideoToolbox decode -> scale_vt (size, and HDR -> SDR when asked) -> HEVC encode.
    /// Measured on a 4K HDR10 file: 1080p 10-bit 8x realtime, 4K 10-bit 3.8x, 1080p SDR 7.7x.
    private func encodeFilter() -> String {
        let h = min(Double(video.height), src.h > 0 ? src.h : Double(video.height))
        let w = src.h > 0 ? (src.w * h / src.h / 2).rounded() * 2 : (h * 16 / 9 / 2).rounded() * 2
        var f = "scale_vt=w=\(Int(w)):h=\(Int(h))"
        if src.hdr && !video.hdr { f += ":color_matrix=bt709:color_primaries=bt709:color_transfer=bt709" }
        return f
    }

    /// Settings changed while something plays: restart the stream at the same moment.
    private func reapply() {
        guard !title.isEmpty, let ff = Caster.tool("ffmpeg") else { return }
        let at = displayPosition
        // Copy only what the TV decodes (H.264 / HEVC); anything else keeps being encoded.
        let copyable = ["avc", "h264", "hev", "hvc"].contains { src.codec.hasPrefix($0) }
        if let j = liveJob { return live(j.ff, inputs: j.inputs, scale: !copyable || shouldEncode(bitrate: 0) ? encodeFilter() : nil, from: at) }
        if let f = currentFile, shouldEncode(bitrate: 0) { live(ff, inputs: [f], scale: encodeFilter(), from: at) }
    }

    private var needsAudioWork: Bool { track != 0 || !Caster.tvAudio.contains(trackCodecs.first ?? "aac") }
    static let tvAudio: Set<String> = ["aac", "ac3", "mp3"]
    /// The Ukrainian audio track: language ukr/uk, or "укр / ukr / україн" in its title (owner 2026-10-23: UA first, always).
    nonisolated static func uaTrack(_ streams: [[String: Any]]) -> Int? {
        streams.firstIndex { st in
            let t = st["tags"] as? [String: String] ?? [:]
            let lang = (t["language"] ?? "").lowercased(), name = (t["title"] ?? "").lowercased()
            return lang == "ukr" || lang == "uk" || ["укр", "ukr", "україн", "украин"].contains { name.contains($0) }
        }
    }

    private func loadTracks(_ probe: String, _ path: String) {
        let r = Caster.run(probe, ["-v", "error", "-select_streams", "a", "-show_entries", "stream=codec_name,channels:stream_tags=language,title",
                                   "-of", "json", path])
        let streams = ((try? JSONSerialization.jsonObject(with: r.out)) as? [String: Any])?["streams"] as? [[String: Any]] ?? []
        trackCodecs = streams.map { $0["codec_name"] as? String ?? "" }
        tracks = streams.enumerated().map { i, st in
            let tags = st["tags"] as? [String: String] ?? [:]
            let lang = (tags["language"] ?? "").uppercased()
            let ch = (st["channels"] as? Int).map { $0 > 2 ? " \($0 - 1).1" : "" } ?? ""
            return (i, [lang, tags["title"] ?? ""].filter { !$0.isEmpty }.joined(separator: " · ") + ch)
        }
        // Default: the first Ukrainian track, else the first one.
        track = Caster.uaTrack(streams) ?? 0
    }

    /// Switch the audio track: restarts the stream at the current moment with that track.
    func setTrack(_ i: Int) {
        if remote { track = i; return Remote.post("cast/audio", ["i": i]) }
        guard i != track || mix != nil, tracks.indices.contains(i), let ff = Caster.tool("ffmpeg") else { return }
        track = i
        let at = displayPosition
        if let j = liveJob { return live(j.ff, inputs: mix != nil ? [j.inputs[0]] : j.inputs, scale: j.scale, from: at) }
        if let f = currentFile { return live(ff, inputs: [f], scale: nil, from: at) }
        // A torrent the TV reads straight from the engine: go on from this second through our remux with that track.
        if engineCast { live(ff, inputs: [Caster.engineStream], scale: nil, from: at) }
    }

    static let engineStream = "http://127.0.0.1:8890/stream"

    // MARK: Dub from another source (owner 2026-10-23: the voiceover he likes + the torrent picture he likes)

    /// audiosync.py cuts and shifts the dub onto this video's clock (shared music and effects, 10 s windows)
    /// and writes an AC3 track that grows ahead of the TV; ffmpeg copies the video and takes this track.
    private(set) var mix: (track: String, status: String, label: String, key: String, nudge: Double)?
    private var mixJob: Process?
    private var mixDub = ""   // where the voice comes from (a release file: the keeper sees it is in use)
    private var mixDubTrack = 0
    private var mixPos: Task<Void, Never>?
    private let mixDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/tinyTV-mix")

    /// For the cards: what plays, how far the track is aligned, the hand nudge.
    var mixState: [String: Any] {
        guard let m = mix else { return [:] }
        let st = (try? Data(contentsOf: URL(fileURLWithPath: m.status))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let state = st["state"] as? String ?? "sync", until = st["until"] as? Double ?? 0
        let parts = (st["segments"] as? [Any])?.count ?? 0
        return ["label": m.label, "state": state, "until": until, "parts": parts, "nudge": m.nudge, "dub": mixDub, "dubTrack": mixDubTrack, "track": m.track,
                "at": mixAt, "live": liveJob?.inputs.last == m.track]
    }

    /// One aligner per pair, kept alive across taps: a second "Продовжити" restarted it and the two runs deleted each
    /// other's files (2026-10-24: "лише з 3го разу запускає"). It ends by itself when the track is written.
    private var aligners: [String: Process] = [:]

    private func endMix() {
        mixJob = nil; mixPos?.cancel(); mixPos = nil; mix = nil
    }

    /// Plays the current video with the dub from `dub` (a file or a stream link). `key` names the pair: the aligned
    /// track is kept, so the same pair starts at once next time.
    func mix(dub: String, track dubTrack: Int = 0, label: String, key: String) {
        if remote { return }
        guard let ff = Caster.tool("ffmpeg"), let py = Bundle.main.path(forResource: "audiosync", ofType: "py") else { return fail("На сервері немає ffmpeg") }
        guard let video = liveJob?.inputs.first ?? currentFile ?? (engineCast ? Caster.engineStream : nil) else {
            return fail("Озвучку з іншого джерела можна додати до торента або файлу") }
        let at = displayPosition, scale = liveJob?.scale, ref = track
        endMix(); mixDub = dub; mixDubTrack = dubTrack
        try? FileManager.default.createDirectory(at: mixDir, withIntermediateDirectories: true)
        // Readable start + FNV-1a of the whole key: two long keys with the same start never share an aligned track.
        let fnv = key.utf8.reduce(UInt32(2166136261)) { ($0 ^ UInt32($1)) &* 16777619 }
        let name = "mix-" + String(key.unicodeScalars.map { $0.isASCII && CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }.prefix(60)) + "-" + String(format: "%08x", fnv)
        let out = mixDir.appendingPathComponent(name + ".ac3"), st = mixDir.appendingPathComponent(name + ".json")
        let saved = (try? Data(contentsOf: st)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let nudges = UserDefaults.standard.dictionary(forKey: "mixNudge") as? [String: Double] ?? [:]
        mix = (out.path, st.path, label, key, nudges[key] ?? 0)
        if let running = aligners[out.path], running.isRunning {
            mixJob = running   // the same pair is aligning already: wait for it
        } else if saved?["state"] as? String != "done" || !FileManager.default.fileExists(atPath: out.path) {
            // Keep the 4 newest pairs (an aligned film is ~30 MB per hour, the dub copy ~70 MB).
            let fm = FileManager.default, items = (try? fm.contentsOfDirectory(at: mixDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let date = { (u: URL) in (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
            // Only aligned pairs ("mix-…"): the plan, keep and registry files and the track in use stay.
            Set(items.filter { $0.lastPathComponent.hasPrefix("mix-") }.sorted { date($0) > date($1) }
                .map { $0.lastPathComponent.components(separatedBy: ".")[0] }.filter { $0 != name }.dropFirst(4))
                .forEach { n in items.filter { $0.lastPathComponent.hasPrefix(n + ".") }.forEach { try? fm.removeItem(at: $0) } }
            try? fm.removeItem(at: st)
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = [py, "align", video, String(ref), dub, String(dubTrack), out.path, st.path, mixDir.path]
            var env = ProcessInfo.processInfo.environment; env["MIX_PLAYHEAD"] = st.path + ".pos"; p.environment = env
            p.standardOutput = FileHandle.nullDevice; p.standardError = Caster.ffmpegLog()
            do { try p.run(); mixJob = p; aligners[out.path] = p } catch { mix = nil; return fail("Не вдалося запустити синхрон") }
        }
        // audiosync maps a torrent still downloading only near the playhead: tell it where the TV is.
        let pos = st.path + ".pos"
        mixPos = Task { @MainActor in
            while !Task.isCancelled {
                try? String(format: "%.1f", self.displayPosition).write(toFile: pos, atomically: true, encoding: .utf8)
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        // Owner 2026-10-24 ("порахувати скільки треба ... і з того моменту коли впевнений назначити перехід"): the old
        // stream plays on; the switch is planned at a future second P (copy of the voice + sync + 1 min ahead), and at P
        // the new stream starts exactly at P - no jump back, no jump forward. Cached pair: P = now + 5 s.
        let cached = saved?["state"] as? String == "done" && FileManager.default.fileExists(atPath: out.path)
        let estimate = cached ? 5.0 : 25 + duration / 600 + 20 + 10   // copy (~25 s / 2.5 h) + sync + margin
        mixAt = (at + estimate).rounded()
        Task { await mixStart(ff, video: video, scale: scale, from: mixAt, planned: true) }
    }

    /// Picture switch in one TV load (owner 2026-10-24: "наперед заплануй перехід"): a downloaded release file from
    /// `from`, with the dub already aligned (or aligning) - no stop on the release's own sound first.
    func mixFile(_ path: String, from: Double, dub: String, track dubTrack: Int, label: String, key: String) {
        if remote { return }
        endScreen()
        fallback = nil; startAt = 0
        job?.terminate(); job = nil; liveJob = nil; endMix(); position = 0; offset = from
        fetchers.forEach { $0.terminate() }; fetchers = []; fetching = false
        currentFile = path; remoteURL = nil; page = ""; tv = tv ?? TV.shared
        title = (path as NSString).lastPathComponent
        if let probe = Caster.tool("ffprobe") {
            let r = Caster.run(probe, ["-v", "error", "-select_streams", "v:0", "-show_entries", "format=duration:stream=width,height,color_transfer,codec_name", "-of", "default=nw=1", path])
            let kv = Dictionary(String(decoding: r.out, as: UTF8.self).split(separator: "\n").map { $0.split(separator: "=", maxSplits: 1).map(String.init) }
                .filter { $0.count == 2 }.map { ($0[0], $0[1]) }, uniquingKeysWith: { a, _ in a })
            src = (Double(kv["width"] ?? "") ?? 0, Double(kv["height"] ?? "") ?? 0, ["smpte2084", "arib-std-b67"].contains(kv["color_transfer"] ?? ""), kv["codec_name"] ?? "")
            duration = Double(kv["duration"] ?? "") ?? 0
            loadTracks(probe, path)
        }
        mix(dub: dub, track: dubTrack, label: label, key: key)
    }

    /// Starts the TV stream once the aligned track covers `from` (+20 s); a seek past the aligned part waits here too.
    /// The planned switch second for the cards ("Перехід на 12:34").
    private(set) var mixAt: Double = 0

    private func mixStart(_ ff: String, video: String, scale: String?, from start: Double, planned: Bool = false) async {
        guard let m = mix else { return }
        var from = start
        try? String(format: "%.1f", from).write(toFile: m.status + ".pos", atomically: true, encoding: .utf8)
        // Planned: wait (no limit) until the voice covers P + 1 min and the TV reaches P; on pause - from the same place.
        // The aligned track must exist with at least ~1 s in it before ffmpeg opens it.
        let written = { ((try? FileManager.default.attributesOfItem(atPath: m.track))?[.size] as? Int ?? 0) > 32_000 }
        func failed(_ s: [String: Any]) {
            endMix()
            // Not started yet (planned): the release's sound simply plays on. A restart (seek): the release's sound.
            if !planned, let j = liveJob, j.inputs.count == 2 { live(ff, inputs: [j.inputs[0]], scale: j.scale, from: from) }
            fail(s["error"] as? String == "dub" ? "HDRezka не віддала озвучку - грає звук релізу" : "Озвучка не збіглась з цим відео (інша версія фільму?)")
        }
        while planned {
            guard let cur = mix, cur.track == m.track else { return }
            let s = mixState, state = s["state"] as? String ?? "sync", until = s["until"] as? Double ?? 0
            if state == "error" { return failed(s) }
            if !playing { from = displayPosition; mixAt = from }   // paused: the switch happens right where it stands
            let ready = (state == "done" || until >= displayPosition + 63) && written()
            // Sure now (the voice covers 1 min ahead): the switch is set 3 s ahead, not at the cautious estimate.
            if ready && playing && from > displayPosition + 3 { from = (displayPosition + 3).rounded(); mixAt = from }
            if ready && (!playing || displayPosition >= from - 1.5) { break }
            if !ready && playing && displayPosition >= from - 3 { from += 30; mixAt = from }   // not ready at P: 30 s later
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        for i in 0..<(planned ? 0 : 600) {
            guard let cur = mix, cur.track == m.track else { return }
            let s = mixState, state = s["state"] as? String ?? "sync", until = s["until"] as? Double ?? 0
            if state == "error" { return failed(s) }
            if (state == "done" || until >= from + 20) && written() { break }
            if i == 599 { endMix(); return fail("Синхрон озвучки не встиг") }
            set(until > 0 ? "Синхронізую озвучку… \(clock(until))" : "Синхронізую озвучку…", min(0.95, Double(i) / 120))
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        live(ff, inputs: [video, m.track], scale: scale, from: from)
    }

    /// Owner: ±0.1 s by hand. Restarts the stream at the same second with the track moved (remembered for this pair).
    func mixNudge(_ d: Double) {
        guard !remote, var m = mix, let j = liveJob else { return }
        m.nudge = (min(5, max(-5, m.nudge + d)) * 10).rounded() / 10; mix = m
        var all = UserDefaults.standard.dictionary(forKey: "mixNudge") as? [String: Double] ?? [:]
        all[m.key] = m.nudge; UserDefaults.standard.set(all, forKey: "mixNudge")
        live(j.ff, inputs: j.inputs, scale: j.scale, from: displayPosition)
    }

    /// Back to the release's own sound.
    func mixOff() {
        guard mix != nil, let j = liveJob, let ff = Caster.tool("ffmpeg") else { return endMix() }
        let at = displayPosition, video = j.inputs[0]
        endMix()
        live(ff, inputs: [video], scale: j.scale, from: at)
    }

    private func clock(_ t: Double) -> String {
        let s = Int(t); return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// ffmpeg errors of TV streams, appended to ~/Library/Logs/tinyTV-ffmpeg.log (kept under 2 MB).
    static func ffmpegLog() -> FileHandle {
        let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/tinyTV-ffmpeg.log")
        if let a = try? FileManager.default.attributesOfItem(atPath: u.path), (a[.size] as? Int ?? 0) > 2_000_000 { try? FileManager.default.removeItem(at: u) }
        if !FileManager.default.fileExists(atPath: u.path) { FileManager.default.createFile(atPath: u.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: u) else { return FileHandle.nullDevice }
        h.seekToEndOfFile(); h.write(Data("--- \(Date())\n".utf8)); return h
    }

    /// Real audio tracks of the torrent's file (owner: not HDRezka's voiceovers). Read via the engine's /probe,
    /// which does not move the TV's playhead; the TV starts on the file's first track.
    private func engineTracks() {
        guard let probe = Caster.tool("ffprobe") else { return }
        let t = title
        Task.detached {
            let r = Caster.run(probe, ["-v", "error", "-select_streams", "a", "-show_entries", "stream=codec_name,channels:stream_tags=language,title",
                                       "-of", "json", "http://127.0.0.1:8890/probe"])
            let streams = ((try? JSONSerialization.jsonObject(with: r.out)) as? [String: Any])?["streams"] as? [[String: Any]] ?? []
            await MainActor.run {
                guard self.title == t, self.engineCast, self.liveJob == nil else { return }
                self.trackCodecs = streams.map { $0["codec_name"] as? String ?? "" }
                self.tracks = streams.enumerated().map { i, st in
                    let tags = st["tags"] as? [String: String] ?? [:]
                    let ch = (st["channels"] as? Int).map { $0 > 2 ? " \($0 - 1).1" : "" } ?? ""
                    return (i, [(tags["language"] ?? "").uppercased(), tags["title"] ?? ""].filter { !$0.isEmpty }.joined(separator: " · ") + ch)
                }
                self.track = 0
                // The TV starts on the file's first track; a Ukrainian one elsewhere switches over our remux at once.
                if let u = Caster.uaTrack(streams), u != 0 { self.setTrack(u) }
            }
        }
    }

    // MARK: YouTube and other pages

    private func resolve(_ url: String) {
        guard let y = Caster.tool("yt-dlp"), let ff = Caster.tool("ffmpeg") else { return fail("На сервері немає yt-dlp або ffmpeg") }
        set("Шукаю відео…", nil)
        let fmt = Caster.ytFormat(video.height)
        Task.detached {
            // Our own node, by path: "--js-runtimes node" only added node to the default deno, and yt-dlp's probes of
            // Homebrew's deno/node on the external disk ("--version") hung every call under launchd (measured 2026-10-22).
            let r = Caster.run(y, ["--no-js-runtimes", "--js-runtimes", "node:" + NSHomeDirectory() + "/tinyTV/tools/bin/node", "-J", "--no-playlist", "--no-warnings",
                                   "-f", fmt, url])
            let info = (try? JSONSerialization.jsonObject(with: r.out)) as? [String: Any]
            let err = String(decoding: r.err, as: UTF8.self)
            await MainActor.run {
                guard let info else {
                    // No video there: it is a web page - open it in the TV Browser (owner: "просто відкривати web сторінки").
                    return err.contains("Unsupported URL") || err.contains("No video") || err.contains("Unable to extract")
                        ? self.webPage(url) : self.fail("Не знайшов відео за цим посиланням")
                }
                self.title = info["title"] as? String ?? "Video"
                self.duration = info["duration"] as? Double ?? 0
                let parts = (info["requested_formats"] as? [[String: Any]]) ?? [info]
                let urls = parts.compactMap { $0["url"] as? String }
                let proto = parts.first?["protocol"] as? String ?? ""
                // One progressive HTTP file: proxy it, the TV can seek in it right away.
                if urls.count == 1, proto.hasPrefix("http"), let u = URL(string: urls[0]) {
                    let ext = parts.first?["ext"] as? String ?? "mp4"
                    self.remoteURL = u.absoluteString
                    return self.push(self.media.add(.remote(u)), ext: ext)
                }
                let v = parts.first ?? [:]
                self.src = ((v["width"] as? Double) ?? 0, (v["height"] as? Double) ?? 0,
                            ((v["dynamic_range"] as? String) ?? "SDR").hasPrefix("HDR"), (v["vcodec"] as? String) ?? "")
                // Separate video + audio (YouTube): fetch both fast with yt-dlp, join the growing files live.
                let ids = parts.compactMap { $0["format_id"] as? String }
                if ids.count == 2, let y = Caster.tool("yt-dlp") { return self.fetchThenLive(y, ff, url, ids) }
                self.live(ff, inputs: urls, scale: nil, from: 0)
            }
        }
    }

    private var fetchers: [Process] = []
    private var fetching = false

    /// YouTube streams a single HTTP reader at about playback speed, so ffmpeg on the URLs leaves the TV a thin buffer.
    /// yt-dlp downloads in chunks many times faster: two downloads run in parallel and ffmpeg follows the growing files.
    private func fetchThenLive(_ y: String, _ ff: String, _ url: String, _ ids: [String]) {
        fetchers.forEach { $0.terminate() }; fetchers = []
        prune()
        let tag = UUID().uuidString.prefix(8)
        let files = ids.enumerated().map { i, _ in dir.appendingPathComponent("dl-\(tag)-\(i).mp4") }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = NSHomeDirectory() + "/tinyTV/tools/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        for (id, out) in zip(ids, files) {
            let p = Process(); p.executableURL = URL(fileURLWithPath: y); p.environment = env
            p.arguments = ["--no-js-runtimes", "--js-runtimes", "node:" + NSHomeDirectory() + "/tinyTV/tools/bin/node", "--no-playlist", "--no-warnings", "--no-part", "--http-chunk-size", "10M",
                           "-f", id, "-o", out.path, "--force-overwrites", url]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run(); fetchers.append(p)
        }
        fetching = true
        set("Завантажую…", 0)
        Task {
            // Start once both files have a head (moov + first fragments).
            for _ in 0..<80 {
                let sizes = files.map { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int) ?? 0 }
                if sizes.allSatisfy({ $0 > 400_000 }) || fetchers.allSatisfy({ !$0.isRunning }) { break }
                set("Завантажую…", min(0.9, Double(sizes.min() ?? 0) / 400_000))
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            let copyable = src.codec.hasPrefix("avc1") || src.codec.hasPrefix("hev") || src.codec.hasPrefix("hvc")
            live(ff, inputs: files.map(\.path), scale: !copyable || shouldEncode(bitrate: 0) ? encodeFilter() : nil, from: 0)
            // When both downloads end and ffmpeg has caught up, end the live file so the TV gets EOF.
            while fetchers.contains(where: { $0.isRunning }) { try? await Task.sleep(nanoseconds: 500_000_000) }
            fetching = false
            // A re-encode (4K VP9 -> HEVC) runs slower than the download: stop only when the output stops growing,
            // i.e. ffmpeg waits at the end of the inputs (cut at 56 % on 2026-10-22 with a fixed 3 s wait).
            guard let mine = job else { return }
            var last = -1, still = 0
            while mine.isRunning, job === mine, still < 4 {
                let size = liveOut.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int) } ?? 0
                still = size == last ? still + 1 : 0; last = size
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            if job === mine { mine.terminate() }
        }
    }

    /// The running live stream, kept so a seek can restart it from another moment.
    private var liveJob: (ff: String, inputs: [String], scale: String?)?
    /// Seconds into the source where the current live stream starts (DLNA counts from 0).
    private var offset: Double = 0
    private var liveOut: URL?

    /// ffmpeg writes a growing MPEG-TS file: joins video and audio (YouTube), copies HLS,
    /// or re-encodes a heavy file with VideoToolbox. Playback starts at ~1.5 MB.
    private var gpuFrames: Bool { ["avc", "h264", "hev", "hvc"].contains { src.codec.lowercased().hasPrefix($0) } }
    /// scale_vt=w=1920:h=1080[:color...] -> a software scale to the same size, then 8/10-bit planar for the encoder.
    private func softScale(_ f: String) -> String {
        let w = f.range(of: #"w=(\d+)"#, options: .regularExpression).map { String(f[$0].dropFirst(2)) } ?? "1920"
        let h = f.range(of: #"h=(\d+)"#, options: .regularExpression).map { String(f[$0].dropFirst(2)) } ?? "1080"
        return "scale=w=\(w):h=\(h):flags=bicubic,format=\(video.hdr && src.hdr ? "p010le" : "nv12")"
    }

    private func live(_ ff: String, inputs: [String], scale: String?, from: Double) {
        guard !inputs.isEmpty else { return fail("Не знайшов відео за цим посиланням") }
        // Transmission moves a finished file out of .incomplete and drops ".part" (a restart after that found nothing).
        let inputs = inputs.map { u -> String in
            guard !u.hasPrefix("http"), !FileManager.default.fileExists(atPath: u), u.contains("/.incomplete/"), u.hasSuffix(".part") else { return u }
            let q = String(u.replacingOccurrences(of: "/.incomplete/", with: "/").dropLast(5))
            return FileManager.default.fileExists(atPath: q) ? q : u
        }
        if currentFile.map({ !FileManager.default.fileExists(atPath: $0) }) == true { currentFile = inputs.first }
        if let m = mix, inputs.last != m.track { endMix() }   // something else plays now
        job?.terminate()
        prune()
        liveJob = (ff, inputs, scale); offset = from
        let out = dir.appendingPathComponent("live-\(UUID().uuidString.prefix(8)).ts")
        liveOut = out
        var args = ["-hide_banner", "-loglevel", "error", "-y"]
        for (n, u) in inputs.enumerated() {
            // The aligned dub: raw CBR AC3 entered at the 32 ms frame of this second by bytes (no seek in a growing file).
            if let m = mix, u == m.track {
                let st = (try? Data(contentsOf: URL(fileURLWithPath: m.status))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let frame = st?["frame"] as? Int ?? 2560, k = Int(Double(Int(from)) / 0.032)
                if mixJob?.isRunning == true { args += ["-follow", "1"] }   // audiosync still writes ahead
                args += ["-f", "ac3", "-skip_initial_bytes", String(k * frame),
                         "-itsoffset", String(format: "%.3f", Double(k) * 0.032 - Double(Int(from)) + m.nudge), "-i", u]   // + = the voice later
                continue
            }
            if from > 0 { args += ["-ss", String(Int(from))] }
            if u.hasPrefix("http") { args += ["-reconnect", "1", "-reconnect_streamed", "1"] }
            else if fetching { args += ["-follow", "1"] }  // the file is still downloading
            // GPU frames end to end only for H.264 / HEVC: VP9 (YouTube 4K) falls back to software decode after a seek
            // and scale_vt then fails ("Function not implemented", measured 2026-10-21); those scale in software.
            if scale != nil, n == 0 { args += gpuFrames ? ["-hwaccel", "videotoolbox", "-hwaccel_output_format", "videotoolbox_vld"] : ["-hwaccel", "videotoolbox"] }
            args += ["-i", u]
        }
        let a = inputs.count > 1 ? 0 : track
        args += inputs.count > 1 ? ["-map", "0:v:0", "-map", "1:a:0"] : ["-map", "0:v:0", "-map", "0:a:\(a)?"]
        // Copy audio the TV decodes; turn DTS / E-AC3 / TrueHD into AC3 5.1.
        let codec = inputs.count > 1 ? (mix != nil ? "ac3" : "aac") : (trackCodecs.indices.contains(a) ? trackCodecs[a] : "aac")
        // Owner (2026-10-21): "Рівно" = the original sound, not re-encoded. Any other preset: through the named
        // equalizer chain (AC3 keeps 5.1); once it is in, later changes go live with no restart.
        SoundSettings.volume = tv?.volume ?? SoundSettings.volume; eqVolume = SoundSettings.volume
        jobEQ = sound.on
        let audio = sound.on ? ["-af", sound.chain, "-c:a", "ac3", "-b:a", "448k"]
            : (Caster.tvAudio.contains(codec) ? ["-c:a", "copy"] : ["-c:a", "ac3", "-b:a", "640k", "-ac", "6"])
        if let scale {
            let tenBit = video.hdr && src.hdr
            args += ["-vf", gpuFrames ? scale : softScale(scale), "-c:v", "hevc_videotoolbox", "-profile:v", tenBit ? "main10" : "main",
                     "-b:v", "\(Int(encodeMbps))M", "-maxrate", "\(Int(min(encodeMbps * 1.2, 42)))M", "-bufsize", "\(Int(min(encodeMbps * 1.2, 42) * 2))M", "-g", "48"]
            if tenBit { args += ["-color_primaries", "bt2020", "-color_trc", "smpte2084", "-colorspace", "bt2020nc"] }
        } else { args += ["-c:v", "copy"] }
        args += audio
        args += ["-f", "mpegts", out.path]
        let p = Process(); p.executableURL = URL(fileURLWithPath: ff); p.arguments = args
        let pin = Pipe(); p.standardInput = pin; jobIn = pin
        p.standardOutput = FileHandle.nullDevice; p.standardError = Caster.ffmpegLog()   // why a TV stream stopped (owner: stutter with a full buffer)
        let id = media.add(.growing(out))
        p.terminationHandler = { [weak self] _ in Task { @MainActor in self?.media.finish(id) } }
        do { try p.run(); job = p } catch { return fail("Не вдалося запустити перекодування") }
        set("Запускаю…", 0)
        Task {
            for _ in 0..<120 {
                let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
                if size > 800_000 || !p.isRunning { break }
                set("Запускаю…", min(0.95, Double(size) / 800_000))
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            push(id, ext: "ts")
        }
    }

    /// Whether the scrubber can move freely: true for files and proxied links, restarts the stream for live jobs.
    var displayPosition: Double { offset + position }

    // MARK: Screen to TV

    /// "mac": wait for the Mac remote to send its screen to :8893. "core": capture this machine's screen.
    func startScreen(_ from: String, window: UInt32? = nil) {
        if remote {
            // Not set locally: the core resets its relay first, then the next poll tells this Mac to send.
            var b: [String: Any] = ["from": from]; if let window { b["window"] = Int(window) }
            return Remote.post("screen", b)
        }
        job?.terminate(); job = nil; liveJob = nil; offset = 0; duration = 0; position = 0
        fetchers.forEach { $0.terminate() }; fetchers = []; fetching = false
        tracks = []; trackCodecs = []; track = 0; currentFile = nil; remoteURL = nil; page = ""
        endScreen()
        screen = from; screenWindow = window
        // from: "<host>[-extend|-audio]"; host "mac" = the Mac remote sends, "core" = this machine captures.
        let host = String(from.split(separator: "-").first ?? "")
        let mode = ScreenCapture.Mode(rawValue: String(from.split(separator: "-").dropFirst().first ?? "")) ?? .mirror
        title = (host == "mac" ? "Mac " : "core host ") + ["mirror": "screen", "extend": "extended screen", "audio": "audio"][mode.rawValue]!
        LiveRelay.shared.reset(raw: mode == .audio)
        set(host == "mac" ? "Чекаю на Mac…" : "Захоплюю екран…", nil)
        if host != "mac" {
            HostSpeakers.mute()   // the TV plays this sound; core host itself stays silent (capture still gets it: measured)
            guard let ff = Caster.tool("ffmpeg") else { return fail("На сервері немає ffmpeg") }
            let c = ScreenCapture(); capture = c
            c.onEnd = { err in Task { @MainActor in if let err { Caster.shared.fail("Показ екрана: \(err)") } } }
            Task {
                do { try await c.start(window: window, mode: mode, preset: ScreenPreset.named(screenPreset),
                                       to: "127.0.0.1:\(LiveRelay.port.rawValue)", ffmpeg: ff) }
                catch { fail("Немає доступу до екрана: дозвольте запис екрана для tinyTVCore у Налаштуваннях") }
            }
        }
        Task {
            for _ in 0..<60 {
                if LiveRelay.shared.live || screen != from { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            guard screen == from else { return }
            guard LiveRelay.shared.live else {
                return fail(host == "mac" ? "The Mac didn't send its screen. Is tinyTV open there?" : "No picture from the screen")
            }
            // The TV page is open in the TV Browser: play there (~1 s) instead of DLNA (~8 s). See LowLatency.swift.
            if mode != .audio, TVPage.shared.open { TVPage.shared.screen(); return set("", nil) }
            push(media.add(.live), ext: mode == .audio ? "aac" : "ts")
        }
    }

    private func endScreen() {
        guard !screen.isEmpty else { return }
        screen = ""; screenWindow = nil
        capture?.stop(); capture = nil
        LiveRelay.shared.reset()
        HostSpeakers.restore()
    }

    // MARK: Torrents through the TV Cast engine

    private func torrent(_ s: String) {
        set("Додаю торент…", nil)
        title = "Torrent"
        Task {
            let base = URL(string: "http://127.0.0.1:8890")!
            var c = URLComponents(url: base.appendingPathComponent("add"), resolvingAgainstBaseURL: false)!
            var r = URLRequest(url: base); r.httpMethod = "POST"
            if s.lowercased().hasPrefix("magnet:") {
                r.httpBody = Data(s.utf8)
                if let ep = torrentEpisode { c.queryItems = [URLQueryItem(name: "ep", value: ep)] }
            }
            else { c.queryItems = [URLQueryItem(name: "file", value: s)] }
            torrentEpisode = nil
            r.url = c.url
            guard let (_, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else {
                return fail("Сервер торентів не запущений")
            }
            for _ in 0..<240 {  // up to 2 min for peers and the first pieces
                if let (d, _) = try? await URLSession.shared.data(from: base.appendingPathComponent("state")),
                   let st = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    let name = st["fileName"] as? String ?? ""
                    if name.isEmpty, let e = st["error"] as? String, !e.isEmpty { return fail(e) }   // e.g. no such episode in the pack
                    let got = (st["downloadedBytes"] as? NSNumber)?.doubleValue ?? 0
                    let peers = (st["peers"] as? NSNumber)?.intValue ?? 0
                    if !name.isEmpty { title = name }
                    if let d = (st["durationSec"] as? NSNumber)?.doubleValue, d > 0 { duration = d }
                    set(name.isEmpty ? "Шукаю роздаючих… (\(peers))" : "Буферизую… \(peers) пір.",
                        name.isEmpty ? nil : min(1, got / 8_000_000))
                    if !name.isEmpty, got > 8_000_000, let ip = TV.macIP() {
                        // Starting mid-film (switch from HDRezka / resume): fetch that part first, or the TV waits on
                        // missing pieces and the seek fails (owner: "не може початися з того ж місця").
                        if startAt > 1 { await preload(at: startAt) }
                        // Owner: a REMUX "jerks" at any download speed - the TV's Wi-Fi (~48 Mbit/s) cannot carry
                        // ~88 Mbit/s. Over ~36 Mbit/s the core re-encodes on the GPU instead of sending the file as is.
                        if let heavy = await heavyTorrent(), heavy, let ff = Caster.tool("ffmpeg") {
                            heavyCap = true
                            let at = startAt; startAt = 0
                            set("Важкий файл: перекодовую під Wi-Fi ТВ…", nil)
                            return live(ff, inputs: [Caster.engineStream], scale: encodeFilter(), from: at)
                        }
                        heavyCap = false
                        // A start not at 0 goes through ffmpeg's exact -ss: the TV's own DLNA seek in a big VBR file lands
                        // elsewhere while it reports the asked second (owner 2026-10-24: "фільм після рестарту … було не там").
                        if sound.on || startAt > 1, let ff = Caster.tool("ffmpeg") { let at = startAt; startAt = 0; return live(ff, inputs: [Caster.engineStream], scale: nil, from: at) }
                        return play("http://\(ip):8890/stream", ext: (name as NSString).pathExtension.lowercased(), engine: true)
                    }
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            fail("Немає роздаючих: торент не стартує")
        }
    }

    // MARK: DLNA

    private func push(_ id: String, ext: String) {
        guard let ip = TV.macIP() else { return fail("Немає домашньої мережі") }
        play("http://\(ip):\(MediaServer.port)/m/\(id).\(ext)", ext: ext, engine: false)
    }

    private func play(_ url: String, ext: String, engine: Bool) {
        guard let tv else { return }
        // Also a remux of the engine's stream (another audio track) still reads the torrent: keep its buffer logic.
        engineCast = engine || (liveJob?.inputs.first == Caster.engineStream); torrent = [:]
        if engine { engineTracks() }
        set("Надсилаю на ТВ…", nil)
        media.lastHit = nil
        Task {
            let ok = await DLNA.load(host: tv.host, url: url, mime: MediaServer.mime(ext), title: title)
            guard ok else { return fail("ТВ не прийняв відео. Спробуйте ще раз") }
            await Caster.acceptConsent(tv, title: title)
            set("", nil)
            watch()
            // Switching from HDRezka to a torrent "from the same second" (owner): seek only once the TV really plays
            // (a seek during the consent dialog is ignored), then check the position and repeat up to 3 times.
            if startAt > 1 {
                let t = startAt; startAt = 0
                for _ in 0..<40 where !playing { try? await Task.sleep(nanoseconds: 500_000_000) }
                for _ in 0..<3 {
                    seek(t); try? await Task.sleep(nanoseconds: 4_000_000_000)
                    if abs(displayPosition - t) < 30 { break }
                }
            }
        }
    }

    /// Probe the torrent's file through the engine (/probe does not move the TV's playhead): picture size and HDR for
    /// the encoder, and whether its average rate is over what the TV's Wi-Fi carries.
    private func heavyTorrent() async -> Bool? {
        guard let probe = Caster.tool("ffprobe") else { return nil }
        let r = await Task.detached {
            Caster.run(probe, ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height,codec_name,color_transfer:format=duration,size",
                               "-of", "json", "http://127.0.0.1:8890/probe"])
        }.value
        guard let j = try? JSONSerialization.jsonObject(with: r.out) as? [String: Any] else { return nil }
        let v = (j["streams"] as? [[String: Any]])?.first ?? [:], f = j["format"] as? [String: Any] ?? [:]
        src = ((v["width"] as? Double) ?? 0, (v["height"] as? Double) ?? 0,
               ["smpte2084", "arib-std-b67"].contains(v["color_transfer"] as? String ?? ""), v["codec_name"] as? String ?? "")
        var size = Double(f["size"] as? String ?? "") ?? 0, dur = Double(f["duration"] as? String ?? "") ?? 0
        // ffprobe can miss the length early on: take the engine's numbers; no length yet and over 30 GB = a REMUX.
        if dur <= 0 || size <= 0, let u = URL(string: "http://127.0.0.1:8890/state"), let (d, _) = try? await URLSession.shared.data(from: u),
           let st = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            if size <= 0 { size = (st["fileBytes"] as? NSNumber)?.doubleValue ?? 0 }
            if dur <= 0 { dur = (st["durationSec"] as? NSNumber)?.doubleValue ?? 0 }
        }
        if dur > 0 { duration = dur }
        // Audio codecs too: a REMUX carries DTS-HD / TrueHD the TV can't play; the encoder turns them into AC3.
        let ar = await Task.detached {
            Caster.run(probe, ["-v", "error", "-select_streams", "a", "-show_entries", "stream=codec_name,channels:stream_tags=language,title",
                               "-of", "json", "http://127.0.0.1:8890/probe"])
        }.value
        let streams = ((try? JSONSerialization.jsonObject(with: ar.out)) as? [String: Any])?["streams"] as? [[String: Any]] ?? []
        if !streams.isEmpty {
            trackCodecs = streams.map { $0["codec_name"] as? String ?? "" }
            tracks = streams.enumerated().map { i, st in
                let tags = st["tags"] as? [String: String] ?? [:]
                let ch = (st["channels"] as? Int).map { $0 > 2 ? " \($0 - 1).1" : "" } ?? ""
                return (i, [(tags["language"] ?? "").uppercased(), tags["title"] ?? ""].filter { !$0.isEmpty }.joined(separator: " · ") + ch)
            }
            // Ukrainian first when there is one (owner's default elsewhere too).
            track = Caster.uaTrack(streams) ?? 0
        }
        return dur > 0 ? size / dur > 4_500_000 : size > 30e9
    }

    /// Download the part of the torrent at second t first (the engine moves its window there), up to ~90 s.
    private func preload(at t: Double) async {
        for i in 0..<90 {
            guard let u = URL(string: "http://127.0.0.1:8890/ahead?sec=\(Int(t))"), let (d, _) = try? await URLSession.shared.data(from: u),
                  let st = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
            let ahead = (st["aheadSec"] as? NSNumber)?.doubleValue ?? 0, bps = (st["bps"] as? NSNumber)?.doubleValue ?? 0
            if bps > 0, ahead >= 15 { return }
            set("Готую з \(Int(t) / 3600 > 0 ? "\(Int(t) / 3600):" : "")\(String(format: "%02d:%02d", Int(t) % 3600 / 60, Int(t) % 60))… \(i) с", nil)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    /// Set by Kino when a torrent replaces an HDRezka episode: if the torrent fails or starves, go back there.
    var fallback: (() -> Void)?
    var startAt: Double = 0
    /// The episode of a season-pack torrent ("2x18"): the engine streams that file, not the pack's largest (owner 2026-10-23).
    var torrentEpisode: String?
    private var holdSince: Date?
    private var lastTorrentSave = Date.distantPast

    /// The TV asks "allow this device to play?" before a pushed video. Measured: a blind OK at 2.5 s can land before
    /// the dialog (the TV first switches source), and an OK while the video runs would toggle pause.
    /// So press OK only while the TV has not reported the DLNA player running: up to 4 times, 2 s apart.
    /// A late "play" from the previous video can arrive after the new push, so the reported title must match too.
    static func acceptConsent(_ tv: TV, title: String) async {
        tv.dlnaPlaystate = ""; tv.dlnaName = ""
        for attempt in 1...4 {
            try? await Task.sleep(nanoseconds: attempt == 1 ? 1_500_000_000 : 2_000_000_000)
            // Our video runs if the TV names it (it may shorten or alter the title) or its DLNA clock moves.
            // Measured: a strict title match failed for "Менталист · S2E13", OK then toggled pause.
            let name = tv.dlnaName.lowercased(), want = title.lowercased()
            let named = !name.isEmpty && (name == want || want.hasPrefix(String(name.prefix(8))) || name.hasPrefix(String(want.prefix(8))))
            if ["start", "play"].contains(tv.dlnaPlaystate), named { return }
            if let st = await DLNA.state(host: tv.host), st.position > 0 { return }
            if MQTT.trace { NSLog("tinyTV consent: OK #%d (playstate '%@', name '%@')", attempt, tv.dlnaPlaystate, tv.dlnaName) }
            tv.key("KEY_OK")
        }
    }

    /// Can the torrent keep up? rate = file size / duration (what playback eats); if the download is slower, the
    /// buffer must hold the shortfall for the rest of the film: (remaining) * (1 - down / rate) seconds of video.
    private func engineStats() async {
        // The engine measures the buffer from the TV's own second and moves its download window there.
        guard let u = URL(string: "http://127.0.0.1:8890/ahead?sec=\(Int(displayPosition))"), let (d, _) = try? await URLSession.shared.data(from: u),
              let st = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        func num(_ k: String) -> Double { (st[k] as? NSNumber)?.doubleValue ?? 0 }
        let dur = num("durationSec") > 0 ? num("durationSec") : duration
        let rate = dur > 0 ? num("fileBytes") / dur : 0, down = num("down"), ahead = num("aheadSec"), progress = num("progress")
        // Owner: torrents remember where he stopped, like HDRezka (by the torrent's hash).
        if let h = st["hash"] as? String, displayPosition > 5, Date().timeIntervalSince(lastTorrentSave) > 5 {
            lastTorrentSave = Date(); Kino.shared.saveTorrent(h, position: displayPosition, duration: dur, name: st["name"] as? String ?? title)
        }
        let remaining = max(0, dur - displayPosition)
        let need = rate > 0 && down < rate ? remaining * (1 - down / rate) : 0
        let wait = need > ahead ? (need - ahead) * rate / max(down, 1) : 0
        // Owner: pause for the buffer instead of stuttering. Under 4 s ahead the TV pauses; it goes on with
        // at least 20 s ahead (more when the download is slower than playback, up to 2 min).
        let target = max(20, min(120, need))
        if bufferHold { holdSince = holdSince ?? Date() } else { holdSince = nil }
        if let h = holdSince, Date().timeIntervalSince(h) > 90, let fb = fallback {
            holdSince = nil; bufferHold = false; fallback = nil; status = "Торент повільний, повертаю HDRezka…"; return fb()
        }
        if rate > 0, progress < 0.999 {
            if playing, !bufferHold, ahead < 4, remaining > 5 { bufferHold = true; setPlaying(false, buffer: true) }
            else if bufferHold, ahead >= target { bufferHold = false; setPlaying(true, buffer: true) }
        } else if bufferHold { bufferHold = false; setPlaying(true, buffer: true) }
        torrent = ["down": down, "rate": rate, "ahead": ahead, "peers": num("peers"), "progress": progress,
                   "need": need, "wait": wait, "hold": bufferHold ? 1 : 0, "target": target]
    }

    /// Live position while something of ours plays.
    private func watch() {
        poll?.cancel()
        poll = Task {
            var idle = 0, tick = Date()
            while !Task.isCancelled, let tv {
                if let st = await DLNA.state(host: tv.host) {
                    let now = Date(), wasPlaying = playing
                    playing = st.state == "PLAYING"
                    if st.duration > 0, liveJob == nil { duration = st.duration }
                    // A live TS has no index: the TV reports 0, so count playing time ourselves - by the clock, since one
                    // round (DLNA query + 1 s sleep) is longer than a second and "+1" fell minutes behind over an episode.
                    if liveJob != nil, st.position == 0 { if playing && wasPlaying { position += min(now.timeIntervalSince(tick), 5) } }
                    else { position = st.position }
                    tick = now
                    // "Динаміки ТВ" follows the TV volume: a step of 3+ re-tunes the running ffmpeg, no restart.
                    if sound.preset == "tv", jobEQ, liveJob != nil, job?.isRunning == true, case let v = tv.volume, abs(v - eqVolume) >= 3, let i = jobIn {
                        eqVolume = v; SoundSettings.volume = v
                        try? i.fileHandleForWriting.write(contentsOf: Data(sound.commands.utf8))
                    }
                    if engineCast { await engineStats() }
                    // A file from the Media tab remembers its second too (key "file:<path>").
                    else if let f = currentFile, displayPosition > 5, Date().timeIntervalSince(lastTorrentSave) > 5 {
                        lastTorrentSave = Date(); Kino.shared.saveTorrent("file:" + f, position: displayPosition, duration: duration, name: title)
                    }
                    idle = st.state == "STOPPED" || st.state == "NO_MEDIA_PRESENT" ? idle + 1 : 0
                    if idle > 8 { title = ""; playing = false; break }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    /// Explicit play / pause. A toggle from a remote with a stale view (the watch) needed two presses.
    func setPlaying(_ p: Bool, buffer: Bool = false) {
        if !buffer { bufferHold = false }   // the owner's own play / pause wins over the buffer pause
        if remote { playing = p; return Remote.post("cast/pause", ["play": p]) }
        guard let tv else { return }
        playing = p
        Task { await DLNA.call(host: tv.host, p ? "Play" : "Pause", p ? "<Speed>1</Speed>" : "") }
    }

    func togglePause() {
        bufferHold = false
        if remote { playing.toggle(); return Remote.post("cast/pause") }
        guard let tv else { return }
        playing.toggle()
        let p = playing
        Task { await DLNA.call(host: tv.host, p ? "Play" : "Pause", p ? "<Speed>1</Speed>" : "") }
    }

    func seek(_ seconds: Double) {
        if remote { position = max(0, seconds); return Remote.post("cast/seek", ["t": max(0, seconds)]) }
        guard let tv else { return }
        if MQTT.trace { NSLog("tinyTV seek %.0f (live=%d)", seconds, liveJob == nil ? 0 : 1) }
        if let j = liveJob, j.inputs.count > 0 {
            position = 0
            position = 0
            if mix != nil, j.inputs.count == 2 {   // the aligned dub may not reach that second yet
                Task { await mixStart(j.ff, video: j.inputs[0], scale: j.scale, from: max(0, seconds)) }; return
            }
            return live(j.ff, inputs: j.inputs, scale: j.scale, from: max(0, seconds))
        }
        let s = max(0, Int(seconds)); position = Double(s)
        let t = String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
        // Measured 2026-10-21: after Seek this TV sometimes stays PAUSED_PLAYBACK. If it was playing, press Play again.
        let wasPlaying = playing || startAt > 0
        Task {
            await DLNA.call(host: tv.host, "Seek", "<Unit>REL_TIME</Unit><Target>\(t)</Target>")
            guard wasPlaying else { return }
            for _ in 0..<3 {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let st = await DLNA.state(host: tv.host) else { continue }
                if st.state == "PLAYING" { return }
                if st.state.hasPrefix("PAUSED") { await DLNA.call(host: tv.host, "Play", "<Speed>1</Speed>"); return }
            }
        }
    }

    func stop() {
        if remote { title = ""; playing = false; screen = ""; return Remote.post("cast/stop") }
        endScreen()
        MovieLight.shared.castChanged(playing: false)
        guard let tv else { return }
        job?.terminate(); job = nil; poll?.cancel(); liveJob = nil; endMix()
        fetchers.forEach { $0.terminate() }; fetchers = []; fetching = false
        title = ""; playing = false
        Task { await DLNA.call(host: tv.host, "Stop", "") }
    }

    /// Remote mode: mirror the core's cast state. Uploads from this Mac show their own progress.
    func apply(_ c: [String: Any]) {
        applying = true; defer { applying = false }
        if !Remote.shared.uploading {
            let st = c["status"] as? String ?? "", pr = c["progress"] as? Double ?? -1, f = c["failed"] as? Bool ?? false
            if st != status { status = st }
            if (pr < 0 ? nil : pr) != progress { progress = pr < 0 ? nil : pr }
            if f != failed { failed = f }
        }
        if let t = c["title"] as? String, t != title { title = t }
        if let l = c["link"] as? String, l != link { link = l }
        if let p = c["playing"] as? Bool, p != playing { playing = p }
        offset = 0
        if let p = c["position"] as? Double, abs(p - position) > 0.5 { position = p }
        let t = (c["torrent"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
        if t != torrent { torrent = t }
        if let d = c["duration"] as? Double, d != duration { duration = d }
        let tr = (c["tracks"] as? [[String: Any]] ?? []).compactMap { d in (d["i"] as? Int).map { (i: $0, label: d["label"] as? String ?? "") } }
        if tr.map(\.i) != tracks.map(\.i) || tr.map(\.label) != tracks.map(\.label) { tracks = tr }
        if let t = c["track"] as? Int, t != track { track = t }
        if let s = c["screen"] as? String, s != screen { screen = s }
        let w = (c["screenWindow"] as? Int).flatMap { $0 >= 0 ? UInt32($0) : nil }
        if w != screenWindow { screenWindow = w }
        if let l = c["screenLatency"] as? Double, l != screenLatency { screenLatency = l }
        if let p = c["screenPreset"] as? String, p != screenPreset { screenPreset = p }
        if let v = c["video"] as? [String: Any] {
            var n = video
            n.mode = v["mode"] as? String ?? n.mode; n.height = v["height"] as? Int ?? n.height
            n.hdr = v["hdr"] as? Bool ?? n.hdr; n.mbps = v["mbps"] as? Double ?? n.mbps
            if n != video { video = n }
        }
        if let v = c["sound"] as? [String: Any] {
            var n = sound
            n.preset = v["preset"] as? String ?? n.preset
            if let cu = (v["custom"] as? [Any])?.compactMap({ ($0 as? NSNumber)?.doubleValue }), cu.count == 5 { n.custom = cu }
            if n != sound { sound = n }
        }
    }

    /// Shown while this Mac uploads a dropped file to the core.
    func uploadStatus(_ s: String, _ p: Double?, failed f: Bool = false) { status = s; progress = p; failed = f }

    private func set(_ s: String, _ p: Double?) { status = s; progress = p; failed = false }
    func fail(_ s: String) {
        if let fb = fallback { fallback = nil; status = "Торент не пішов, повертаю HDRezka…"; return fb() }
        status = s; progress = nil; failed = true
        Task { try? await Task.sleep(nanoseconds: 6_000_000_000); if failed, status == s { status = ""; failed = false } }
    }

    /// Keeps the cache small: the 3 newest files stay.
    private func prune() {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let date = { (u: URL) in (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        items.sorted { date($0) > date($1) }.dropFirst(6).forEach { try? fm.removeItem(at: $0) }
    }

    nonisolated static func run(_ exe: String, _ args: [String]) -> (out: Data, err: Data) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = NSHomeDirectory() + "/tinyTV/tools/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        p.environment = env
        let o = Pipe(), e = Pipe(); p.standardOutput = o; p.standardError = e
        guard (try? p.run()) != nil else { return (Data(), Data()) }
        // A hung tool must not hold its caller (and a Swift concurrency thread) forever.
        DispatchQueue.global().asyncAfter(deadline: .now() + 120) { if p.isRunning { p.terminate() } }
        let errData = Tail()
        e.fileHandleForReading.readabilityHandler = { errData.add(String(decoding: $0.availableData, as: UTF8.self)) }
        let out = o.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        e.fileHandleForReading.readabilityHandler = nil
        return (out, Data(errData.text.utf8))
    }
}

enum DLNA {
    static func ctrl(_ host: String) -> URL { URL(string: "http://\(host):38400/upnp/control/mingusavtr")! }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    @discardableResult
    static func call(host: String, _ action: String, _ args: String) async -> String? {
        let st = "urn:schemas-upnp-org:service:AVTransport:1"
        var r = URLRequest(url: ctrl(host)); r.httpMethod = "POST"; r.timeoutInterval = 8
        r.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        r.setValue("\"\(st)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        r.httpBody = Data(("<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:\(action) xmlns:u=\"\(st)\"><InstanceID>0</InstanceID>\(args)</u:\(action)></s:Body></s:Envelope>").utf8)
        guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    static func load(host: String, url: String, mime: String, title: String) async -> Bool {
        let cls = mime.hasPrefix("audio") ? "object.item.audioItem.musicTrack" : "object.item.videoItem"
        let didl = #"<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:dc="http://purl.org/dc/elements/1.1/"><item id="0" parentID="-1" restricted="1"><dc:title>"#
            + esc(title) + "</dc:title><upnp:class>\(cls)</upnp:class><res protocolInfo=\"http-get:*:\(mime):*\">" + esc(url) + "</res></item></DIDL-Lite>"
        guard await call(host: host, "SetAVTransportURI", "<CurrentURI>\(esc(url))</CurrentURI><CurrentURIMetaData>\(esc(didl))</CurrentURIMetaData>") != nil
        else { return false }
        return await call(host: host, "Play", "<Speed>1</Speed>") != nil
    }

    struct State { let state: String; let position: Double; let duration: Double }

    static func state(host: String) async -> State? {
        guard let t = await call(host: host, "GetTransportInfo", ""), let p = await call(host: host, "GetPositionInfo", "") else { return nil }
        func tag(_ x: String, _ n: String) -> String {
            guard let a = x.range(of: "<\(n)>"), let b = x.range(of: "</\(n)>", range: a.upperBound..<x.endIndex) else { return "" }
            return String(x[a.upperBound..<b.lowerBound])
        }
        func secs(_ s: String) -> Double {
            let p = s.split(separator: ":").compactMap { Double($0) }
            return p.count == 3 ? p[0] * 3600 + p[1] * 60 + p[2] : 0
        }
        return State(state: tag(t, "CurrentTransportState"), position: secs(tag(p, "RelTime")), duration: secs(tag(p, "TrackDuration")))
    }
}

/// Last lines of a process's output, written from a pipe queue and read on exit.
final class Tail: @unchecked Sendable {
    private var s = "", lock = NSLock()
    func add(_ x: String) { lock.lock(); s = String((s + x).suffix(600)); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return s }
}

/// LAN media server for the TV: GET /m/<id>.<ext> with Range. Serves only registered sources.
final class MediaServer: @unchecked Sendable {
    static let port: NWEndpoint.Port = 8892
    enum Source { case file(URL), remote(URL), growing(URL), live }
    private var sources: [String: Source] = [:]
    private var done: Set<String> = []
    private let lock = NSLock()
    private var hit: Date?
    var lastHit: Date? {
        get { lock.lock(); defer { lock.unlock() }; return hit }
        set { lock.lock(); hit = newValue; lock.unlock() }
    }
    private var listener: NWListener?
    private let q = DispatchQueue(label: "tinytv.media", attributes: .concurrent)

    static func mime(_ ext: String) -> String {
        ["mkv": "video/x-matroska", "webm": "video/webm", "ts": "video/mp2ts", "m2ts": "video/mp2ts", "mts": "video/mp2ts",
         "avi": "video/x-msvideo", "mov": "video/quicktime", "mpg": "video/mpeg", "mpeg": "video/mpeg", "wmv": "video/x-ms-wmv",
         "flv": "video/x-flv", "mp3": "audio/mpeg", "m4a": "audio/mp4", "aac": "audio/aac", "flac": "audio/flac",
         "wav": "audio/x-wav", "ogg": "audio/ogg"][ext] ?? "video/mp4"
    }

    func add(_ s: Source) -> String {
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        lock.lock(); sources[id] = s; lock.unlock()
        return id
    }
    func finish(_ id: String) { lock.lock(); done.insert(id); lock.unlock() }
    private func get(_ id: String) -> (Source, Bool)? { lock.lock(); defer { lock.unlock() }; return sources[id].map { ($0, done.contains(id)) } }

    func start() {
        let p = NWParameters.tcp; p.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: p, on: MediaServer.port) else { NSLog("tinyTV media: cannot listen on 8892"); return }
        l.newConnectionHandler = { [weak self] c in self?.serve(c) }
        l.start(queue: q); listener = l
    }

    private func reply404(_ c: NWConnection) {
        c.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
               completion: .contentProcessed { _ in c.cancel() })
    }

    private func send(_ c: NWConnection, _ type: String, _ d: Data) {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(d.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + d, completion: .contentProcessed { _ in c.cancel() })
    }

    /// The phone HLS on the home network too: the LAN QR of "Watch here", for devices without Tailscale.
    private func watch(_ c: NWConnection, _ path: String) {
        let p = path.split(separator: "/").map(String.init)
        guard p.count == 3, p[1].allSatisfy({ $0.isLetter || $0.isNumber }), !p[2].contains(".."),
              let d = try? Data(contentsOf: PhoneWatch.dir.appendingPathComponent(p[1]).appendingPathComponent(p[2])) else { return reply404(c) }
        let type = p[2].hasSuffix(".m3u8") ? "application/vnd.apple.mpegurl" : p[2].hasSuffix(".m4s") ? "video/iso.segment" : "video/mp4"
        let head = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(d.count)\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + d, completion: .contentProcessed { _ in c.cancel() })
    }

    private func serve(_ c: NWConnection) {
        c.start(queue: q)
        c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] d, _, _, _ in
            guard let self, let d, let head = String(data: d, encoding: .utf8) else { c.cancel(); return }
            let lines = head.components(separatedBy: "\r\n")
            let parts = lines.first?.split(separator: " ") ?? []
            let method = parts.first.map(String.init) ?? ""
            let path = parts.count > 1 ? String(parts[1].split(separator: "?").first ?? "") : ""
            if path.hasPrefix("/watch/") { return self.watch(c, path) }
            // Paired screens (QR in Kino → Списки → Екрани): the receiver page and its 2 s poll.
            if path == "/screen" {
                let html = Bundle.main.url(forResource: "screen", withExtension: "html").flatMap { try? Data(contentsOf: $0) } ?? Data()
                return self.send(c, "text/html; charset=utf-8", html)
            }
            if path == "/screen/seek" {   // 1:1 seeking from a screen: the core restarts the stream at that second
                let q = parts.count > 1 ? String(parts[1].split(separator: "?").dropFirst().first ?? "") : ""
                let at = q.split(separator: "&").first { $0.hasPrefix("at=") }.flatMap { Double($0.dropFirst(3)) } ?? 0
                Task { @MainActor in
                    let r = await PhoneWatch.seek(at)
                    self.send(c, "application/json", (try? JSONSerialization.data(withJSONObject: r)) ?? Data("{}".utf8))
                }
                return
            }
            if path == "/screen/poll" {
                let q = parts.count > 1 ? String(parts[1].split(separator: "?").dropFirst().first ?? "") : ""
                let id = q.split(separator: "&").first { $0.hasPrefix("id=") }.map { String($0.dropFirst(3)) }.flatMap { $0.isEmpty ? nil : $0 }
                let d = (try? JSONSerialization.data(withJSONObject: Screens.poll(id))) ?? Data("{}".utf8)
                return self.send(c, "application/json", d)
            }
            let id = path.hasPrefix("/m/") ? String(path.dropFirst(3).split(separator: ".").first ?? "") : ""
            guard method == "GET" || method == "HEAD", let (src, finished) = self.get(id) else { return self.reply404(c) }
            self.lastHit = Date()
            let ext = (path as NSString).pathExtension.lowercased()
            var range: (Int, Int?)?
            if let r = lines.first(where: { $0.lowercased().hasPrefix("range: bytes=") }) {
                let spec = r.split(separator: "=", maxSplits: 1)[1].split(separator: "-", omittingEmptySubsequences: false)
                range = (Int(spec[0]) ?? 0, spec.count > 1 ? Int(spec[1]) : nil)
            }
            switch src {
            case .file(let u): self.sendFile(c, u, range, method, ext)
            case .growing(let u):
                if finished { self.sendFile(c, u, range, method, ext) } else { self.sendGrowing(c, u, range?.0 ?? 0, method, ext, id) }
            case .remote(let u): self.proxy(c, u, lines, method, ext)
            case .live: LiveRelay.shared.serve(c, head: method == "HEAD")
            }
        }
    }

    private func sendFile(_ c: NWConnection, _ u: URL, _ range: (Int, Int?)?, _ method: String, _ ext: String) {
        guard let fh = try? FileHandle(forReadingFrom: u),
              let size = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? nil, size > 0 else { return reply404(c) }
        let a = min(range?.0 ?? 0, size - 1), b = min(range?.1 ?? size - 1, size - 1)
        var h = range != nil ? "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes \(a)-\(b)/\(size)\r\n" : "HTTP/1.1 200 OK\r\n"
        h += "Content-Type: \(MediaServer.mime(ext))\r\nAccept-Ranges: bytes\r\nContent-Length: \(b - a + 1)\r\n"
        h += "transferMode.dlna.org: Streaming\r\nConnection: close\r\n\r\n"
        c.send(content: Data(h.utf8), completion: .contentProcessed { _ in })
        if method == "HEAD" { c.cancel(); return }
        try? fh.seek(toOffset: UInt64(a))
        var left = b - a + 1
        func pump() {
            guard left > 0 else { try? fh.close(); c.cancel(); return }
            let chunk = fh.readData(ofLength: min(1 << 18, left))
            guard !chunk.isEmpty else { try? fh.close(); c.cancel(); return }
            left -= chunk.count
            c.send(content: chunk, completion: .contentProcessed { err in if err != nil { try? fh.close(); c.cancel() } else { pump() } })
        }
        pump()
    }

    /// A file ffmpeg is still writing: no length, send what exists and wait for more until ffmpeg ends.
    private func sendGrowing(_ c: NWConnection, _ u: URL, _ from: Int, _ method: String, _ ext: String, _ id: String) {
        guard let fh = try? FileHandle(forReadingFrom: u) else { return reply404(c) }
        let h = "HTTP/1.1 200 OK\r\nContent-Type: \(MediaServer.mime(ext))\r\ntransferMode.dlna.org: Streaming\r\nConnection: close\r\n\r\n"
        c.send(content: Data(h.utf8), completion: .contentProcessed { _ in })
        if method == "HEAD" { c.cancel(); return }
        try? fh.seek(toOffset: UInt64(from))
        func pump() {
            let chunk = fh.readData(ofLength: 1 << 18)
            if chunk.isEmpty {
                if get(id)?.1 == true { try? fh.close(); c.cancel(); return }
                q.asyncAfter(deadline: .now() + 0.2) { pump() }; return
            }
            c.send(content: chunk, completion: .contentProcessed { err in if err != nil { try? fh.close(); c.cancel() } else { pump() } })
        }
        pump()
    }

    /// Streams a remote HTTPS file to the TV as plain HTTP, passing Range through so seeking works.
    private func proxy(_ c: NWConnection, _ u: URL, _ lines: [String], _ method: String, _ ext: String) {
        // YouTube (googlevideo) answers 403 to a plain GET or HEAD and only serves byte ranges (measured 2026-10-21:
        // the TV opened with a plain request, got 403 and stopped). Always ask upstream for a range; a plain request
        // from the TV gets "bytes=0-" upstream and a normal 200 back; HEAD becomes a 1-byte ranged GET.
        var r = URLRequest(url: u); r.httpMethod = "GET"; r.timeoutInterval = 30
        let asked = lines.first(where: { $0.lowercased().hasPrefix("range:") })
            .map { String($0.split(separator: ":", maxSplits: 1)[1]).trimmingCharacters(in: .whitespaces) }
        r.setValue(method == "HEAD" ? "bytes=0-0" : (asked ?? "bytes=0-"), forHTTPHeaderField: "Range")
        Task {
            guard let (bytes, resp) = try? await URLSession.shared.bytes(for: r), let http = resp as? HTTPURLResponse else { return reply404(c) }
            let total = (http.value(forHTTPHeaderField: "Content-Range") ?? "").split(separator: "/").last.flatMap { Int($0) }
            let ranged = asked != nil
            let code = http.statusCode == 206 && !ranged ? 200 : http.statusCode
            var h = "HTTP/1.1 \(code) \(code == 206 ? "Partial Content" : code == 200 ? "OK" : "Error")\r\n"
            h += "Content-Type: \(MediaServer.mime(ext))\r\nAccept-Ranges: bytes\r\n"
            if !ranged, let total { h += "Content-Length: \(total)\r\n" }
            else { for k in ["Content-Length", "Content-Range"] { if let v = http.value(forHTTPHeaderField: k) { h += "\(k): \(v)\r\n" } } }
            h += "transferMode.dlna.org: Streaming\r\nConnection: close\r\n\r\n"
            await send(c, Data(h.utf8))
            if method == "HEAD" { c.cancel(); return }
            var buf = Data(); buf.reserveCapacity(1 << 17)
            do {
                for try await b in bytes {
                    buf.append(b)
                    if buf.count >= 1 << 17 { guard await send(c, buf) else { break }; buf.removeAll(keepingCapacity: true) }
                }
                if !buf.isEmpty { await send(c, buf) }
            } catch {}
            c.cancel()
        }
    }

    @discardableResult
    private func send(_ c: NWConnection, _ d: Data) async -> Bool {
        await withCheckedContinuation { k in c.send(content: d, completion: .contentProcessed { k.resume(returning: $0 == nil) }) }
    }
}

/// Mutes this machine's output while its sound goes to the TV and restores the owner's own setting after.
enum HostSpeakers {
    nonisolated(unsafe) private static var wasMuted: Bool?

    static func mute() {
        guard wasMuted == nil else { return }
        let r = String(decoding: Caster.run("/usr/bin/osascript", ["-e", "output muted of (get volume settings)"]).out, as: UTF8.self)
        wasMuted = r.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        _ = Caster.run("/usr/bin/osascript", ["-e", "set volume output muted true"])
    }

    static func restore() {
        guard let w = wasMuted else { return }
        wasMuted = nil
        if !w { _ = Caster.run("/usr/bin/osascript", ["-e", "set volume output muted false"]) }
    }
}

/// Keeps the AirPlay FIFO open for reading all the time. shairport-sync opens it for writing at startup and blocks
/// until a reader exists (measured: it hung before opening its network port). PCM goes to ffmpeg only while
/// an AirPlay session plays; otherwise it is dropped.
final class AirPlayPipe: @unchecked Sendable {
    static let shared = AirPlayPipe()
    private let lock = NSLock()
    private var _sink: FileHandle?
    var sink: FileHandle? {
        get { lock.lock(); defer { lock.unlock() }; return _sink }
        set { lock.lock(); _sink = newValue; lock.unlock() }
    }

    func start() {
        let path = Caster.airplayFIFO
        Thread.detachNewThread { [self] in
            while true {
                if !FileManager.default.fileExists(atPath: path) { mkfifo(path, 0o666) }
                guard let fh = FileHandle(forReadingAtPath: path) else { Thread.sleep(forTimeInterval: 2); continue }  // waits for a writer
                while true {
                    let d = fh.availableData
                    if d.isEmpty { break }                       // writer closed: reopen and wait again
                    if let s = sink { do { try s.write(contentsOf: d) } catch { sink = nil } }
                }
                try? fh.close()
            }
        }
    }
}

/// Which processes produce sound right now (CoreAudio process objects, macOS 14.2+).
enum AudioOutput {
    static func isPlaying(processNamed name: String) -> Bool {
        let out = String(decoding: Caster.run("/usr/bin/pgrep", ["-x", name]).out, as: UTF8.self)
        let pids = Set(out.split(separator: "\n").compactMap { pid_t($0) })
        guard !pids.isEmpty else { return false }
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr, size > 0 else { return false }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return false }
        for id in ids {
            var pid: pid_t = 0, running: UInt32 = 0
            var s1 = UInt32(MemoryLayout<pid_t>.size), s2 = UInt32(MemoryLayout<UInt32>.size)
            var pa = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var ra = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &pa, 0, nil, &s1, &pid) == noErr, pids.contains(pid),
                  AudioObjectGetPropertyData(id, &ra, 0, nil, &s2, &running) == noErr else { continue }
            if running == 1 { return true }
        }
        return false
    }
}
