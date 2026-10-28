import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Model

struct Photo: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    var state: JobState = .ready
    var jobID: Int?
    var message: String?
    var turns = 0          // clockwise quarter turns applied before printing
    var fit: FitMode?      // per-photo override of the global fit mode
}

struct FitMode: Hashable {
    let title: String
    let cups: String
    let note: String
}

let fitModes = [
    FitMode(title: "Kayıpsız sığdır (önerilen)", cups: "fit", note: "yön otomatik seçilir, kırpma yok, gerekirse kenarlarda boşluk kalır"),
    FitMode(title: "Tam baskı (kırpar)", cups: "fill", note: "sayfayı doldurur, taşan kısım kırpılır"),
]

struct PaperType: Hashable {
    let title: String
    let cups: String
}

let paperTypes = [
    PaperType(title: "Parlak fotoğraf kağıdı", cups: "photographic-glossy"),
    PaperType(title: "HP Premium parlak", cups: "com.hp-specialty-glossy"),
    PaperType(title: "Mat fotoğraf kağıdı", cups: "com.hp-matte-inkjet"),
]

func run(_ tool: String, _ args: [String]) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

func listPrinters() -> (names: [String], preferred: String?) {
    let names = run("/usr/bin/lpstat", ["-e"]).out
        .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    let def = run("/usr/bin/lpstat", ["-d"]).out
        .components(separatedBy: ": ").last?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let preferred = names.first { $0 == def } ?? names.first
    return (names, preferred)
}

/// Blocks until the job has left the CUPS queue and returns its final state; nil if it never left.
func waitForJob(_ job: Int) async -> JobState? {
    for _ in 0..<450 {   // 15 minutes
        if parseJobList(run("/usr/bin/lpstat", ["-W", "not-completed", "-o"]).out)[job] == nil {
            let history = parseJobList(run("/usr/bin/lpstat", ["-W", "all", "-l", "-o"]).out)
            return QueueSnapshot(pending: [:], history: history).state(of: job).0
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
    }
    return nil
}

// MARK: - Saved session

struct SavedPhoto: Codable {
    var path: String
    var turns: Int
    var fit: String?
    var state: JobState
    var jobID: Int?
}

struct SavedSession: Codable {
    var photos: [SavedPhoto]
    var paper: String
    var fit: String
    var copies: Int
    var printer: String
}

// MARK: - View model

@MainActor
final class PrintModel: ObservableObject {
    @Published var photos: [Photo] = [] { didSet { save() } }
    @Published var printers: [String] = []
    @Published var printer: String = "" { didSet { save() } }
    @Published var paper = paperTypes[0] { didSet { save() } }
    @Published var fit = fitModes[0] { didSet { save() } }
    @Published var copies = 1 { didSet { save() } }
    @Published var status = "Fotoğrafları pencereye sürükleyin veya “Fotoğraf Ekle”ye tıklayın."
    @Published var busy = false

    private var abortSend = false
    private var loaded = false
    private var lastSaved = Data()
    private static let sessionURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fotoğraf Çıktı")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("session.json")
    }()

    init() {
        let found = listPrinters()
        printers = found.names
        printer = found.preferred ?? ""
        restore()
        loaded = true
    }

    /// Writes the photo list and every correction to disk, so closing the app loses nothing.
    private func save() {
        guard loaded else { return }
        let session = SavedSession(
            photos: photos.map { SavedPhoto(path: $0.url.path, turns: $0.turns, fit: $0.fit?.cups, state: $0.state, jobID: $0.jobID) },
            paper: paper.cups, fit: fit.cups, copies: copies, printer: printer)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(session), data != lastSaved else { return }
        lastSaved = data
        try? data.write(to: Self.sessionURL, options: .atomic)
    }

    private func restore() {
        guard let data = try? Data(contentsOf: Self.sessionURL),
              let s = try? JSONDecoder().decode(SavedSession.self, from: data) else { return }
        paper = paperTypes.first { $0.cups == s.paper } ?? paper
        fit = fitModes.first { $0.cups == s.fit } ?? fit
        copies = s.copies
        if printers.contains(s.printer) { printer = s.printer }
        photos = s.photos.filter { FileManager.default.fileExists(atPath: $0.path) }.map { sp in
            var p = Photo(url: URL(fileURLWithPath: sp.path), state: sp.state == .sending ? .ready : sp.state,
                          jobID: sp.jobID, turns: sp.turns)
            p.fit = fitModes.first { $0.cups == sp.fit }
            return p
        }
        if !photos.isEmpty { status = "\(photos.count) fotoğraf önceki oturumdan geri yüklendi." }
    }

    func add(_ urls: [URL]) {
        let exts = Set(["jpg", "jpeg", "png", "tif", "tiff", "heic", "heif", "gif", "bmp", "webp"])
        for u in urls where exts.contains(u.pathExtension.lowercased()) {
            if !photos.contains(where: { $0.url == u }) { photos.append(Photo(url: u, turns: bestTurns(for: u))) }
        }
        status = "\(photos.count) fotoğraf hazır."
    }

    func pick() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func update(_ id: UUID, _ change: (inout Photo) -> Void) {
        if let i = photos.firstIndex(where: { $0.id == id }) { change(&photos[i]) }
    }

    func effectiveFit(_ p: Photo) -> FitMode { p.fit ?? fit }

    func rotate(_ id: UUID, by turns: Int) { update(id) { $0.turns = ($0.turns + turns + 4) % 4 } }

    func toggleFit(_ id: UUID) {
        update(id) { p in p.fit = (p.fit ?? fit).cups == "fit" ? fitModes[1] : fitModes[0] }
    }

    /// Sends only photos that have not gone out yet (or failed), so a second click cannot duplicate jobs.
    /// `only` limits the run to a single photo.
    func printAll(only: UUID? = nil) {
        guard !busy, !printer.isEmpty else { return }
        let list = photos
            .filter { ($0.state == .ready || $0.state == .failed) && (only == nil || $0.id == only) }
            .map { ($0.id, $0.url, $0.turns, effectiveFit($0).cups == "fill") }
        guard !list.isEmpty else { return }
        busy = true
        abortSend = false
        let printer = printer, paper = paper.cups, copies = copies
        Task.detached {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fotograf-cikti")
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            // One photo at a time: a printer such as the HP Smart Tank holds a single job and refuses the
            // next one ("spool-area-full") until it is done, so each job must leave the queue first.
            for (i, (id, url, turns, fill)) in list.enumerated() {
                if await MainActor.run(body: { self.abortSend }) { break }
                var outcome: (state: JobState, message: String?) = (.failed, nil)
                for attempt in 1...3 {
                    await MainActor.run {
                        self.status = "Gönderiliyor \(i + 1)/\(list.count): \(url.lastPathComponent)"
                        self.update(id) { $0.state = .sending; $0.message = attempt > 1 ? "Yeniden deneniyor (\(attempt)/3)" : nil }
                    }
                    guard let file = printableURL(for: url, tempDir: tmp, turns: turns, fill: fill) else {
                        outcome = (.failed, "dosya okunamadı"); break
                    }
                    let r = run("/usr/bin/lp", [
                        "-d", printer, "-n", String(copies),
                        "-o", "PageSize=4x6.Fullbleed",       // borderless 4x6
                        "-o", "MediaType=\(paper)",
                        "-o", "cupsPrintQuality=High",
                        "-o", "ColorModel=RGB",
                        "-o", "print-color-mode=color",       // the sheet is already laid out 2:3, no scaling needed
                        file.path,
                    ])
                    try? FileManager.default.removeItem(at: file)   // lp has spooled its own copy
                    guard r.status == 0, let job = parseSubmitted(r.out, printer: printer) else {
                        outcome = (.failed, r.out); break
                    }
                    await MainActor.run { self.update(id) { $0.state = .queued; $0.jobID = job; $0.message = nil } }
                    outcome = (await waitForJob(job) ?? .failed, nil)
                    let stopped = await MainActor.run(body: { self.abortSend })
                    if outcome.state != .failed || stopped || attempt == 3 { break }
                    try? await Task.sleep(nanoseconds: 15_000_000_000)   // let the printer's own spool drain
                }
                let final = outcome
                await MainActor.run { self.update(id) { $0.state = final.state; $0.message = final.message } }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
            await MainActor.run { self.busy = false; self.status = "Gönderim bitti. Durum fotoğrafların altında." }
        }
    }

    /// Polls the CUPS queue and moves each submitted photo to its real state.
    func refresh() async {
        let tracked = photos.compactMap { p -> (UUID, Int)? in
            guard let job = p.jobID, p.state == .queued || p.state == .printing else { return nil }
            return (p.id, job)
        }
        guard !tracked.isEmpty else { return }
        let snap = await Task.detached {
            QueueSnapshot(
                pending: parseJobList(run("/usr/bin/lpstat", ["-W", "not-completed", "-l", "-o"]).out),
                history: parseJobList(run("/usr/bin/lpstat", ["-W", "all", "-l", "-o"]).out))
        }.value
        for (id, job) in tracked {
            let (state, message) = snap.state(of: job)
            update(id) { $0.state = state; $0.message = message }
        }
    }

    /// Cancels this app's jobs that are still waiting or on paper.
    func cancelPending() {
        let jobs = photos.filter { $0.state == .queued || $0.state == .printing }.compactMap(\.jobID)
        abortSend = true   // stop sending the rest of the batch too
        guard !jobs.isEmpty else { return }
        Task.detached {
            _ = run("/usr/bin/cancel", jobs.map(String.init))
            await self.refresh()
        }
    }

    /// 1-based place in line for a queued photo (printing photo is 0).
    func place(of photo: Photo) -> Int? {
        guard photo.state == .queued, let job = photo.jobID else { return nil }
        return photos.filter { $0.state == .queued || $0.state == .printing }
            .compactMap(\.jobID).filter { $0 < job }.count + 1
    }

    var summary: String {
        let count = { (s: JobState) in self.photos.filter { $0.state == s }.count }
        let parts = [
            ("Yazdırılıyor", count(.printing)), ("Sırada", count(.queued)), ("Yazdırıldı", count(.done)),
            ("Hata", count(.failed)), ("İptal", count(.canceled)),
        ].filter { $0.1 > 0 }.map { "\($0.0): \($0.1)" }
        return parts.joined(separator: " · ")
    }
}

// MARK: - UI

struct ContentView: View {
    @StateObject private var m = PrintModel()
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.4),
                                  style: StrokeStyle(lineWidth: 2, dash: [6]))
                if m.photos.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.on.rectangle.angled").font(.system(size: 36))
                        Text("Fotoğrafları buraya sürükleyin").font(.headline)
                    }.foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 10) {
                            ForEach(m.photos) { p in
                                VStack(spacing: 3) {
                                    ZStack(alignment: .topTrailing) {
                                        Thumb(url: p.url, fill: m.effectiveFit(p).cups == "fill", turns: p.turns)
                                            .overlay(alignment: .bottomLeading) { Badge(state: p.state).padding(4) }
                                        if !p.state.isActive {
                                            Button { m.photos.removeAll { $0.id == p.id } } label: {
                                                Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.6))
                                            }.buttonStyle(.plain).padding(3)
                                        }
                                    }
                                    Text(caption(for: p)).font(.caption2).foregroundStyle(color(for: p.state))
                                        .lineLimit(1).help(p.message ?? p.url.lastPathComponent)
                                    if p.state == .ready || p.state == .failed {
                                        HStack(spacing: 2) {
                                            tool("rotate.left", "Sola döndür") { m.rotate(p.id, by: -1) }
                                            tool("rotate.right", "Sağa döndür") { m.rotate(p.id, by: 1) }
                                            tool("crop", m.effectiveFit(p).cups == "fit"
                                                 ? "Tam baskı yap (bu fotoğrafı kırparak sayfayı doldurur)" : "Kayıpsız sığdırmaya dön",
                                                 active: m.effectiveFit(p).cups == "fill") { m.toggleFit(p.id) }
                                            tool("printer", "Yalnızca bunu yazdır") { m.printAll(only: p.id) }
                                                .disabled(m.busy || m.printer.isEmpty)
                                        }
                                    }
                                }
                            }
                        }.padding(10)
                    }
                }
            }
            .frame(minHeight: 220)
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        if let url { Task { @MainActor in m.add([url]) } }
                    }
                }
                return true
            }

            HStack {
                Picker("Yazıcı", selection: $m.printer) {
                    ForEach(m.printers, id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ")).tag($0) }
                }
                Picker("Kağıt", selection: $m.paper) {
                    ForEach(paperTypes, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Sığdırma", selection: $m.fit) {
                    ForEach(fitModes, id: \.self) { Text($0.title).tag($0) }
                }
                Stepper("Adet: \(m.copies)", value: $m.copies, in: 1...50)
            }

            HStack {
                Text("4×6 inç · kenarlıksız · \(m.fit.note) · en yüksek kalite · RGB renk")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }

            if !m.summary.isEmpty {
                HStack {
                    Text(m.summary).font(.callout.weight(.medium))
                    Spacer()
                }
            }

            HStack {
                Text(m.status).font(.callout).lineLimit(2)
                Spacer()
                Button("Fotoğraf Ekle…") { m.pick() }
                Button("Temizle") { m.photos.removeAll { !$0.state.isActive } }
                    .disabled(!m.photos.contains { !$0.state.isActive })
                Button("Bekleyenleri İptal Et") { m.cancelPending() }
                    .disabled(!m.photos.contains { $0.state == .queued || $0.state == .printing })
                Button("Yazdır (\(m.photos.filter { $0.state == .ready || $0.state == .failed }.count))") { m.printAll() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!m.photos.contains { $0.state == .ready || $0.state == .failed } || m.busy || m.printer.isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 700, minHeight: 440)
        .task {
            while !Task.isCancelled {
                await m.refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func tool(_ symbol: String, _ help: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12))
                .foregroundStyle(active ? Color.orange : Color.primary)
                .frame(width: 22, height: 20)
        }.buttonStyle(.borderless).help(help)
    }

    func caption(for p: Photo) -> String {
        if let n = m.place(of: p) { return "Sırada \(n)" }
        return p.state == .ready ? p.url.lastPathComponent : p.state.label
    }

    func color(for s: JobState) -> Color {
        switch s {
        case .done: return .green
        case .failed: return .red
        case .canceled: return .orange
        case .printing: return .accentColor
        default: return .secondary
        }
    }
}

struct Badge: View {
    let state: JobState
    var body: some View {
        switch state {
        case .ready: EmptyView()
        case .sending, .printing:
            ProgressView().controlSize(.small).padding(4).background(.regularMaterial, in: Circle())
        case .queued: icon("clock.fill", .gray)
        case .done: icon("checkmark.circle.fill", .green)
        case .failed: icon("exclamationmark.triangle.fill", .red)
        case .canceled: icon("xmark.circle.fill", .orange)
        }
    }
    func icon(_ name: String, _ tint: Color) -> some View {
        Image(systemName: name).foregroundStyle(.white, tint).font(.system(size: 18))
            .background(Circle().fill(.white).padding(2))
    }
}

/// The actual 4x6 sheet as it will print: white margins in fit mode, the crop in fill mode.
struct Thumb: View {
    let url: URL
    let fill: Bool
    let turns: Int
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() } else { Color.gray.opacity(0.2) }
        }
        .frame(width: 80, height: 120).cornerRadius(4)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))
        .task(id: "\(turns)-\(fill)") {
            let (u, t, f) = (url, turns, fill)
            image = await Task.detached {
                guard let s = CGImageSourceCreateWithURL(u as CFURL, nil),
                      let c = CGImageSourceCreateThumbnailAtIndex(s, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 700] as CFDictionary),
                      let page = composePage(c, turns: t, fill: f, width: 160) else { return nil as NSImage? }
                return NSImage(cgImage: page, size: .zero)
            }.value
        }
    }
}

@main
struct FotografCiktiApp: App {
    var body: some Scene {
        WindowGroup("Fotoğraf Çıktı") { ContentView() }
    }
}
