// tinyTV - menu bar remote for a Hisense VIDAA TV, in the style of tinyLight.
// Config: ~/Library/Application Support/tinyTV/config.json {"tv": "<TV IP>"} (see config.*.example.json)
import SwiftUI
import AppKit
import ServiceManagement
import WebKit

let accent = Color(red: 0.42, green: 0.62, blue: 1.0)

// MARK: - Controls (same feel as tinyLight)

struct GlowSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let track: [Color]
    let thumb: Color
    var enabled = true
    var onEnd: (() -> Void)? = nil
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, d: CGFloat = 20
            let f = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            ZStack(alignment: .leading) {
                Capsule().fill(LinearGradient(colors: track, startPoint: .leading, endPoint: .trailing))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
                Circle().fill(thumb)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                    .shadow(color: thumb.opacity(enabled ? 0.8 : 0), radius: dragging ? 8 : 4)
                    .frame(width: d, height: d)
                    .scaleEffect(dragging ? 1.18 : 1)
                    .offset(x: CGFloat(f) * (w - d))
            }
            .saturation(enabled ? 1 : 0).opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if !dragging { withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { dragging = true } }
                    let p = min(1, max(0, (g.location.x - d / 2) / (w - d)))
                    value = (range.lowerBound + Double(p) * (range.upperBound - range.lowerBound)).rounded()
                }
                .onEnded { _ in withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { dragging = false }; onEnd?() })
        }
        .frame(height: 20)
    }
}

struct Row<C: View>: View {
    let title: String, value: String
    @ViewBuilder let content: C
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Text(value).monospacedDigit().contentTransition(.numericText())
            }
            .font(.system(size: 12))
            content
        }
    }
}

struct FlowChips: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 288
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > w { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing; row = max(row, s.height)
        }
        return CGSize(width: w, height: y + row)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = b.minX, y = b.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > b.minX, x + s.width > b.maxX { x = b.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; row = max(row, s.height)
        }
    }
}

struct Chip: View {
    let title: String
    var icon: String? = nil
    var dot: Color? = nil
    var selected = false
    let action: () -> Void
    @State private var pressed = false
    var body: some View {
        Button(action: {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) { pressed = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { pressed = false }
            }
            action()
        }) {
            HStack(spacing: 5) {
                if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
                if let icon { Image(systemName: icon).font(.system(size: 10, weight: .semibold)) }
                Text(title).font(.system(size: 11)).lineLimit(1)
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(selected ? accent.opacity(0.28) : .primary.opacity(0.07), in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? accent.opacity(0.6) : .clear, lineWidth: 0.5))
            .scaleEffect(pressed ? 0.92 : 1)
        }
        .buttonStyle(.plain)
    }
}

struct KeyButton: View {
    let icon: String, key: String, label: String
    @EnvironmentObject var tv: TV
    @State private var pressed = false
    var body: some View {
        Button {
            tv.key(key)
            withAnimation(.spring(response: 0.18, dampingFraction: 0.5)) { pressed = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { pressed = false }
            }
        } label: {
            Image(systemName: icon).font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity).frame(height: 32)
                .background(pressed ? accent.opacity(0.35) : .primary.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .scaleEffect(pressed ? 0.9 : 1)
        }
        .buttonStyle(.plain)
        .help(label).accessibilityLabel(label)
    }
}

// MARK: - Link bar and shortcuts

func clock(_ t: Double) -> String {
    let s = Int(max(0, t)); return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
        : String(format: "%d:%02d", s / 60, s % 60)
}

/// What the TV plays from us: title, pause, scrubber, stop.
struct NowCasting: View {
    @ObservedObject var caster = Caster.shared
    @ObservedObject var tv = TV.shared
    @State private var scrub: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 11)).foregroundStyle(accent)
                    .symbolEffect(.pulse, isActive: caster.playing)
                Text(caster.title).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button { caster.stop() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Stop on TV").accessibilityLabel("Stop on TV")
            }
            HStack(spacing: 10) {
                Button { caster.togglePause() } label: {
                    Image(systemName: caster.playing ? "pause.fill" : "play.fill").font(.system(size: 13))
                        .frame(width: 30, height: 30)
                        .background(caster.playing ? AnyShapeStyle(Color.white.opacity(0.14)) : AnyShapeStyle(accent.opacity(0.45)),
                                    in: RoundedRectangle(cornerRadius: caster.playing ? 8 : 15, style: .continuous))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain).accessibilityLabel(caster.playing ? "Pause" : "Play")
                if let ep = tv.episode {
                    Button { Remote.post("kino/step", ["dir": -1]) } label: { Image(systemName: "backward.end.fill").font(.system(size: 11)) }
                        .buttonStyle(.plain).disabled(!ep.prev).help("Previous episode").accessibilityLabel("Previous episode")
                }
                Button { caster.seek(caster.displayPosition - 10) } label: { Image(systemName: "gobackward.10").font(.system(size: 12)) }
                    .buttonStyle(.plain).accessibilityLabel("Back 10 seconds")
                VStack(spacing: 3) {
                    GlowSlider(value: Binding(get: { scrub ?? caster.displayPosition },
                                              set: { scrub = $0 }),
                               range: 0...max(1, caster.duration), track: [Color(white: 0.18), accent], thumb: accent,
                               onEnd: { if let s = scrub { caster.seek(s) }; scrub = nil })
                    HStack {
                        Text(clock(scrub ?? caster.displayPosition)); Spacer(); Text(caster.duration > 0 ? clock(caster.duration) : "live")
                    }
                    .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                }
                Button { caster.seek(caster.displayPosition + 30) } label: { Image(systemName: "goforward.30").font(.system(size: 12)) }
                    .buttonStyle(.plain).accessibilityLabel("Forward 30 seconds")
                if let ep = tv.episode {
                    Button { Remote.post("kino/step", ["dir": 1]) } label: { Image(systemName: "forward.end.fill").font(.system(size: 11)) }
                        .buttonStyle(.plain).disabled(!ep.next).help("Next episode").accessibilityLabel("Next episode")
                }
            }
            if let rate = caster.torrent["rate"], rate > 0 {
                let t = caster.torrent, mb = { (v: Double) in String(format: "%.1f", v / 1_048_576) }
                let down = t["down"] ?? 0, ahead = Int(t["ahead"] ?? 0), wait = Int(t["wait"] ?? 0)
                let tail = t["hold"] == 1 ? "buffering to \(Int(t["target"] ?? 20)) s" : down >= rate ? "keeps up" : wait > 0 ? "pause ~\(wait >= 60 ? "\((wait + 59) / 60) min" : "\(wait) s"), then no stops" : "buffer is enough"
                Text("↓ \(mb(down)) MB/s · needs \(mb(rate)) · buffer \(ahead / 60):\(String(format: "%02d", ahead % 60)) · \(Int(t["peers"] ?? 0)) peers · \(tail)")
                    .font(.system(size: 10)).monospacedDigit().foregroundStyle(down >= rate ? Color.secondary : Color.yellow)
            }
            if caster.tracks.count > 1 {
                Menu {
                    ForEach(caster.tracks, id: \.i) { t in
                        Button { caster.setTrack(t.i) } label: {
                            if t.i == caster.track { Label(t.label, systemImage: "checkmark") } else { Text(t.label) }
                        }
                    }
                } label: {
                    Label(caster.tracks.first { $0.i == caster.track }?.label ?? "Audio", systemImage: "waveform")
                        .font(.system(size: 11)).lineLimit(1)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Audio track")
            }
        }
        .padding(10)
        .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(accent.opacity(0.25), lineWidth: 0.5))
    }
}

struct LinkBar: View {
    @EnvironmentObject var tv: TV
    @ObservedObject var caster = Caster.shared
    @State private var link = ""
    @State private var sent = false
    @State private var naming = false
    @State private var name = ""
    @FocusState private var nameFocus: Bool

    func send(_ u: String) {
        LinkBar.lastSent = u.trimmingCharacters(in: .whitespacesAndNewlines)
        tv.open(u)
        link = ""
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { sent = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation(.easeOut(duration: 0.3)) { sent = false } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "link").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Paste a video link (YouTube and more)", text: $link)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .onSubmit { send(link) }
                Button {
                    if link.isEmpty, let s = NSPasteboard.general.string(forType: .string) { link = s }
                    send(link)
                } label: {
                    Image(systemName: sent ? "checkmark" : "arrow.up.forward.app.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 24)
                        .background(sent ? Color.green : accent, in: Capsule())
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .help("Open on TV (empty field = clipboard)")
            }
            .padding(.leading, 10).padding(.trailing, 4).padding(.vertical, 4)
            .background(.primary.opacity(0.07), in: Capsule())

            if !caster.status.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text(caster.status).font(.system(size: 11))
                        .foregroundStyle(caster.failed ? Color.orange : .secondary)
                        .contentTransition(.opacity)
                    if let p = caster.progress {
                        GeometryReader { g in
                            Capsule().fill(.primary.opacity(0.08))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(accent).frame(width: max(6, g.size.width * p))
                                        .shadow(color: accent.opacity(0.7), radius: 4)
                                }
                        }
                        .frame(height: 4)
                        .animation(.easeOut(duration: 0.3), value: p)
                    }
                }
                .padding(.horizontal, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            FlowChips {
                ForEach(tv.shortcuts) { s in
                    Chip(title: s.name, icon: "bolt.fill") { send(s.url) }
                        .contextMenu {
                            Button("Copy link") {
                                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s.url, forType: .string)
                            }
                            Button("Delete \"\(s.name)\"", role: .destructive) {
                                withAnimation { tv.shortcuts.removeAll { $0.id == s.id } }
                            }
                        }
                        .help(s.url)
                        .transition(.scale.combined(with: .opacity))
                }
                if naming {
                    TextField("Name", text: $name)
                        .textFieldStyle(.plain).font(.system(size: 11)).frame(width: 90)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(.primary.opacity(0.1), in: Capsule())
                        .focused($nameFocus)
                        .onSubmit {
                            let n = name.trimmingCharacters(in: .whitespaces)
                            if !n.isEmpty, !link.isEmpty { tv.shortcuts.append(Shortcut(name: n, url: link)) }
                            withAnimation(.spring(response: 0.3)) { naming = false; name = "" }
                        }
                        .onExitCommand { withAnimation { naming = false; name = "" } }
                } else {
                    Button { withAnimation(.spring(response: 0.3)) { naming = true }; nameFocus = true } label: {
                        Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                            .frame(width: 26, height: 24)
                            .background(.primary.opacity(0.07), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(link.isEmpty)
                    .opacity(link.isEmpty ? 0.4 : 1)
                    .help("Save the link above as a shortcut")
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: tv.shortcuts)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: caster.status.isEmpty)
        .onAppear {
            // A fresh link or magnet on the clipboard fills the field: one press sends it.
            guard link.isEmpty, let c = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  c != LinkBar.lastSent, c.count < 4000,
                  c.hasPrefix("http") || c.lowercased().hasPrefix("magnet:") || c.hasPrefix("/") else { return }
            link = c
        }
    }
    static var lastSent = ""
}

// MARK: - Mouse pad

struct MousePad: View {
    @EnvironmentObject var tv: TV
    @EnvironmentObject var mouse: MouseBridge
    @ObservedObject var caster = Caster.shared
    @State private var breathe = false
    @State private var hovering = false
    @State private var hud: String?
    @State private var monitor: Any?
    @State private var gesture = Swipe()

    /// One two-finger swipe over the pad while a video plays (owner): up / down = volume, left / right = seek,
    /// a longer and faster swipe jumps further.
    struct Swipe { var axis = 0; var acc: CGFloat = 0; var peak: CGFloat = 0; var vol: Double = 0 }

    private func scroll(_ e: NSEvent) -> NSEvent? {
        guard hovering, !mouse.active, !caster.title.isEmpty, e.momentumPhase.isEmpty else { return e }
        if e.phase == .began || e.phase == .mayBegin { gesture = Swipe(vol: tv.volume) }
        let inv: CGFloat = e.isDirectionInvertedFromDevice ? -1 : 1
        let dx = e.scrollingDeltaX * inv, dy = e.scrollingDeltaY * inv
        if gesture.axis == 0, max(abs(dx), abs(dy)) > 3 { gesture.axis = abs(dx) > abs(dy) ? 1 : 2 }
        if gesture.axis == 2 {
            gesture.acc += dy
            let v = max(0, min(100, (gesture.vol + Double(gesture.acc / 12)).rounded()))
            if v != tv.volume { tv.volume = v; flash("Гучність \(Int(v))") }
        } else if gesture.axis == 1 {
            gesture.acc += dx; gesture.peak = max(gesture.peak, abs(dx))
            flash(seekLabel(seconds()))
        }
        if e.phase == .ended || e.phase == .cancelled {
            if gesture.axis == 1, abs(seconds()) >= 5 { caster.seek(max(0, caster.displayPosition + seconds())) }
            gesture = Swipe()
        }
        return nil
    }

    private func seconds() -> Double {
        // ~10 s per 60 pt; a fast flick (peak > 25 pt per event) triples it. Steps of 5 s, up to 10 min.
        let base = Double(abs(gesture.acc)) / 60 * 10 * (gesture.peak > 25 ? 3 : 1)
        return (gesture.acc < 0 ? -1 : 1) * min(600, (base / 5).rounded() * 5)
    }
    private func seekLabel(_ s: Double) -> String { abs(s) >= 60 ? String(format: "%@%d:%02d", s < 0 ? "−" : "+", Int(abs(s)) / 60, Int(abs(s)) % 60) : (s < 0 ? "−" : "+") + "\(Int(abs(s))) с" }
    private func flash(_ t: String) {
        hud = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if hud == t { withAnimation(.easeOut(duration: 0.3)) { hud = nil } } }
    }

    var arrow: String {
        switch mouse.lastDir {
        case "KEY_UP": "chevron.up"; case "KEY_DOWN": "chevron.down"
        case "KEY_LEFT": "chevron.left"; case "KEY_RIGHT": "chevron.right"
        case "KEY_RETURNS": "arrow.uturn.backward"
        default: "circle.fill"
        }
    }

    var body: some View {
        let on = mouse.active
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.primary.opacity(on ? 0.1 : 0.05))
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(on ? accent.opacity(breathe ? 0.9 : 0.4) : .primary.opacity(0.1), lineWidth: on ? 1.5 : 0.5)
            RadialGradient(colors: [accent.opacity(on ? 0.3 : 0), .clear], center: .center, startRadius: 0, endRadius: 70)
                .offset(mouse.nudge)
                .allowsHitTesting(false)
            if on {
                VStack(spacing: 6) {
                    Image(systemName: mouse.cursorMode ? "cursorarrow" : arrow).font(.system(size: 22, weight: .semibold)).foregroundStyle(accent)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 44, height: 34)
                        .offset(mouse.nudge)
                    Text(mouse.cursorMode ? "Real cursor on the TV Cast page" : "Arrow keys on the TV")
                        .font(.system(size: 11, weight: .medium))
                        .contentTransition(.opacity)
                    Text("click OK · delete Back · right click or Esc releases")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "cursorarrow.motionlines").font(.system(size: 20)).foregroundStyle(.secondary)
                    Text("Click to move the TV with this trackpad").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }
        }
        .overlay {
            if let hud {
                Text(hud).font(.system(size: 20, weight: .semibold)).monospacedDigit()
                    .padding(.horizontal, 14).padding(.vertical, 8).background(.black.opacity(0.45), in: Capsule())
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if !on, !caster.title.isEmpty, hud == nil {
                Text("two fingers: ↕ volume · ↔ seek").font(.system(size: 10)).foregroundStyle(.tertiary).padding(.bottom, 8)
            }
        }
        .frame(height: 128)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onAppear { monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { scroll($0) } }
        .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
        .onTapGesture { if !on { mouse.start() } }
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: on)
        .onChange(of: on) { _, v in
            if v { withAnimation(.easeInOut(duration: 1.1).repeatForever()) { breathe = true } } else { breathe = false }
        }
        .accessibilityLabel("Trackpad for the TV")
    }
}

// MARK: - Video settings

/// Sound to the TV: presets; the five bands only for "Custom" (owner: equalizer hidden smartly).
struct SoundSection: View {
    @ObservedObject var caster = Caster.shared
    @State private var open = false
    private let presets = [("flat", "Flat"), ("soft", "Less treble"), ("dialog", "Dialogue"), ("night", "Night"), ("bass", "More bass"), ("custom", "Custom")]
    private let freqs = ["60", "250", "1k", "4k", "12k"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { open.toggle() } } label: {
                HStack {
                    Text("Sound to TV").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Text(presets.first { $0.0 == caster.sound.preset }?.1 ?? "").font(.system(size: 11)).foregroundStyle(.tertiary)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary).rotationEffect(.degrees(open ? 90 : 0))
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if open {
                Picker("", selection: Binding(get: { caster.sound.preset }, set: { var s = caster.sound; s.preset = $0; caster.sound = s })) {
                    ForEach(presets, id: \.0) { Text($0.1).tag($0.0) }
                }.pickerStyle(.menu).labelsHidden()
                if caster.sound.preset == "custom" {
                    HStack(spacing: 10) {
                        ForEach(0..<5, id: \.self) { i in
                            VStack(spacing: 4) {
                                Text("\(Int(caster.sound.custom[i]))").font(.system(size: 10)).monospacedDigit()
                                Slider(value: Binding(get: { caster.sound.custom[i] }, set: { var s = caster.sound; s.custom[i] = $0.rounded(); caster.sound = s }),
                                       in: -12...8).rotationEffect(.degrees(-90)).frame(width: 90, height: 24).frame(width: 30, height: 90)
                                Text(freqs[i]).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct VideoSection: View {
    @ObservedObject var caster = Caster.shared
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { open.toggle() } } label: {
                HStack {
                    Text("Video to TV").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Text(summary).font(.system(size: 11)).foregroundStyle(.tertiary).contentTransition(.opacity)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary).rotationEffect(.degrees(open ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("", selection: $caster.video.mode) {
                        Text("Auto").tag("auto"); Text("Original").tag("original"); Text("Encode").tag("encode")
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .help("Auto re-encodes only files that are too heavy for the TV's Wi-Fi or larger than the size below")
                    Picker("", selection: $caster.video.height) {
                        Text("4K").tag(2160); Text("1440p").tag(1440); Text("1080p").tag(1080); Text("720p").tag(720)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    Picker("", selection: $caster.video.hdr) {
                        Text("HDR · 10-bit").tag(true); Text("SDR · 8-bit").tag(false)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    Row(title: "Bitrate", value: "\(Int(caster.video.mbps)) Mbit/s") {
                        GlowSlider(value: $caster.video.mbps, range: 4...40, track: [Color(white: 0.18), accent], thumb: accent)
                    }
                    Text("TV Wi-Fi measured at ~48 Mbit/s. Changes apply at once.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
            }
        }
        .clipped()
    }

    var summary: String {
        let v = caster.video
        let h = v.height == 2160 ? "4K" : "\(v.height)p"
        return v.mode == "original" ? "Original" : "\(v.mode == "auto" ? "Auto · " : "")\(h) · \(v.hdr ? "HDR" : "SDR") · \(Int(v.mbps)) Mb"
    }
}

// MARK: - Screen to TV

struct ScreenRow: View {
    @ObservedObject var caster = Caster.shared
    @State private var windows: [(id: UInt32, title: String)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Screen to TV").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                if !caster.screen.isEmpty {
                    Text(caster.screenLatency > 0 ? String(format: "live · %.1f s delay", caster.screenLatency) : "live")
                        .font(.system(size: 10)).monospacedDigit().foregroundStyle(accent)
                        .help("End-to-end delay, measured with a photo of the Mac clock next to the TV")
                }
            }
            FlowChips {
                Chip(title: "This Mac", icon: "laptopcomputer", selected: caster.screen == "mac" && caster.screenWindow == nil) {
                    caster.startScreen("mac")
                }
                Menu {
                    if windows.isEmpty { Text("No windows (allow Screen Recording)") }
                    ForEach(windows, id: \.id) { w in Button(w.title) { caster.startScreen("mac", window: w.id) } }
                } label: {
                    Label(caster.screen == "mac" && caster.screenWindow != nil ? "Window ✓" : "Window", systemImage: "macwindow")
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton).controlSize(.small).font(.system(size: 11)).fixedSize()
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(caster.screen == "mac" && caster.screenWindow != nil ? accent.opacity(0.28) : .primary.opacity(0.07), in: Capsule())
                .help("Show one window (a browser tab, a video) on the TV")
                Chip(title: "Extend", icon: "rectangle.on.rectangle", selected: caster.screen == "mac-extend") { caster.startScreen("mac-extend") }
                    .help("The TV becomes a second display of this Mac")
                Chip(title: "Audio", icon: "speaker.wave.2", selected: caster.screen == "mac-audio") { caster.startScreen("mac-audio") }
                    .help("Only this Mac's sound on the TV")
                Chip(title: "Core", icon: "desktopcomputer", selected: caster.screen == "core") { caster.startScreen("core") }
                if !caster.screen.isEmpty {
                    Chip(title: "Delay clock", icon: "stopwatch") { DelayClock.show() }
                        .help("Big clock on this Mac: photograph it next to the TV to measure the delay")
                }
            }
            Picker("", selection: $caster.screenPreset) {
                ForEach(ScreenPreset.all, id: \.id) { p in Text(p.label).tag(p.id) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .help("Fast: 720p, 4 Mbit/s, short keyframe gap. Balanced: 1080p, 12 Mbit/s. Quality: 4K HEVC, 25 Mbit/s")
        }
        .task { windows = await ScreenCapture.windows() }
    }
}

/// A big millisecond clock: on the TV it shows a moment ago, so one photo of both gives the delay.
enum DelayClock {
    @MainActor static var window: NSWindow?
    @MainActor static func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: .init(x: 120, y: 160, width: 760, height: 260), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "tinyTV delay clock"; w.isReleasedWhenClosed = false; w.level = .floating
        w.contentView = NSHostingView(rootView: TimelineView(.animation) { t in
            Text(t.date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second().secondFraction(.fractional(2))))
                .font(.system(size: 110, weight: .bold, design: .monospaced))
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(.black).foregroundStyle(.white)
        })
        w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        window = w
    }
}

// MARK: - Panel

/// Real translucency for the menu bar window: a clear window over a behind-window HUD material (owner: concept A).
struct GlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow; v.blendingMode = .behindWindow; v.state = .active
        v.alphaValue = 0.25   // owner: "ще прозоріше"; 1.0 = system HUD density
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.isOpaque = false; w.backgroundColor = .clear
            // The MenuBarExtra window brings its own material under ours; a clear mask turns it off without hiding the content it holds.
            let clear = NSImage(size: .init(width: 8, height: 8), flipped: false) { r in NSColor.clear.set(); r.fill(using: .copy); return true }
            func strip(_ s: NSView) {
                if let e = s as? NSVisualEffectView, e !== v { e.maskImage = clear }
                s.subviews.forEach(strip)
            }
            if let root = w.contentView?.superview ?? w.contentView { strip(root) }
        }
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

enum PanelTab: String, CaseIterable { case remote = "Пульт", kino = "Кіно", screen = "Екран" }

struct TabBar: View {
    @Binding var tab: PanelTab
    @Namespace private var ns
    var body: some View {
        HStack(spacing: 0) {
            ForEach(PanelTab.allCases, id: \.self) { t in
                Text(t.rawValue)
                    .font(.system(size: 12, weight: tab == t ? .semibold : .regular))
                    .foregroundStyle(tab == t ? .primary : .secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                    .background {
                        if tab == t {
                            Capsule().fill(.white.opacity(0.16))
                                .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
                                .matchedGeometryEffect(id: "tab", in: ns)
                        }
                    }
                    .contentShape(Capsule())
                    .onTapGesture { withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) { tab = t } }
            }
        }
        .padding(3)
        .background(.white.opacity(0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
    }
}

struct Panel: View {
    @EnvironmentObject var tv: TV
    @ObservedObject var caster = Caster.shared
    @EnvironmentObject var mouse: MouseBridge
    @State private var tab: PanelTab = CommandLine.arguments.contains("--kino") ? .kino
        : CommandLine.arguments.contains("--screen") ? .screen : .remote
    @State private var dropping = false
    @State private var typing = ""
    @State private var allApps = false

    var header: some View {
        HStack(spacing: 8) {
            let dot: Color = tv.connected ? .green : tv.offline ? .gray : .orange
            Circle().fill(dot).frame(width: 8, height: 8)
                .shadow(color: dot.opacity(tv.connected ? 0.7 : 0), radius: 4)
            VStack(alignment: .leading, spacing: 0) {
                Text("Hisense TV").font(.system(size: 13, weight: .semibold))
                Text(tv.connected ? (tv.nowPlaying.isEmpty ? tv.host : tv.nowPlaying)
                     : tv.offline ? "Off or asleep · power wakes it" : "Connecting to \(tv.host)…")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    .contentTransition(.opacity)
            }
            Spacer()
            Button { tv.power() } label: {
                Image(systemName: "power").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tv.connected ? Color.red : accent)
                    .frame(width: 26, height: 26)
                    .background(.white.opacity(0.1), in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .help(tv.connected ? "Turn the TV off" : "Wake the TV (Wake-on-LAN)")
            .accessibilityLabel(tv.connected ? "Turn the TV off" : "Wake the TV")
        }
    }

    var remote: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !caster.title.isEmpty {
                NowCasting().transition(.move(edge: .top).combined(with: .opacity))
            }
            LinkBar()
            MousePad()
            HStack(spacing: 6) {
                KeyButton(icon: "arrow.uturn.backward", key: "KEY_RETURNS", label: "Back")
                KeyButton(icon: "house", key: "KEY_HOME", label: "Home")
                KeyButton(icon: "line.3.horizontal", key: "KEY_MENU", label: "Menu")
                KeyButton(icon: "playpause", key: "KEY_PLAY", label: "Play / pause")
                KeyButton(icon: "cursorarrow.rays", key: "KEY_LEFTMOUSEKEYS", label: "TV cursor on / off")
            }
        }
        .disabled(!tv.connected)
        .opacity(tv.connected ? 1 : 0.4)
        .saturation(tv.connected ? 1 : 0)
    }

    var screen: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScreenRow()
            // A movie on this Mac: goes to the core host (~/Movies/tinyTV) and plays on the TV; dropping a file on the panel does the same.
            Button {
                let p = NSOpenPanel(); p.allowsMultipleSelection = false; p.canChooseDirectories = false
                p.allowedContentTypes = [.movie, .audiovisualContent, .audio]
                NSApp.activate(ignoringOtherApps: true)
                if p.runModal() == .OK, let u = p.url { Caster.shared.tv = tv; Caster.shared.file(u.path) }
            } label: {
                Label("File from this Mac…", systemImage: "film").font(.system(size: 12))
                    .padding(.horizontal, 12).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.07), in: Capsule())
            }
            .buttonStyle(.plain)
            HStack(spacing: 6) {
                Image(systemName: "keyboard").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Type into the TV field", text: $typing)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .onSubmit { tv.type(typing); typing = "" }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.white.opacity(0.07), in: Capsule())
            if !tv.apps.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Apps").font(.system(size: 11)).foregroundStyle(.secondary)
                    FlowChips {
                        ForEach(allApps ? tv.apps : Array(tv.apps.prefix(6))) { a in
                            Chip(title: a.name) { tv.launch(a) }.transition(.scale.combined(with: .opacity))
                        }
                        if tv.apps.count > 6 {
                            Chip(title: allApps ? "Less" : "+\(tv.apps.count - 6)") {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { allApps.toggle() }
                            }
                        }
                    }
                }
            }
            if !tv.sources.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Inputs").font(.system(size: 11)).foregroundStyle(.secondary)
                    FlowChips {
                        ForEach(tv.sources) { s in
                            Chip(title: s.name, dot: s.signal ? .green : .primary.opacity(0.2)) { tv.source(s) }
                        }
                    }
                }
            }
            VideoSection()
                SoundSection()
            Toggle(isOn: $caster.movieLight) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Movie light").font(.system(size: 12))
                    Text("Dims the room light while a cast plays, back on pause").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            .toggleStyle(.switch).controlSize(.mini).tint(accent)
            HStack {
                Button("Refresh") { tv.refresh() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            TabBar(tab: $tab)
            Group {
                switch tab {
                case .remote: remote
                case .kino: KinoWindow().frame(height: 600).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                case .screen: screen
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            // Owner: volume on every tab; Kino has its own in the player, so none here.
            if tab != .kino {
                HStack(spacing: 8) {
                    Button { tv.key("KEY_MUTE") } label: {
                        Image(systemName: tv.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 11)).frame(width: 18)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain).accessibilityLabel("Mute")
                    GlowSlider(value: $tv.volume, range: 0...100, track: [.white.opacity(0.12), accent], thumb: .white)
                    Text("\(Int(tv.volume))").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 22, alignment: .trailing).contentTransition(.numericText())
                }
                .disabled(!tv.connected)
            }
        }
        .padding(14)
        .frame(width: tab == .kino ? 440 : 320)
        .background(GlassBackground().ignoresSafeArea())
        .background(alignment: .top) {
            RadialGradient(colors: [accent.opacity(tv.connected ? 0.22 : 0.06), .clear],
                           center: .top, startRadius: 0, endRadius: 220)
                .allowsHitTesting(false)
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.85), value: tab)
        .animation(.easeInOut(duration: 0.35), value: tv.connected)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: caster.title.isEmpty)
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(accent, style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                    .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(Label("Play on TV", systemImage: "play.tv").font(.system(size: 14, weight: .semibold)))
                    .padding(6).transition(.opacity)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropping.animation(.easeOut(duration: 0.15))) { items in
            _ = items.first?.loadObject(ofClass: URL.self) { u, _ in
                if let u { Task { @MainActor in Caster.shared.tv = tv; Caster.shared.file(u.path) } }
            }
            return true
        }
        .onAppear { mouse.tv = tv; Caster.shared.tv = tv; tv.refresh() }
        .onDisappear { mouse.stop() }
    }
}

@main
struct TinyTVApp: App {
    // One shared instance each: two MQTT clients with the same client_id kick each other off the TV broker.
    @ObservedObject private var tv = TV.shared
    @ObservedObject private var mouse = MouseBridge.shared

    init() {
        if CommandLine.arguments.contains("--window") {
            // Debug: show the panel in a normal window so it can be captured.
            let tv = TV.shared, mouse = MouseBridge.shared
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let w = NSWindow(contentRect: .init(x: 200, y: 200, width: 320, height: 600),
                                 styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
                w.titlebarAppearsTransparent = true; w.title = "tinyTV"
                let v = NSVisualEffectView(); v.material = .popover; v.state = .active
                let h = NSHostingView(rootView: Panel().environmentObject(tv).environmentObject(mouse))
                h.translatesAutoresizingMaskIntoConstraints = false
                v.addSubview(h)
                NSLayoutConstraint.activate([h.leadingAnchor.constraint(equalTo: v.leadingAnchor),
                    h.trailingAnchor.constraint(equalTo: v.trailingAnchor),
                    h.topAnchor.constraint(equalTo: v.topAnchor, constant: 20), h.bottomAnchor.constraint(equalTo: v.bottomAnchor)])
                w.contentView = v; w.setContentSize(h.fittingSize); w.level = .floating; w.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        } else if SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
    }

    var body: some Scene {
        MenuBarExtra {
            Panel().environmentObject(tv).environmentObject(mouse)
        } label: {
            Image(systemName: tv.connected ? "tv.fill" : "tv")
        }
        .menuBarExtraStyle(.window)

    }
}

struct KinoWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        // Owner: the phone player inside the panel needs real full screen (off by default in WKWebView).
        let cfg = WKWebViewConfiguration()
        cfg.preferences.isElementFullscreenEnabled = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let w = WKWebView(frame: .zero, configuration: cfg)
        let base = TV.config["core"] ?? "http://127.0.0.1:8891"
        w.load(URLRequest(url: URL(string: base + "/kino?embed=1")!))
        w.setValue(false, forKey: "drawsBackground")
        return w
    }
    func updateNSView(_ v: WKWebView, context: Context) {}
}
