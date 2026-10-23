// tinyTV - menu bar remote for a Hisense VIDAA TV, in the style of tinyLight.
// Config: ~/Library/Application Support/tinyTV/config.json {"tv": "192.168.0.38"}
import SwiftUI
import AppKit
import AVFoundation
import ServiceManagement
import WebKit
import CoreImage

let accent = Color(red: 0.42, green: 0.62, blue: 1.0)
/// The same blue, deeper: white text on `accent` itself is only 2.5:1, on this it is 5:1 (review 29).
let accentFill = Color(red: 0.20, green: 0.40, blue: 0.92)

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
            .contentShape(Rectangle().inset(by: -4))   // a 28 pt grab area; nothing moves (review 12)
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

/// Owner: a saved shortcut must be removable without hunting for the right-click menu: an x shows on hover.
struct RemoveBadge: View {
    let remove: () -> Void
    @State private var near = false
    var body: some View {
        Color.clear.frame(width: 26, height: 22)
            .overlay(alignment: .topTrailing) {
                Button(action: { haptic(); remove() }) {
                    Image(systemName: "xmark").font(.system(size: 7, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 15, height: 15).background(Color.secondary, in: Circle())
                        .contentShape(Rectangle().inset(by: -7))   // the cross looks small, the target is 29 pt (review 12)
                }
                .buttonStyle(.plain).opacity(near ? 1 : 0).offset(x: 5, y: -5).help("Видалити").accessibilityLabel("Видалити")
            }
            .contentShape(Rectangle())
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { near = h } }
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
            .padding(.horizontal, 10).padding(.vertical, 7)   // 28 pt tall: a Mac target (review 12)
            .background(selected ? accent.opacity(0.28) : .primary.opacity(0.07), in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? accent.opacity(0.6) : .clear, lineWidth: 0.5))
            .scaleEffect(pressed ? 0.92 : 1)
        }
        .buttonStyle(Press())
    }
}

struct KeyButton: View {
    let icon: String, key: String, label: String
    var help: String? = nil
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
            // The concept names every key under its icon; the target is 40 pt (was an icon alone, 32 pt).
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 13, weight: .medium))
                Text(label).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity).frame(height: 40)
            .background(pressed ? accent.opacity(0.35) : .primary.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .scaleEffect(pressed ? 0.9 : 1)
        }
        .buttonStyle(Press())
        .help(help ?? label).accessibilityLabel(help ?? label)
    }
}

// MARK: - Where it plays (review 1)

/// Every "play this" on the Mac has two honest targets: the Hisense TV, or this Mac's own window (Watch.swift).
enum Dest { case tv, here }

/// One of the two target buttons. The main one is filled, the other is quiet; one that cannot work now is dimmed, not hidden.
struct DestButton: View {
    let dest: Dest
    var primary = false
    var enabled = true
    var done = false
    var help: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: done ? "checkmark" : dest == .tv ? "tv" : "macwindow").font(.system(size: 10, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                Text(dest == .tv ? "ТВ" : "Тут").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(primary || done ? Color.white : Color.primary)
            .padding(.horizontal, 10).frame(height: 28)
            .background(done ? Color.green : primary ? accentFill : Color.primary.opacity(0.1), in: Capsule())
        }
        .buttonStyle(Press())
        .disabled(!enabled).opacity(enabled ? 1 : 0.4)
        .help(help ?? (dest == .tv ? "Дивитись на Hisense TV" : "Дивитись тут, у вікні цього Mac"))
        .accessibilityLabel(dest == .tv ? "Дивитись на ТВ" : "Дивитись тут")
    }
}

/// A short word under the tabs: what just happened, and one way back (review 6, 7). It goes away by itself.
@MainActor
final class PanelToast: ObservableObject {
    static let shared = PanelToast()
    @Published private(set) var text: String?
    @Published private(set) var actionTitle: String?
    private var run: (@MainActor () -> Void)?
    private var timer: DispatchWorkItem?

    func show(_ text: String, actionTitle: String? = nil, seconds: Double = 6, action: (@MainActor () -> Void)? = nil) {
        timer?.cancel()
        run = actionTitle == nil ? nil : action
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { self.text = text; self.actionTitle = actionTitle }
        let job = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.hide() } }
        timer = job; DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: job)
    }
    func perform() { let r = run; hide(); r?() }
    func hide() {
        timer?.cancel(); run = nil
        withAnimation(.easeOut(duration: 0.25)) { text = nil; actionTitle = nil }
    }
}

struct ToastBar: View {
    @ObservedObject var toast = PanelToast.shared
    var body: some View {
        if let text = toast.text {
            HStack(spacing: 10) {
                Text(text).font(.system(size: 12)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let a = toast.actionTitle {
                    Button(a) { toast.perform() }
                        .buttonStyle(Press()).font(.system(size: 12, weight: .semibold)).foregroundStyle(accent)
                        .frame(minHeight: 28)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 3).frame(minHeight: 34)
            .background(.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .combine)
        }
    }
}

/// The TV is away (off, asleep, off its Wi-Fi: it happens often): say it once, and offer what still works (review 3).
struct OfflineCard: View {
    let serverUp: Bool
    var wake: () -> Void
    var here: () -> Void
    var retry: () -> Void
    private func action(_ title: String, _ icon: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: icon).font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10).frame(height: 28)
                .background(.primary.opacity(0.1), in: Capsule())
        }
        .buttonStyle(Press())
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: serverUp ? "tv.slash" : "wifi.slash").font(.system(size: 14)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(serverUp ? "ТВ не в мережі" : "Сервер недоступний").font(.system(size: 12, weight: .semibold))
                    Text(serverUp ? "Вимкнений, спить або втратив Wi-Fi." : "Немає зв'язку з tinyTV Core. Перевірте мережу.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                if serverUp {
                    action("Розбудити ТВ", "power", wake)
                    action("Дивитись тут", "macwindow", here)
                } else {
                    action("Повторити", "arrow.clockwise", retry)
                }
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.orange.opacity(0.25), lineWidth: 0.5))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// "Тут" for a file on this Mac: the window plays it straight from disk (what AVFoundation opens; the rest only on the TV).
@MainActor
enum HereFile {
    static func play(_ u: URL) {
        Task {
            let ok = (try? await AVURLAsset(url: u).load(.isPlayable)) ?? false
            guard ok else {
                return PanelToast.shared.show("Вікно Mac не відтворює «.\(u.pathExtension.lowercased())». Цей файл можна дивитись на ТВ.", seconds: 8)
            }
            Watch.shared.show(["direct": u.absoluteString, "title": Library.pretty(u.deletingPathExtension().lastPathComponent)])
        }
    }
}

// MARK: - Link bar and shortcuts

/// What the panel calls the thing on the TV: the Kino film like the phone shows it, else a bare file name made readable
/// ("Lawrence.Of.Arabia.1962.2160p….mkv" -> "Lawrence Of Arabia 1962"); page titles stay as they are.
@MainActor func shownTitle(_ raw: String) -> String {
    if !TV.shared.kinoTitle.isEmpty { return TV.shared.kinoTitle }
    let file = Library.exts.contains((raw as NSString).pathExtension.lowercased())
    return file ? Library.pretty((raw as NSString).deletingPathExtension) : raw
}

func clock(_ t: Double) -> String {
    let s = Int(max(0, t)); return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
        : String(format: "%d:%02d", s / 60, s % 60)
}

/// What the TV plays from us: title, pause, scrubber, stop.
struct NowCasting: View {
    @ObservedObject var caster = Caster.shared
    @ObservedObject var tv = TV.shared
    @State private var scrub: Double?

    /// Review 7: stop is one plain click on a 28 pt button (no hold), and it can be taken back for a few seconds.
    private func stop() {
        let u = caster.link, at = caster.displayPosition
        caster.stop()
        PanelToast.shared.show("Зупинено", actionTitle: u.isEmpty ? nil : "Повернути") { TV.shared.open(u, from: at) }
    }

    private func action(_ title: String, _ icon: String, tint: Color? = nil, help: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label { Text(title) } icon: { Image(systemName: icon).foregroundStyle(tint ?? Color.primary) }
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10).frame(height: 28)
                .background(.primary.opacity(0.1), in: Capsule())
        }
        .buttonStyle(Press()).help(help).accessibilityLabel(title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 11)).foregroundStyle(accent)
                    .symbolEffect(.pulse, isActive: caster.playing)
                // Review 32: the whole width for the name, two lines; the end is cut, never the middle ("Lawrenc…abia 1962").
                Text(shownTitle(caster.title)).font(.system(size: 12, weight: .medium)).lineLimit(2).truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                PlayPause(playing: caster.playing, size: 36) { caster.togglePause() }   // Space (review 34)
                if let ep = tv.episode {
                    Button { Remote.post("kino/step", ["dir": -1]) } label: { Image(systemName: "backward.end.fill").font(.system(size: 11)).frame(width: 28, height: 28) }
                        .buttonStyle(Press()).disabled(!ep.prev).help("Попередня серія").accessibilityLabel("Попередня серія")
                }
                Button { caster.seek(caster.displayPosition - 10) } label: { Image(systemName: "gobackward.10").font(.system(size: 13)).frame(width: 28, height: 28) }
                    .buttonStyle(Press()).help("Назад 10 с (←)").accessibilityLabel("Назад 10 с")
                VStack(spacing: 3) {
                    GlowSlider(value: Binding(get: { scrub ?? caster.displayPosition },
                                              set: { scrub = $0 }),
                               range: 0...max(1, caster.duration), track: [Color(white: 0.18), accent], thumb: accent,
                               onEnd: { if let s = scrub { caster.seek(s) }; scrub = nil })
                    HStack {
                        Text(clock(scrub ?? caster.displayPosition)); Spacer(); Text(caster.duration > 0 ? clock(caster.duration) : "наживо")
                    }
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                }
                Button { caster.seek(caster.displayPosition + 30) } label: { Image(systemName: "goforward.30").font(.system(size: 13)).frame(width: 28, height: 28) }
                    .buttonStyle(Press()).help("Вперед 30 с (→)").accessibilityLabel("Вперед 30 с")
                if let ep = tv.episode {
                    Button { Remote.post("kino/step", ["dir": 1]) } label: { Image(systemName: "forward.end.fill").font(.system(size: 11)).frame(width: 28, height: 28) }
                        .buttonStyle(Press()).disabled(!ep.next).help("Наступна серія").accessibilityLabel("Наступна серія")
                }
            }
            HStack(spacing: 8) {
                // Owner: watch the same thing here too - the Mac window (Watch.swift) has PiP and full screen; its card is WatchMini.
                action("Дивитись тут", "macwindow", help: "Дивитись тут, у вікні Mac: картинка в картинці, повний екран") { Watch.shared.here() }
                action("Стоп", "stop.fill", tint: .red, help: "Зупинити на ТВ. Кілька секунд це можна повернути.") { stop() }
                Spacer(minLength: 0)
                if let rate = caster.torrent["rate"], rate > 0 {
                    let t = caster.torrent, mb = { (v: Double) in String(format: "%.1f", v / 1_048_576).replacingOccurrences(of: ".", with: ",") }
                    let down = t["down"] ?? 0, ahead = Int(t["ahead"] ?? 0), wait = Int(t["wait"] ?? 0)
                    // Owner: "40% (зеленим) Ahead просто" - share of the rest of the film already loaded, coloured by state; details in the tooltip.
                    let span = { (s: Int) in s < 60 ? "\(s) с" : s < 3600 ? "\(s / 60) хв" : "\(s / 3600) год \(s % 3600 / 60) хв" }
                    let rest = max(1, caster.duration - caster.displayPosition)
                    let label = caster.duration > 0 ? "\(min(100, Int(Double(ahead) / rest * 100)))% Ahead" : "\(span(ahead)) Ahead"
                    let level: Color = t["hold"] == 1 || ahead < 10 ? .red : wait > 0 ? .orange : .green
                    let head = t["hold"] == 1 ? "Набираю буфер до \(Int(t["target"] ?? 20)) с" : down >= rate ? "Завантаження встигає" : wait > 0 ? "Скоро пауза ~\(span(wait)), далі без зупинок" : "Буфера досить"
                    Text(label)
                        .font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(level)
                        .help("\(head) · \(span(ahead)) наперед · ↓ \(mb(down)) з \(mb(rate)) МБ/с · пірів: \(Int(t["peers"] ?? 0))")
                }
            }
            if caster.tracks.count > 1 {
                Menu {
                    ForEach(caster.tracks, id: \.i) { t in
                        Button { caster.setTrack(t.i) } label: {
                            if t.i == caster.track { Label(t.label, systemImage: "checkmark") } else { Text(t.label) }
                        }
                    }
                } label: {
                    Label(caster.tracks.first { $0.i == caster.track }?.label ?? "Звук", systemImage: "waveform")
                        .font(.system(size: 11)).lineLimit(1)
                }
                .menuStyle(.borderlessButton).fixedSize().frame(minHeight: 28)
                .help("Звукова доріжка")
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
    @State private var clip = ""   // a link on the clipboard: only offered under the field, never put in it (review 33)
    @State private var sent: Dest?
    private var saveURL: String { !link.isEmpty ? link : !caster.link.isEmpty ? caster.link : LinkBar.lastSent }
    /// Return and a tap on a chip use the TV when it is there, else this Mac's window (review 3).
    private var primary: Dest { tv.connected ? .tv : .here }
    /// "+" saves the field, or what plays now, or (once chips exist) the last link sent. With nothing to save it stays away
    /// instead of standing alone in a row (review 35).
    private var canSave: Bool { !saveURL.isEmpty && (!link.isEmpty || !caster.title.isEmpty || !tv.shortcuts.isEmpty) }

    /// Owner: "+" saves what plays now with its moment, so the chip resumes from where it stopped.
    func save() {
        let u = saveURL; guard !u.isEmpty else { return }
        let now = link.isEmpty && !caster.title.isEmpty
        let at = now && caster.displayPosition > 5 ? caster.displayPosition : nil
        let host = URL(string: u)?.host?.replacingOccurrences(of: "www.", with: "") ?? "Посилання"
        let n = String((now ? caster.title : host).prefix(28))
        if let i = tv.shortcuts.firstIndex(where: { $0.url == u }) {
            tv.shortcuts[i].at = at   // same id: didSet sends nothing, so tell the core here
            if core { Remote.post("shortcut", ["name": n, "url": u, "at": at ?? 0]) }
        } else { tv.shortcuts.append(Shortcut(name: n, url: u, at: at)) }
        haptic()
    }
    private var core: Bool { tv.core != nil }
    static func clock(_ s: Double) -> String {
        let t = Int(s); return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    /// A bare domain gets https:// (like TV.open); magnets, paths and full URLs pass as they are.
    static func normalized(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty || s.contains(":") || s.hasPrefix("/") ? s : "https://" + s
    }

    /// One door for the field, the chips and the paste offer; where it plays is the caller's choice (review 1).
    /// "Тут" takes a link (Watch.here) or a file path (straight from disk); a magnet only plays on the TV or in Kino.
    func go(_ raw: String, _ to: Dest, from at: Double? = nil) {
        let u = LinkBar.normalized(raw); guard !u.isEmpty else { return }
        switch to {
        case .tv:
            LinkBar.lastSent = u
            if let at { tv.open(u, from: at) } else { tv.open(u) }
        case .here:
            if u.lowercased().hasPrefix("magnet:") {
                return PanelToast.shared.show("Магнет не грає у вікні Mac. Оберіть «ТВ» або відкрийте його в «Кіно».", seconds: 8)
            }
            if u.hasPrefix("http"), !tv.serverUp {   // the window asks the server for the stream
                return PanelToast.shared.show("Сервер недоступний: посилання у вікні Mac поки не відкриється.", seconds: 6)
            }
            LinkBar.lastSent = u
            if u.hasPrefix("http") { Watch.shared.here(path: u) }
            else { HereFile.play(URL(fileURLWithPath: u.hasPrefix("file://") ? (URL(string: u)?.path ?? u) : u)) }
        }
        link = ""; clip = ""
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { sent = to }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation(.easeOut(duration: 0.3)) { sent = nil } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "link").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Посилання на відео", text: $link)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .onSubmit { go(link, primary) }
                // Review 1: the target is written on the buttons; Return takes the filled one.
                DestButton(dest: .tv, primary: primary == .tv, enabled: tv.connected && !link.isEmpty, done: sent == .tv,
                           help: tv.connected ? nil : "ТВ не в мережі") { go(link, .tv) }
                DestButton(dest: .here, primary: primary == .here, enabled: tv.serverUp && !link.isEmpty, done: sent == .here,
                           help: tv.serverUp ? nil : "Сервер недоступний") { go(link, .here) }
            }
            .padding(.leading, 10).padding(.trailing, 4).padding(.vertical, 2)
            .background(.primary.opacity(0.07), in: Capsule())

            // Review 33: the clipboard is offered, one click away; it never fills the field (or goes to the TV) by itself.
            if link.isEmpty, !clip.isEmpty {
                Button { link = clip; clip = "" } label: {
                    Label { Text("Вставити: \(LinkBar.shortLink(clip))").lineLimit(1).truncationMode(.middle) } icon: { Image(systemName: "doc.on.clipboard") }
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).frame(height: 28)
                        .background(.primary.opacity(0.07), in: Capsule())
                }
                .buttonStyle(Press()).help("Вставити посилання з буфера обміну в поле")
                .transition(.opacity)
            }

            // While it works the status lives in the CastWait card; only a failure stays here.
            if !caster.status.isEmpty && caster.failed {
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
                    // A moment on the chip = a play mark; the rest carry no icon (review 35).
                    Chip(title: s.at.map { "\(s.name) · \(LinkBar.clock($0))" } ?? s.name, icon: s.at == nil ? nil : "play.fill") {
                        go(s.url, primary, from: s.at)
                    }
                        .contextMenu {
                            Button("Дивитись на ТВ") { go(s.url, .tv, from: s.at) }.disabled(!tv.connected)
                            Button("Дивитись тут") { go(s.url, .here) }.disabled(!tv.serverUp)
                            Divider()
                            Button("Скопіювати посилання") {
                                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s.url, forType: .string)
                            }
                            Button("Видалити «\(s.name)»", role: .destructive) {
                                withAnimation { tv.shortcuts.removeAll { $0.id == s.id } }
                            }
                        }
                        .help(s.url)
                        .overlay(alignment: .topTrailing) { RemoveBadge { withAnimation { tv.shortcuts.removeAll { $0.id == s.id } } } }
                        .transition(.scale.combined(with: .opacity))
                }
                // Owner: "+" saves the link in the field, else what plays now with its moment.
                if canSave {
                    Button { save() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                            // Alone in its row a bare "+" looked like a mistake (review 35): with no chips it says what it does.
                            if tv.shortcuts.isEmpty { Text("Зберегти посилання").font(.system(size: 11)) }
                        }
                        .padding(.horizontal, tv.shortcuts.isEmpty ? 10 : 0).frame(minWidth: 28, minHeight: 28)
                        .background(.primary.opacity(0.07), in: Capsule())
                    }
                    .buttonStyle(Press())
                    .help(link.isEmpty ? "Зберегти посилання, що грає, з моментом" : "Зберегти посилання з поля")
                    .accessibilityLabel("Зберегти посилання")
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: tv.shortcuts)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: caster.status.isEmpty)
        .animation(.easeOut(duration: 0.2), value: clip.isEmpty)
        .onAppear { clip = LinkBar.offer() }
    }
    static var lastSent: String {   // kept across restarts: "+" can save it later
        get { UserDefaults.standard.string(forKey: "lastSent") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "lastSent") }
    }
    /// What the clipboard offers: a link or a magnet that was not just sent. Read once, when the panel opens.
    static func offer() -> String {
        guard let c = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              c != lastSent, c.count < 4000, c.hasPrefix("http") || c.lowercased().hasPrefix("magnet:") else { return "" }
        return c
    }
    /// "https://www.youtube.com/watch?v=abc" -> "youtube.com/watch?v=abc"
    static func shortLink(_ u: String) -> String {
        var s = u
        for p in ["https://", "http://", "www."] where s.lowercased().hasPrefix(p) { s = String(s.dropFirst(p.count)) }
        return s
    }
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
                    Text(mouse.cursorMode ? "Справжній курсор на сторінці TV Cast" : "Стрілки на ТВ")
                        .font(.system(size: 11, weight: .medium))
                        .contentTransition(.opacity)
                    Text("клік - OK · Delete - Назад · правий клік або Esc - вийти")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "cursorarrow.motionlines").font(.system(size: 20)).foregroundStyle(.secondary)
                    Text("Клікніть, щоб керувати ТВ цим трекпадом").font(.system(size: 11)).foregroundStyle(.secondary)
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
                Text("два пальці: ↕ гучність · ↔ перемотка").font(.system(size: 11)).foregroundStyle(.secondary).padding(.bottom, 8)
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
        .accessibilityLabel("Трекпад для ТВ")
    }
}

// MARK: - Video settings

/// Sound to the TV: presets; the five bands only for "Custom" (owner: equalizer hidden smartly).
struct SoundSection: View {
    @ObservedObject var caster = Caster.shared
    @State private var open = false
    private let presets = [("flat", "Рівно"), ("soft", "Менше високих"), ("dialog", "Діалоги"), ("night", "Нічний"), ("bass", "Більше басу"), ("tv", "Динаміки ТВ"), ("custom", "Свій")]
    private let freqs = ["60", "250", "1k", "4k", "12k"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { open.toggle() } } label: {
                HStack {
                    Text("Звук ТВ").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Text(presets.first { $0.0 == caster.sound.preset }?.1 ?? "").font(.system(size: 11)).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).rotationEffect(.degrees(open ? 90 : 0))
                }.frame(minHeight: 28).contentShape(Rectangle())
            }.buttonStyle(Press())
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
                    Text("Відео на ТВ").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Text(summary).font(.system(size: 11)).foregroundStyle(.secondary).contentTransition(.opacity)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary).rotationEffect(.degrees(open ? 90 : 0))
                }
                .frame(minHeight: 28).contentShape(Rectangle())
            }
            .buttonStyle(Press())
            if open {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("", selection: $caster.video.mode) {
                        Text("Авто").tag("auto"); Text("Оригінал").tag("original"); Text("Перекодувати").tag("encode")
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .help("Авто перекодовує лише файли, надто важкі для Wi-Fi ТВ, або більші за розмір нижче")
                    Picker("", selection: $caster.video.height) {
                        Text("4K").tag(2160); Text("1440p").tag(1440); Text("1080p").tag(1080); Text("720p").tag(720)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    Picker("", selection: $caster.video.hdr) {
                        Text("HDR · 10-біт").tag(true); Text("SDR · 8-біт").tag(false)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    Row(title: "Бітрейт", value: "\(Int(caster.video.mbps)) Мбіт/с") {
                        GlowSlider(value: $caster.video.mbps, range: 4...40, track: [Color(white: 0.18), accent], thumb: accent)
                    }
                    Text("Wi-Fi ТВ ≈ 48 Мбіт/с. Зміни діють одразу.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
            }
        }
        .clipped()
    }

    var summary: String {
        let v = caster.video
        let h = v.height == 2160 ? "4K" : "\(v.height)p"
        return v.mode == "original" ? "Оригінал" : "\(v.mode == "auto" ? "Авто · " : "")\(h) · \(v.hdr ? "HDR" : "SDR") · \(Int(v.mbps)) Мбіт/с"
    }
}

// MARK: - Screen to TV

struct ScreenRow: View {
    @ObservedObject var caster = Caster.shared
    @State private var windows: [(id: UInt32, title: String)] = []
    /// The preset names come from Screen.swift in English; the panel says them in Ukrainian (review 10).
    static let presetNames = ["fast": "Швидко", "balanced": "Збалансовано", "quality": "Якість"]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Показ екрана на ТВ").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                if !caster.screen.isEmpty {
                    Text(caster.screenLatency > 0 ? String(format: "Йде показ · затримка %.1f с", caster.screenLatency).replacingOccurrences(of: ".", with: ",") : "Йде показ")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(accent)
                        .help("Повна затримка, виміряна за фото годинника Mac поруч із ТВ")
                }
            }
            FlowChips {
                Chip(title: "Цей Mac", icon: "laptopcomputer", selected: caster.screen == "mac" && caster.screenWindow == nil) {
                    caster.startScreen("mac")
                }
                Menu {
                    if windows.isEmpty { Text("Немає вікон (дозвольте запис екрана)") }
                    ForEach(windows, id: \.id) { w in Button(w.title) { caster.startScreen("mac", window: w.id) } }
                } label: {
                    Label(caster.screen == "mac" && caster.screenWindow != nil ? "Вікно ✓" : "Вікно", systemImage: "macwindow")
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton).controlSize(.small).font(.system(size: 11)).fixedSize()
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(caster.screen == "mac" && caster.screenWindow != nil ? accent.opacity(0.28) : .primary.opacity(0.07), in: Capsule())
                .help("Показати на ТВ одне вікно (вкладку браузера, відео)")
                Chip(title: "Другий екран", icon: "rectangle.on.rectangle", selected: caster.screen == "mac-extend") { caster.startScreen("mac-extend") }
                    .help("ТВ стає другим екраном цього Mac")
                Chip(title: "Звук", icon: "speaker.wave.2", selected: caster.screen == "mac-audio") { caster.startScreen("mac-audio") }
                    .help("Лише звук цього Mac на ТВ")
                Chip(title: "Core", icon: "desktopcomputer", selected: caster.screen == "core") { caster.startScreen("core") }
                    .help("Показати на ТВ екран tinyTV Core")
                if !caster.screen.isEmpty {
                    Chip(title: "Годинник затримки", icon: "stopwatch") { DelayClock.show() }
                        .help("Великий годинник на цьому Mac: сфотографуйте його поруч із ТВ, щоб виміряти затримку")
                }
            }
            Picker("", selection: $caster.screenPreset) {
                ForEach(ScreenPreset.all, id: \.id) { p in Text(ScreenRow.presetNames[p.id] ?? p.label).tag(p.id) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .help("Швидко: 720p, 4 Мбіт/с, найкоротший інтервал ключових кадрів. Збалансовано: 1080p, 12 Мбіт/с. Якість: 4K HEVC, 25 Мбіт/с")
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
        w.title = "tinyTV · годинник затримки"; w.isReleasedWhenClosed = false; w.level = .floating
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

/// "Екран" meant three things (the phone's mirror, Kino's paired screens, this tab's drawer), so the Mac tab that shows a
/// screen on the TV is "Показ" (review 8). If the owner keeps "Екран", this one word is the only change.
enum PanelTab: String, CaseIterable { case remote = "Пульт", kino = "Кіно", screen = "Показ" }

struct TabBar: View {
    @Binding var tab: PanelTab
    @Namespace private var ns
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(PanelTab.allCases.enumerated()), id: \.element) { i, t in
                // Review 34: a real button (focus, VoiceOver, "selected") with its own ⌘1 / ⌘2 / ⌘3.
                Button { withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) { tab = t } } label: {
                    Text(t.rawValue)
                        .font(.system(size: 12, weight: tab == t ? .semibold : .regular))
                        .foregroundStyle(tab == t ? .primary : .secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                        .background {
                            if tab == t {
                                Capsule().fill(.white.opacity(0.16))
                                    .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
                                    .matchedGeometryEffect(id: "tab", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
                .help("\(t.rawValue)  ⌘\(i + 1)")
                .accessibilityAddTraits(tab == t ? .isSelected : [])
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
    @State private var dropSide: Dest = .tv
    @State private var typing = ""
    @State private var allApps = false
    @State private var keys: Any?
    @AppStorage("panelMoreOpen") private var moreOpen = false

    /// One width for every tab: the window no longer jumps 320 -> 440 under the pointer (review 30).
    static let width: CGFloat = 440
    /// Kino keeps 600 pt, less on a small display, so the panel never runs off the screen.
    static var kinoHeight: CGFloat { min(600, (NSScreen.main?.visibleFrame.height ?? 800) - 140) }

    var header: some View {
        HStack(spacing: 8) {
            // Owner: the panel is the tinyTV server (core host); under it, the TV that is connected now. Two words for the TV (review 24).
            let dot: Color = !tv.serverUp ? .gray : tv.connected ? .green : .orange
            Circle().fill(dot).frame(width: 8, height: 8)
                .shadow(color: dot.opacity(tv.serverUp ? 0.7 : 0), radius: 4)
            VStack(alignment: .leading, spacing: 0) {
                Text("tinyTV server").font(.system(size: 13, weight: .semibold))
                Text(!tv.serverUp ? "Сервер недоступний" : tv.connected ? "ТВ на зв'язку" + (tv.nowPlaying.isEmpty ? "" : " · \(shownTitle(tv.nowPlaying))")
                     : "ТВ не в мережі")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    .contentTransition(.opacity)
            }
            Spacer()
            // Owner: power is a plain press (no hold).
            Button { power() } label: {
                Image(systemName: "power").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tv.connected ? Color.red : accent)
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.1), in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
            }
            .buttonStyle(Press())
            .help(tv.connected ? "Вимкнути ТВ" : "Розбудити ТВ")
            .accessibilityLabel(tv.connected ? "Вимкнути ТВ" : "Розбудити ТВ")
        }
    }

    /// The TV takes seconds to answer power, so the press answers in words at once (consistency table, "Живлення").
    private func power() {
        PanelToast.shared.show(tv.connected ? "Вимикаю ТВ…" : "Вмикаю ТВ…", seconds: 4)
        tv.power()
    }

    /// A file from this Mac, wherever it goes: to the TV (it goes up to core host first) or to this Mac's window.
    private func play(_ u: URL, on d: Dest) {
        switch d {
        case .tv: Caster.shared.tv = tv; Caster.shared.file(u.path)
        case .here: HereFile.play(u)
        }
    }

    /// ← / → seek while something plays from here - but never while a text field has the keys: a plain shortcut would
    /// steal the caret (measured). Space is a normal shortcut on the play button, which text fields keep for themselves.
    private func arrowSeek(_ e: NSEvent) -> NSEvent? {
        guard tab == .remote, tv.connected, !caster.title.isEmpty, !mouse.active, e.keyCode == 123 || e.keyCode == 124,
              e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              !(NSApp.keyWindow?.firstResponder is NSText) else { return e }
        caster.seek(max(0, caster.displayPosition + (e.keyCode == 123 ? -10 : 30)))
        return nil
    }

    /// Owner: while a cast starts, the panel waits visibly - everything but the trackpad and volume is dimmed.
    var busy: Bool { !caster.status.isEmpty && !caster.failed }

    var remote: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Review 3: the TV is often away. The panel says so once and still offers what works without it.
            if !tv.serverUp || (!tv.connected && tv.offline) {
                OfflineCard(serverUp: tv.serverUp, wake: { power() },
                            here: { withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) { tab = .kino } },
                            retry: { tv.refresh() })
            }
            // What needs no TV stays alive when it is away: the Mac window's card and the link field ("Тут").
            VStack(alignment: .leading, spacing: 12) {
                WatchMini()   // the Mac window ("Грати тут") stays findable and controllable from here
                if !caster.title.isEmpty {
                    NowCasting().transition(.move(edge: .top).combined(with: .opacity)).disabled(!tv.connected)
                }
                LinkBar()
            }
            .waiting(busy)
            .overlay { if busy { CastWait().transition(.scale(scale: 0.9).combined(with: .opacity)) } }
            // The TV's own controls: dimmed and inert while it is away.
            VStack(alignment: .leading, spacing: 12) {
                // Owner: the main controls are always here; with nothing cast they drive the TV's own player.
                if caster.title.isEmpty { TransportBar().waiting(busy) }
                MousePad()
                HStack(spacing: 6) {
                    KeyButton(icon: "arrow.uturn.backward", key: "KEY_RETURNS", label: "Назад")
                    KeyButton(icon: "house", key: "KEY_HOME", label: "Додому")
                    KeyButton(icon: "smallcircle.filled.circle", key: "KEY_OK", label: "OK")
                    KeyButton(icon: "line.3.horizontal", key: "KEY_MENU", label: "Меню")
                    KeyButton(icon: "stop.fill", key: "KEY_STOP", label: "Стоп", help: "Стоп на ТВ")
                    KeyButton(icon: "cursorarrow.rays", key: "KEY_LEFTMOUSEKEYS", label: "Курсор", help: "Курсор ТВ: увімкнути або вимкнути")
                }
                .waiting(busy)
            }
            .disabled(!tv.connected).allowsHitTesting(tv.connected)
            .opacity(tv.connected ? 1 : 0.55)
            .saturation(tv.connected ? 1 : 0)
        }
    }

    var screen: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScreenRow()
            // A movie on this Mac: to the TV (it goes up to core host, ~/Movies/tinyTV, first) or to this Mac's window;
            // dropping a file on the panel does the same.
            FileRow(tvOnline: tv.connected) { play($0, on: $1) }
            // Review 30: what is not "show a screen" waits one click away; the panel remembers whether it was open.
            // "Refresh" and "Quit" are gone: the menu on the icon has both.
            Divider().opacity(0.5)
            Button { withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { moreOpen.toggle() } } label: {
                HStack(spacing: 6) {
                    Text("Ще").font(.system(size: 12, weight: .medium))
                    Text("текст, додатки, входи, відео, звук").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(moreOpen ? 90 : 0))
                }
                .frame(minHeight: 28).contentShape(Rectangle())
            }
            .buttonStyle(Press()).accessibilityLabel(moreOpen ? "Ще: згорнути" : "Ще: розгорнути")
            if moreOpen {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 6) {
                        Image(systemName: "keyboard").font(.system(size: 11)).foregroundStyle(.secondary)
                        TextField("Ввести текст на ТВ", text: $typing)
                            .textFieldStyle(.plain).font(.system(size: 12))
                            .onSubmit { tv.type(typing); typing = "" }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(.white.opacity(0.07), in: Capsule())
                    if !tv.apps.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Додатки").font(.system(size: 11)).foregroundStyle(.secondary)
                            FlowChips {
                                ForEach(allApps ? tv.apps : Array(tv.apps.prefix(6))) { a in
                                    Chip(title: a.name) { tv.launch(a) }.transition(.scale.combined(with: .opacity))
                                }
                                if tv.apps.count > 6 {
                                    Chip(title: allApps ? "Менше" : "+\(tv.apps.count - 6)") {
                                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { allApps.toggle() }
                                    }
                                }
                            }
                        }
                    }
                    if !tv.sources.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Входи").font(.system(size: 11)).foregroundStyle(.secondary)
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
                            Text("Кіносвітло").font(.system(size: 12))
                            Text("Приглушує світло в кімнаті, поки йде фільм; на паузі вмикає").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch).controlSize(.mini).tint(accent)
                }
                .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
            }
        }
        .clipped()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header.waiting(busy && tab != .kino)
            TabBar(tab: $tab).waiting(busy && tab != .kino)
            ToastBar()
            Group {
                switch tab {
                case .remote: remote
                case .kino: KinoWindow().frame(height: Panel.kinoHeight).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        // Owner: Kino on half the Mac screen - 4 covers a row, more rows below.
                        Button { KinoBig.open() } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 10, weight: .bold))
                                .frame(width: 28, height: 28).background(.black.opacity(0.5), in: Circle())
                        }
                        .buttonStyle(Press()).padding(8).help("Відкрити «Кіно» на пів екрана").accessibilityLabel("Відкрити «Кіно» у великому вікні")
                    }
                case .screen: screen.waiting(busy).overlay(alignment: .top) { if busy { CastWait().padding(.top, 40) } }
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            // Owner: volume on every tab; Kino has its own in the player, so none here.
            if tab != .kino {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Button { tv.key("KEY_MUTE") } label: {
                            Image(systemName: tv.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.system(size: 11)).frame(width: 28, height: 28)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(Press()).help("Без звуку").accessibilityLabel("Без звуку")
                        GlowSlider(value: $tv.volume, range: 0...100, track: [.white.opacity(0.12), accent], thumb: .white)
                        Text("\(Int(tv.volume))").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 22, alignment: .trailing).contentTransition(.numericText())
                    }
                    // Review 34: ⌘↑ / ⌘↓ = volume, two steps; invisible buttons carry the shortcuts (they follow .disabled below).
                    .background {
                        Group {
                            Button("Гучніше") { tv.volume = min(100, tv.volume + 2) }.keyboardShortcut(.upArrow, modifiers: .command)
                            Button("Тихіше") { tv.volume = max(0, tv.volume - 2) }.keyboardShortcut(.downArrow, modifiers: .command)
                        }.hidden()
                    }
                    .disabled(!tv.connected)
                    // The concept shows the keys under the volume; they apply while something plays from here.
                    if tab == .remote, !caster.title.isEmpty {
                        Text("Пробіл - пауза · ← → - перемотка · ⌘↑ ⌘↓ - гучність").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: Panel.width)
        .background(GlassBackground().ignoresSafeArea())
        .background(alignment: .top) {
            RadialGradient(colors: [accent.opacity(tv.connected ? 0.22 : 0.06), .clear],
                           center: .top, startRadius: 0, endRadius: 220)
                .allowsHitTesting(false)
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.85), value: tab)
        .animation(.easeInOut(duration: 0.35), value: tv.connected)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: caster.title.isEmpty)
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: busy)
        // Review 1: a dropped file chooses its target - the left half is the TV, the right half this Mac's window.
        .overlay { if dropping { DropZones(side: dropSide, tvOnline: tv.connected) } }
        .onDrop(of: [.fileURL], delegate: PanelDrop(dropping: $dropping, side: $dropSide, tvOnline: tv.connected) { play($0, on: $1) })
        .onAppear {
            mouse.tv = tv; Caster.shared.tv = tv; tv.refresh()
            if keys == nil { keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { arrowSeek($0) } }
        }
        .onDisappear { mouse.stop(); if let keys { NSEvent.removeMonitor(keys) }; keys = nil }
    }
}

/// The drop target of the whole panel. The two halves are only drawn (DropZones); the pointer's place decides the target.
struct PanelDrop: DropDelegate {
    @Binding var dropping: Bool
    @Binding var side: Dest
    var tvOnline: Bool
    var play: (URL, Dest) -> Void

    private func pick(_ info: DropInfo) { side = tvOnline && info.location.x < Panel.width / 2 ? .tv : .here }
    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }
    func dropEntered(info: DropInfo) { pick(info); withAnimation(.easeOut(duration: 0.15)) { dropping = true } }
    func dropUpdated(info: DropInfo) -> DropProposal? { pick(info); return DropProposal(operation: .copy) }
    func dropExited(info: DropInfo) { withAnimation(.easeOut(duration: 0.15)) { dropping = false } }
    func performDrop(info: DropInfo) -> Bool {
        let target = side
        withAnimation(.easeOut(duration: 0.15)) { dropping = false }
        guard let p = info.itemProviders(for: [.fileURL]).first else { return false }
        _ = p.loadObject(ofClass: URL.self) { u, _ in
            if let u { Task { @MainActor in play(u, target) } }
        }
        return true
    }
}

struct DropZones: View {
    let side: Dest
    let tvOnline: Bool
    private func zone(_ d: Dest, _ icon: String, _ title: String, _ sub: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 22, weight: .medium))
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(sub).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))   // readable over any tab
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(side == d ? accent.opacity(0.24) : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .opacity(d == .tv && !tvOnline ? 0.45 : 1)
        .padding(6)
    }
    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(accent, style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
            .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                HStack(spacing: 0) {
                    zone(.tv, "tv", "Hisense TV", tvOnline ? "дивитись на ТВ" : "ТВ не в мережі")
                    zone(.here, "macwindow", "Тут", "у вікні цього Mac")
                }
            }
            .padding(6).allowsHitTesting(false).transition(.opacity)
    }
}

/// A movie from this Mac: to the TV (it goes up to core host first) or to this Mac's window. Dropping a file does the same.
struct FileRow: View {
    var tvOnline: Bool
    var play: (URL, Dest) -> Void
    private func pick(_ d: Dest) {
        let p = NSOpenPanel(); p.allowsMultipleSelection = false; p.canChooseDirectories = false
        p.allowedContentTypes = [.movie, .audiovisualContent, .audio]
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let u = p.url { play(u, d) }
    }
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "film").font(.system(size: 11)).foregroundStyle(.secondary)
            Text("Файл із цього Mac…").font(.system(size: 12))
            Spacer(minLength: 0)
            DestButton(dest: .tv, primary: tvOnline, enabled: tvOnline, help: tvOnline ? "Файл на Hisense TV (піде на tinyTV Core, далі на ТВ)" : "ТВ не в мережі") { pick(.tv) }
            DestButton(dest: .here, primary: !tvOnline, help: "Файл у вікні цього Mac") { pick(.here) }
        }
        .padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 2)
        .background(.white.opacity(0.07), in: Capsule())
    }
}

@main
struct TinyTVApp: App {
    // One shared instance each: two MQTT clients with the same client_id kick each other off the TV broker.
    @ObservedObject private var tv = TV.shared
    @ObservedObject private var mouse = MouseBridge.shared

    init() {
        DispatchQueue.main.async { StatusMenu.install() }
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
        // Debug: open the watch window on a core host file, or Kino on half the screen, without the menu bar panel.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--watch"), i + 1 < args.count {
            let p = args[i + 1]; DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Watch.shared.here(path: p) }
        }
        if args.contains("--kino-big") { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { KinoBig.open() } }
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
        cfg.userContentController.add(WatchBridge(), name: "watch")   // 📱 here opens the native window (Watch.swift)
        let w = WKWebView(frame: .zero, configuration: cfg)
        let base = TV.config["core"] ?? "http://127.0.0.1:8891"
        w.load(URLRequest(url: URL(string: base + "/kino?embed=1")!))
        w.setValue(false, forKey: "drawsBackground")
        return w
    }
    func updateNSView(_ v: WKWebView, context: Context) {}
}

@MainActor
enum KinoBig {
    private static var window: NSWindow?
    static func open() {
        if window == nil, let sc = NSScreen.main?.visibleFrame {
            let w = NSWindow(contentRect: NSRect(x: sc.minX, y: sc.minY, width: sc.width / 2, height: sc.height),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false; w.titlebarAppearsTransparent = true; w.title = "Кіно · tinyTV"
            w.backgroundColor = NSColor(red: 0.055, green: 0.059, blue: 0.075, alpha: 1)
            w.contentView = NSHostingView(rootView: KinoWindow().padding(.top, 28))
            w.setFrameAutosaveName("tinyTV.kino")
            window = w
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}

final class WatchBridge: NSObject, WKScriptMessageHandler {
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let r = m.body as? [String: Any] else { return }
        MainActor.assumeIsolated { Watch.shared.show(r) }
    }
}


extension View {
    /// Dimmed, blurred and inert while a cast starts.
    func waiting(_ on: Bool) -> some View {
        blur(radius: on ? 5 : 0).opacity(on ? 0.32 : 1).saturation(on ? 0.4 : 1).allowsHitTesting(!on)
    }
}

/// The "sending to TV" moment: a TV with soft rings going out, the step and its progress, and a way out.
struct CastWait: View {
    @ObservedObject var caster = Caster.shared
    var body: some View {
        VStack(spacing: 10) {
            TimelineView(.animation) { t in
                let time = t.date.timeIntervalSinceReferenceDate
                ZStack {
                    ForEach(0..<3) { i in
                        let f = (time / 2.4 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                        Circle().strokeBorder(accent.opacity(0.55 * (1 - f)), lineWidth: 1.5)
                            .frame(width: 30 + 46 * f, height: 30 + 46 * f)
                    }
                    Image(systemName: "tv").font(.system(size: 17, weight: .medium)).foregroundStyle(.white)
                        .frame(width: 34, height: 34).background(accent, in: Circle())
                        .shadow(color: accent.opacity(0.7), radius: 8 + 3 * sin(time * 2.6))
                }
                .frame(width: 78, height: 78)
            }
            Text(caster.status).font(.system(size: 12, weight: .medium)).multilineTextAlignment(.center)
                .contentTransition(.opacity).animation(.easeOut, value: caster.status)
            GeometryReader { g in
                Capsule().fill(.white.opacity(0.1)).overlay(alignment: .leading) {
                    if let p = caster.progress {
                        Capsule().fill(accent).frame(width: max(6, g.size.width * p)).shadow(color: accent.opacity(0.7), radius: 4)
                    } else {
                        TimelineView(.animation) { t in   // no number yet: a slow sweep
                            let x = (t.date.timeIntervalSinceReferenceDate / 1.6).truncatingRemainder(dividingBy: 1)
                            Capsule().fill(LinearGradient(colors: [.clear, accent, .clear], startPoint: .leading, endPoint: .trailing))
                                .frame(width: g.size.width * 0.35).offset(x: (g.size.width * 1.35) * x - g.size.width * 0.35)
                        }
                    }
                }.clipShape(Capsule())
            }
            .frame(width: 150, height: 4)
            .animation(.easeOut(duration: 0.3), value: caster.progress)
            // Review 12: the way out of a blocked panel is a real target (it was 11 pt text).
            Button { caster.stop() } label: {
                Text("Скасувати").font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14).frame(height: 28).background(.white.opacity(0.1), in: Capsule())
            }
            .buttonStyle(Press())
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }
}


/// Play / pause: paused = an accent circle with "play", playing = a soft square with "pause". A tap squeezes it,
/// a ring goes out, the shape morphs and the symbol flips.
struct PlayPause: View {
    var playing: Bool
    var size: CGFloat = 44
    var action: () -> Void
    @State private var ring = false
    @State private var press = false
    var body: some View {
        Button {
            action()
            ring = false
            withAnimation(.easeOut(duration: 0.55)) { ring = true }
            withAnimation(.spring(response: 0.18, dampingFraction: 0.5)) { press = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { press = false } }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: playing ? size * 0.28 : size / 2, style: .continuous)
                    .fill(playing ? AnyShapeStyle(Color.white.opacity(0.16)) : AnyShapeStyle(accent))
                    .shadow(color: accent.opacity(playing ? 0 : 0.6), radius: playing ? 0 : 10)
                RoundedRectangle(cornerRadius: playing ? size * 0.28 : size / 2, style: .continuous)
                    .strokeBorder(accent.opacity(ring ? 0 : 0.8), lineWidth: 2)
                    .scaleEffect(ring ? 1.6 : 1)
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white)
                    .offset(x: playing ? 0 : size * 0.03)
                    .contentTransition(.symbolEffect(.replace.downUp))
            }
            .frame(width: size, height: size)
            .scaleEffect(press ? 0.86 : 1)
            .animation(.spring(response: 0.4, dampingFraction: 0.62), value: playing)
        }
        .buttonStyle(Press())
        .keyboardShortcut(.space, modifiers: [])   // review 34: Space = play / pause (a text field keeps its own spaces)
        .help(playing ? "Пауза (пробіл)" : "Відтворити (пробіл)")
        .accessibilityLabel(playing ? "Пауза" : "Відтворити")
    }
}

/// Nothing cast from here: rewind, play / pause, fast forward and stop go to the TV's own player (YouTube, apps).
struct TransportBar: View {
    @EnvironmentObject var tv: TV
    @State private var playing = true
    var body: some View {
        HStack(spacing: 14) {
            Spacer()
            side("backward.fill", "KEY_BACKS", "Перемотка назад")
            PlayPause(playing: playing, size: 46) { tv.key(playing ? "KEY_PAUSE" : "KEY_PLAY"); playing.toggle() }
            side("forward.fill", "KEY_FORWARDS", "Перемотка вперед")
            Spacer()
        }
        .padding(.vertical, 6)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
    }
    private func side(_ icon: String, _ key: String, _ label: String) -> some View {
        Button { tv.key(key) } label: {
            Image(systemName: icon).font(.system(size: 14)).frame(width: 40, height: 34)
                .background(.white.opacity(0.08), in: Capsule())
        }
        .buttonStyle(Press()).help(label).accessibilityLabel(label)
    }
}


/// Trackpad tick (Force Touch trackpads; silent elsewhere).
func haptic(_ p: NSHapticFeedbackManager.FeedbackPattern = .alignment) {
    NSHapticFeedbackManager.defaultPerformer.perform(p, performanceTime: .now)
}

/// Owner: every button answers the press - it squeezes, brightens and ticks; it springs back on release.
struct Press: ButtonStyle {
    func makeBody(configuration c: Configuration) -> some View {
        c.label
            .contentShape(Rectangle())
            .scaleEffect(c.isPressed ? 0.92 : 1)
            .brightness(c.isPressed ? 0.08 : 0)
            .animation(c.isPressed ? .easeOut(duration: 0.08) : .spring(response: 0.32, dampingFraction: 0.5), value: c.isPressed)
            .onChange(of: c.isPressed) { _, down in if down { haptic() } }
    }
}

/// Owner: right click on the menu bar icon gives the app menu (settings, restart, quit). MenuBarExtra has none of its own.
@MainActor
enum StatusMenu {
    private static var monitor: Any?
    private final class Act: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire() { run() }
    }

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { e in
            guard let w = e.window, String(describing: type(of: w)).contains("StatusBar"), let v = w.contentView else { return e }
            NSMenu.popUpContextMenu(menu(w), with: e, for: v)
            return nil
        }
    }

    private static var lan: [String: String] = [:]
    /// GET core /api/lan for the next menu (the first menu shows tinytv.local, which is right unless port 80 was taken).
    private static func refreshLAN() {
        guard let core = TV.config["core"].flatMap({ URL(string: $0) }) else { return }
        URLSession.shared.dataTask(with: core.appendingPathComponent("api/lan")) { d, _, _ in
            guard let o = d.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: String] }) else { return }
            Task { @MainActor in lan = o }
        }.resume()
    }
    private static func copy(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }
    private static func qrImage(_ s: String) -> NSImage? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(s.utf8), forKey: "inputMessage"); f.setValue("M", forKey: "inputCorrectionLevel")
        guard let ci = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: ci), img = NSImage(size: rep.size); img.addRepresentation(rep); return img
    }

    private static func menu(_ w: NSWindow) -> NSMenu {
        let m = NSMenu()
        func add(_ title: String, key: String = "", on: Bool? = nil, _ run: @escaping () -> Void) {
            let a = Act(run), i = NSMenuItem(title: title, action: #selector(Act.fire), keyEquivalent: key)
            i.target = a; i.representedObject = a
            if let on { i.state = on ? .on : .off }
            m.addItem(i)
        }
        func note(_ title: String) { let i = NSMenuItem(title: title, action: nil, keyEquivalent: ""); i.isEnabled = false; m.addItem(i) }
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        note("tinyTV \(v)")
        note(!TV.shared.serverUp ? "Сервер недоступний" : TV.shared.connected ? "ТВ на зв'язку" : "ТВ не в мережі")
        m.addItem(.separator())
        // Owner 2026-10-24: the remote on the home Wi-Fi too, open to everyone at home; Tailscale stays for outside.
        refreshLAN()
        let lanURL = lan["name"] ?? "http://tinytv.local"
        add("Пульт у Wi-Fi: \(lanURL.replacingOccurrences(of: "http://", with: ""))") { copy(lanURL) }
        if let ip = lan["ip"], !ip.isEmpty { add("Або за адресою: \(ip.replacingOccurrences(of: "http://", with: ""))") { copy(ip) } }
        if let qr = qrImage(lanURL) {
            let iv = NSImageView(frame: NSRect(x: 16, y: 6, width: 148, height: 148)); iv.image = qr
            let box = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 160)); box.addSubview(iv)
            let i = NSMenuItem(); i.view = box; m.addItem(i)
            note("Скануйте камерою iPhone вдома")
        }
        m.addItem(.separator())
        // Review 31: ⌘, is Settings on a Mac; it used to open the panel. It opens a real, small settings window now.
        add("Налаштування…", key: ",") { SettingsWindow.show() }
        add("Кіно") { KinoBig.open() }
        add("Оновити стан ТВ") { TV.shared.refresh() }
        m.addItem(.separator())
        add("Запускати при вході", on: SMAppService.mainApp.status == .enabled) {
            if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() } else { try? SMAppService.mainApp.register() }
        }
        add("Перезапустити tinyTV") {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
            try? p.run(); NSApp.terminate(nil)
        }
        add("Вийти", key: "q") { NSApp.terminate(nil) }
        return m
    }
}

// MARK: - Settings (review 31)

/// The window behind "Налаштування…" (⌘,): small and real. It holds what the app decides itself; the addresses of the
/// server and of the TV live in config.json and are shown here, not edited.
struct SettingsView: View {
    @ObservedObject var tv = TV.shared
    @State private var login = SMAppService.mainApp.status == .enabled

    private var server: String { URL(string: TV.config["core"] ?? "")?.host ?? "не задано" }
    private var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/tinyTV/config.json")
    }

    var body: some View {
        Form {
            Section("Загальні") {
                Toggle("Запускати tinyTV при вході в систему", isOn: Binding(get: { login }, set: { on in
                    if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                    login = SMAppService.mainApp.status == .enabled
                }))
            }
            Section("З'єднання") {
                LabeledContent("Сервер", value: server)
                LabeledContent("Стан сервера", value: tv.serverUp ? "на зв'язку" : "недоступний")
                LabeledContent("ТВ", value: tv.connected ? "на зв'язку" : "не в мережі")
            }
            Section {
                HStack {
                    Button("Оновити стан ТВ") { tv.refresh() }
                    Button("Показати config.json") { NSWorkspace.shared.activateFileViewerSelecting([configURL]) }
                }
                Text("Адреси сервера й ТВ лежать у config.json. Після зміни перезапустіть tinyTV.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }
}

@MainActor
enum SettingsWindow {
    private static var window: NSWindow?
    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 420, height: 300), styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = "Налаштування tinyTV"; w.isReleasedWhenClosed = false
            let h = NSHostingView(rootView: SettingsView())
            w.contentView = h; w.setContentSize(h.fittingSize); w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}
