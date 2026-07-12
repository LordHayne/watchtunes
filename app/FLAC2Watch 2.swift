// FLAC2Watch.app — native front-end for the flac2watch CLI.
//
// All real work (FLAC→MP3 conversion, watch discovery, adb push) lives in the
// CLI at ~/.local/bin/flac2watch; this app only shows status and triggers it.
// Built by install.sh with plain `swiftc` — no Xcode project needed.
// UI: dark Liquid-Glass look (macOS 26 "Tahoe") + menu bar companion.

import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

// MARK: - App state

struct LibraryEntry: Identifiable, Hashable {
    let id = UUID()
    let path: String    // relative path, e.g. "Album/Song.mp3"
    let synced: Bool    // true = on watch, false = pending
}

struct SongMeta: Identifiable, Hashable {
    let id = UUID()
    let path: String
    let artist: String
    let album: String
    let title: String
    let coverPath: String
    let hasCover: Bool
}

final class AppState: ObservableObject {

    static let shared = AppState()
    static let cliPath = NSHomeDirectory() + "/.local/bin/flac2watch"

    struct Status {
        var library = NSHomeDirectory() + "/Music/WatchSync"
        var localCount = 0
        var paired = false
        var reachable = false
        var endpoint = ""
        var watchCount: Int?
        var playerInstalled = true
        var pending = 0
        var battery: Int?
        var freeKB: Int64?
        var totalKB: Int64?
        var bitrate = "320k"
        var mirrorDelete = true
    }

    struct SyncProgress {
        var done: Int
        var total: Int
        var current: String
    }

    @Published var status = Status()
    @Published var statusLoaded = false
    @Published var refreshing = false
    @Published var syncing = false
    @Published var syncProgress: SyncProgress?
    @Published var log: [String] = []
    @Published var cliMissing = false
    @Published var watchSongs: [String] = []
    @Published var watchSongsCached = false
    @Published var libraryDiff: [LibraryEntry] = []
    @Published var libraryDiffLoading = false
    @Published var songMeta: [String: SongMeta] = [:]  // path -> metadata
    @Published var metaLoading = false
    @Published var nowPlaying: SongMeta?
    @Published var isPlaying = false

    private var audioPlayer: AVAudioPlayer?
    @Published var keepAwake = UserDefaults.standard.bool(forKey: "keepAwake") {
        didSet { UserDefaults.standard.set(keepAwake, forKey: "keepAwake") }
    }

    private var timer: Timer?
    private var pingTimer: Timer?
    private var pendingSync = false
    private var wasReachable = false
    private let workQueue = DispatchQueue(label: "flac2watch.work")

    func start() {
        guard timer == nil else { return }
        cliMissing = !FileManager.default.isExecutableFile(atPath: Self.cliPath)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // Keep-awake: a tiny adb no-op keeps the watch's Wi-Fi from napping.
        pingTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            guard let self, self.keepAwake, self.status.reachable, !self.syncing else { return }
            self.workQueue.async { self.runCLI(["ping"]) }
        }
    }

    // MARK: CLI bridge

    @discardableResult
    private func runCLI(_ args: [String], onLine: ((String) -> Void)? = nil) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: Self.cliPath)
        proc.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        proc.environment = env
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        var pending = ""
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            pending += chunk
            while let nl = pending.firstIndex(of: "\n") {
                let line = String(pending[..<nl])
                pending = String(pending[pending.index(after: nl)...])
                onLine?(line)
            }
        }
        do {
            try proc.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            onLine?("Fehler: \(error.localizedDescription)")
            return -1
        }
        proc.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        if !pending.isEmpty { onLine?(pending) }
        return proc.terminationStatus
    }

    // MARK: Actions

    func refresh() {
        guard !cliMissing, !refreshing else { return }
        refreshing = true
        workQueue.async {
            var lines: [String] = []
            self.runCLI(["status", "--porcelain"]) { lines.append($0) }
            var s = Status()
            for line in lines {
                guard let eq = line.firstIndex(of: "=") else { continue }
                let key = String(line[..<eq])
                let val = String(line[line.index(after: eq)...])
                switch key {
                case "library":       s.library = val
                case "local":         s.localCount = Int(val) ?? 0
                case "paired":        s.paired = !val.isEmpty
                case "reachable":     s.reachable = (val == "1")
                case "endpoint":      s.endpoint = val
                case "watch":         s.watchCount = Int(val)
                case "player":        s.playerInstalled = (val == "1")
                case "pending":       s.pending = Int(val) ?? 0
                case "battery":       s.battery = Int(val)
                case "free_kb":       s.freeKB = Int64(val)
                case "total_kb":      s.totalKB = Int64(val)
                case "bitrate":       s.bitrate = val
                case "mirror_delete": s.mirrorDelete = (val == "true")
                default: break
                }
            }
            if !s.reachable { s.watchCount = nil }
            DispatchQueue.main.async {
                let justReconnected = !self.wasReachable && s.reachable
                self.wasReachable = s.reachable
                self.status = s
                self.statusLoaded = true
                self.refreshing = false
                // Watch just came back online with pending songs → auto-sync
                if justReconnected && s.pending > 0 && !self.syncing && !self.cliMissing {
                    self.appendLog("Uhr wieder erreichbar — auto-sync …")
                    self.sync()
                }
            }
        }
    }

    func sync() {
        guard !cliMissing else { return }
        if syncing { pendingSync = true; return }
        syncing = true
        appendLog("— Sync gestartet —")
        workQueue.async {
            self.runCLI(["sync", "--progress"]) { line in
                if line.hasPrefix("TOTAL ") {
                    let n = Int(line.dropFirst(6).trimmingCharacters(in: .whitespaces)) ?? 0
                    DispatchQueue.main.async {
                        self.syncProgress = n > 0 ? SyncProgress(done: 0, total: n, current: "") : nil
                    }
                    return
                }
                if line.hasPrefix("PROGRESS ") {
                    let parts = line.split(separator: " ", maxSplits: 3,
                                           omittingEmptySubsequences: true)
                    guard parts.count >= 3,
                          let i = Int(parts[1]), let n = Int(parts[2]) else { return }
                    let name = parts.count > 3 ? String(parts[3]) : ""
                    DispatchQueue.main.async {
                        self.syncProgress = SyncProgress(done: i, total: n, current: name)
                    }
                    return
                }
                let t = line.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { self.appendLog(t) }
            }
            DispatchQueue.main.async {
                self.syncing = false
                self.syncProgress = nil
                self.refresh()
                if self.pendingSync { self.pendingSync = false; self.sync() }
            }
        }
    }

    /// Copy dropped files/folders into the library, then sync.
    func importItems(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let libURL = URL(fileURLWithPath: status.library, isDirectory: true)
        workQueue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: libURL, withIntermediateDirectories: true)
            let libPath = libURL.standardizedFileURL.resolvingSymlinksInPath().path
            let audioExts = ["flac", "mp3", "m4a"]
            var copied = 0, skipped = 0, alreadyIn = 0
            for src in urls {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: src.path, isDirectory: &isDir) else { continue }
                // Anything already inside the library must never be copied onto
                // itself — and especially never deleted.
                let srcPath = src.standardizedFileURL.resolvingSymlinksInPath().path
                if srcPath == libPath || srcPath.hasPrefix(libPath + "/") {
                    alreadyIn += 1
                    continue
                }
                if !isDir.boolValue && !audioExts.contains(src.pathExtension.lowercased()) {
                    skipped += 1
                    continue
                }
                let dst = libURL.appendingPathComponent(src.lastPathComponent)
                do {
                    if fm.fileExists(atPath: dst.path) {
                        // replace via Trash so a mistake stays recoverable
                        try fm.trashItem(at: dst, resultingItemURL: nil)
                    }
                    try fm.copyItem(at: src, to: dst)
                    copied += 1
                } catch {
                    self.appendLog("Kopieren fehlgeschlagen: \(src.lastPathComponent)")
                }
            }
            var msg = "\(copied) Element\(copied == 1 ? "" : "e") übernommen"
            if alreadyIn > 0 { msg += ", \(alreadyIn) schon in der Bibliothek" }
            if skipped > 0 { msg += ", \(skipped) übersprungen (kein FLAC/MP3/M4A)" }
            self.appendLog(msg)
            DispatchQueue.main.async {
                if copied > 0 { self.sync() } else { self.refresh() }
            }
        }
    }

    func pair(addr: String, code: String, completion: @escaping (Bool) -> Void) {
        workQueue.async {
            let rc = self.runCLI(["pair", addr, code]) { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { self.appendLog(t) }
            }
            DispatchQueue.main.async {
                completion(rc == 0)
                self.refresh()
            }
        }
    }

    func installPlayer() {
        appendLog("Öffne Play-Store-Seite auf der Uhr …")
        workQueue.async {
            self.runCLI(["player"]) { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { self.appendLog(t) }
            }
        }
    }

    func launchPlayer() {
        workQueue.async {
            self.runCLI(["launch"]) { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { self.appendLog(t) }
            }
        }
    }

    func reconnect() {
        guard !cliMissing else { return }
        appendLog("— Neu verbinden —")
        refreshing = true
        workQueue.async {
            self.runCLI(["reconnect"]) { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { self.appendLog(t) }
            }
            DispatchQueue.main.async {
                self.refreshing = false
                self.refresh()
            }
        }
    }

    func loadWatchSongs() {
        workQueue.async {
            var lines: [String] = []
            self.runCLI(["list"]) { lines.append($0) }
            var cached = false
            if lines.first == "# cached" { cached = true; lines.removeFirst() }
            let songs = lines
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            DispatchQueue.main.async {
                self.watchSongs = songs
                self.watchSongsCached = cached
            }
        }
    }

    func loadDiff() {
        libraryDiffLoading = true
        workQueue.async {
            var entries: [LibraryEntry] = []
            self.runCLI(["diff"]) { line in
                let parts = line.split(separator: "\t", maxSplits: 1)
                guard parts.count == 2 else { return }
                let status = String(parts[0])
                let path = String(parts[1]).trimmingCharacters(in: .whitespaces)
                guard !path.isEmpty else { return }
                entries.append(LibraryEntry(path: path, synced: status == "synced"))
            }
            DispatchQueue.main.async {
                self.libraryDiff = entries
                self.libraryDiffLoading = false
            }
        }
    }

    func loadMeta() {
        metaLoading = true
        workQueue.async {
            var meta: [String: SongMeta] = [:]
            self.runCLI(["meta"]) { line in
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                let path = obj["path"] as? String ?? ""
                guard !path.isEmpty else { return }
                meta[path] = SongMeta(
                    path: path,
                    artist: obj["artist"] as? String ?? "",
                    album: obj["album"] as? String ?? "",
                    title: obj["title"] as? String ?? "",
                    coverPath: obj["cover"] as? String ?? "",
                    hasCover: obj["has_cover"] as? Bool ?? false
                )
            }
            DispatchQueue.main.async {
                self.songMeta = meta
                self.metaLoading = false
            }
        }
    }

    // MARK: - Local preview player

    /// Resolve a watch-relative .mp3 path back to the actual source file on disk.
    private func sourceFile(for path: String) -> String? {
        let lib = status.library
        let stem = (path as NSString).deletingPathExtension
        for ext in ["flac", "mp3", "m4a", "FLAC", "MP3", "M4A"] {
            let candidate = "\(lib)/\(stem).\(ext)"
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }

    func previewPlay(_ meta: SongMeta) {
        guard let src = sourceFile(for: meta.path) else { return }
        // Toggle off if same song is playing
        if nowPlaying?.path == meta.path && isPlaying {
            audioPlayer?.pause()
            isPlaying = false
            return
        }
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: src))
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
            nowPlaying = meta
            isPlaying = true
        } catch {
            appendLog("Abspielen fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    func previewTogglePause() {
        guard let p = audioPlayer else { return }
        if p.isPlaying { p.pause(); isPlaying = false }
        else { p.play(); isPlaying = true }
    }

    func previewStop() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        nowPlaying = nil
    }

    /// Remove one song: local sources go to the Trash, the watch copy is
    /// deleted directly (works regardless of the mirror-delete setting).
    func removeSong(_ target: String) {
        watchSongs.removeAll { $0 == target }
        let lib = status.library
        workQueue.async {
            let fm = FileManager.default
            let stem = (target as NSString).deletingPathExtension
            var trashed = 0
            if let walker = fm.enumerator(at: URL(fileURLWithPath: lib),
                                          includingPropertiesForKeys: nil) {
                for case let url as URL in walker {
                    guard ["flac", "mp3", "m4a"].contains(url.pathExtension.lowercased()) else { continue }
                    let rel = url.path.hasPrefix(lib + "/")
                        ? String(url.path.dropFirst(lib.count + 1))
                        : url.lastPathComponent
                    if (rel as NSString).deletingPathExtension == stem {
                        if (try? fm.trashItem(at: url, resultingItemURL: nil)) != nil { trashed += 1 }
                    }
                }
            }
            if trashed > 0 { self.appendLog("In den Papierkorb: \(stem)") }
            self.runCLI(["remove", target]) { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { self.appendLog(t) }
            }
            DispatchQueue.main.async { self.refresh() }
        }
    }

    func setConfig(_ key: String, _ value: String) {
        workQueue.async {
            self.runCLI(["config", "set", key, value]) { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { self.appendLog(t) }
            }
            DispatchQueue.main.async { self.refresh() }
        }
    }

    func chooseLibraryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: status.library)
        panel.prompt = "Auswählen"
        if panel.runModal() == .OK, let url = panel.url {
            setConfig("library", url.path)
        }
    }

    func openLibrary() {
        let lib = URL(fileURLWithPath: status.library, isDirectory: true)
        try? FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        NSWorkspace.shared.open(lib)
    }

    private func appendLog(_ line: String) {
        DispatchQueue.main.async {
            self.log.append(line)
            if self.log.count > 300 { self.log.removeFirst(self.log.count - 300) }
        }
    }
}

// Collects URLs arriving from concurrent NSItemProvider callbacks.
final class URLCollector {
    private let lock = NSLock()
    private var collected: [URL] = []
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return collected }
    func add(_ url: URL) { lock.lock(); collected.append(url); lock.unlock() }
}

// MARK: - Theme

enum Theme {
    static let violet = Color(red: 0.48, green: 0.40, blue: 0.98)
    static let cyan   = Color(red: 0.20, green: 0.65, blue: 0.95)
    static var accent: LinearGradient {
        LinearGradient(colors: [violet, cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Main window

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var dropTargeted = false
    @State private var showPair = false
    @State private var showSettings = false
    @State private var showSongs = false
    @State private var showLibrary = false

    var body: some View {
        VStack(spacing: 14) {
            header
            if state.statusLoaded && state.status.paired { pills }
            if state.statusLoaded && state.status.reachable && !state.status.playerInstalled {
                playerWarning
            }
            dropZone
            actions
            if state.syncing, let p = state.syncProgress, p.total > 0 {
                progressBar(p)
            }
            logView
        }
        .padding(20)
        .padding(.top, 16)            // room for the traffic lights
        .frame(width: 380)
        .background(windowBackground.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showPair) { PairSheet().environmentObject(state) }
        .sheet(isPresented: $showSettings) { SettingsSheet().environmentObject(state) }
        .sheet(isPresented: $showSongs) { SongsSheet().environmentObject(state) }
        .sheet(isPresented: $showLibrary) { LibrarySheet().environmentObject(state) }
    }

    private var windowBackground: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.09, green: 0.07, blue: 0.20),
                                    Color(red: 0.03, green: 0.03, blue: 0.08)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Theme.violet.opacity(0.32), .clear],
                           center: UnitPoint(x: 0.15, y: 0.0),
                           startRadius: 0, endRadius: 360)
            RadialGradient(colors: [Theme.cyan.opacity(0.16), .clear],
                           center: UnitPoint(x: 1.0, y: 0.4),
                           startRadius: 0, endRadius: 320)
        }
    }

    // MARK: status

    private var headerTitle: String {
        if state.cliMissing { return "flac2watch-CLI fehlt" }
        if !state.statusLoaded { return "Suche Uhr …" }
        if !state.status.paired { return "Uhr noch nicht gekoppelt" }
        return state.status.reachable ? "Uhr verbunden" : "Uhr nicht erreichbar"
    }

    private var headerSub: String {
        if state.cliMissing { return "Bitte ./install.sh im flac2watch-Repo ausführen" }
        if !state.statusLoaded { return "" }
        if !state.status.paired { return "Einmal koppeln, danach läuft alles automatisch" }
        return state.status.reachable
            ? state.status.endpoint
            : "Uhr wecken (Display an) — ihr WLAN schläft sonst"
    }

    private var headerColor: Color {
        if state.cliMissing { return .red }
        if !state.statusLoaded { return .gray }
        if !state.status.paired { return .orange }
        return state.status.reachable ? .green : .gray
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Theme.accent)
                Image(systemName: "applewatch.radiowaves.left.and.right")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.white)
            }
            .frame(width: 42, height: 42)
            .shadow(color: Theme.violet.opacity(0.55), radius: 12, y: 2)

            VStack(alignment: .leading, spacing: 3) {
                Text("FLAC2Watch")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                HStack(spacing: 6) {
                    Circle()
                        .fill(headerColor)
                        .frame(width: 7, height: 7)
                        .shadow(color: headerColor.opacity(0.9), radius: 4)
                    Text(headerTitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                if !headerSub.isEmpty {
                    Text(headerSub)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if state.refreshing || state.syncing {
                ProgressView().controlSize(.small)
            }
            if state.status.reachable && state.status.playerInstalled {
                Button { state.launchPlayer() } label: {
                    Image(systemName: "play.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Player auf der Uhr starten")
            }
            if state.statusLoaded && state.status.paired && !state.status.reachable {
                Button { state.reconnect() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.circle")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Neu verbinden")
                .disabled(state.refreshing)
            }
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Einstellungen")
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    // MARK: pills

    private var pills: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    state.loadDiff()
                    showLibrary = true
                } label: {
                    pill("music.note.list", "\(state.status.localCount) lokal", Theme.violet)
                }
                .buttonStyle(.plain)
                .help("Bibliothek anzeigen — was ist synced, was fehlt")
                if let w = state.status.watchCount {
                    Button {
                        state.loadWatchSongs()
                        showSongs = true
                    } label: {
                        pill("applewatch", "\(w) auf der Uhr", Theme.cyan)
                    }
                    .buttonStyle(.plain)
                    .help("Songs auf der Uhr anzeigen")
                }
                if state.status.pending > 0 {
                    pill("arrow.up.circle.fill", "\(state.status.pending) warten", .orange)
                }
                Spacer()
            }
            if state.status.battery != nil || state.status.freeKB != nil {
                HStack(spacing: 8) {
                    if let b = state.status.battery {
                        pill("battery.100percent", "\(b) %", batteryColor(b))
                    }
                    if let free = state.status.freeKB {
                        pill("internaldrive", String(format: "%.1f GB frei", Double(free) / 1_048_576.0), .secondary)
                    }
                    Spacer()
                }
            }
        }
    }

    private func batteryColor(_ level: Int) -> Color {
        level > 50 ? .green : (level > 20 ? .yellow : .red)
    }

    private func pill(_ icon: String, _ text: String, _ tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
            Text(text).font(.caption)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
    }

    private var playerWarning: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Text("Kein Musik-Player auf der Uhr").font(.caption)
            Spacer()
            Button("Installieren") { state.installPlayer() }
                .controlSize(.small)
                .buttonStyle(.glass)
                .tint(.orange)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular.tint(.orange.opacity(0.25)), in: .capsule)
    }

    // MARK: drop zone

    private var dropZone: some View {
        VStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(Theme.accent)
                    .opacity(dropTargeted ? 1 : 0.16)
                Image(systemName: "arrow.down")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(dropTargeted ? Color.white : Color.secondary)
            }
            .frame(width: 44, height: 44)
            Text("Musik hierher ziehen")
                .font(.system(.callout, design: .rounded).weight(.medium))
            Text("FLAC · MP3 · M4A — landet automatisch auf der Uhr")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 124)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                .foregroundStyle(dropTargeted
                                 ? AnyShapeStyle(Theme.accent)
                                 : AnyShapeStyle(Color.white.opacity(0.14)))
                .padding(6)
        )
        .animation(.easeOut(duration: 0.15), value: dropTargeted)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let collector = URLCollector()
        let group = DispatchGroup()
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { collector.add(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { state.importItems(collector.urls) }
        return true
    }

    // MARK: actions / progress / log

    private var actions: some View {
        HStack(spacing: 10) {
            if state.statusLoaded && !state.status.paired && !state.cliMissing {
                Button { showPair = true } label: {
                    Label("Uhr koppeln", systemImage: "link")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.violet)
            } else {
                Button { state.sync() } label: {
                    Label(state.syncing ? "Synct …" : "Jetzt syncen",
                          systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.violet)
                .disabled(state.syncing || state.cliMissing)
            }

            Button { state.openLibrary() } label: {
                Label("Ordner", systemImage: "folder")
            }
            .buttonStyle(.glass)
        }
        .controlSize(.large)
    }

    private func progressBar(_ p: AppState.SyncProgress) -> some View {
        VStack(spacing: 4) {
            ProgressView(value: Double(min(p.done, p.total)), total: Double(p.total))
                .progressViewStyle(.linear)
                .tint(Theme.violet)
            HStack {
                Text(p.current)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                Text("\(p.done) / \(p.total)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if state.log.isEmpty {
                        Text("Bereit.").foregroundStyle(.tertiary)
                    }
                    ForEach(Array(state.log.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Color.clear.frame(height: 1).id("logEnd")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(.system(size: 11, design: .monospaced))
                .padding(10)
            }
            .frame(height: 96)
            .background(RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.32)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08)))
            .onChange(of: state.log.count) {
                proxy.scrollTo("logEnd", anchor: .bottom)
            }
        }
    }
}

// MARK: - Songs on the watch

struct SongsSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Auf der Uhr")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                if state.watchSongsCached {
                    Text("Stand: letzter Kontakt")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text("\(state.watchSongs.count) Songs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if state.watchSongs.isEmpty {
                Text("Keine Songs auf der Uhr.")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(state.watchSongs, id: \.self) { song in
                            songRow(song)
                        }
                    }
                }
                .frame(height: 340)
                .background(RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.25)))
            }

            HStack {
                Button {
                    state.launchPlayer()
                } label: {
                    Label("Player öffnen", systemImage: "play.circle")
                }
                .buttonStyle(.glass)
                .disabled(!state.status.reachable)
                Spacer()
                Button("Schließen") { dismiss() }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.violet)
            }
        }
        .padding(18)
        .frame(width: 460)
        .preferredColorScheme(.dark)
        .onAppear { state.loadMeta() }
    }

    private func songRow(_ song: String) -> some View {
        let meta = state.songMeta[song]
        let displayName = meta?.title.isEmpty == false ? meta!.title : ((song as NSString).lastPathComponent as NSString).deletingPathExtension
        let folder = (song as NSString).deletingLastPathComponent
        return HStack(spacing: 10) {
            if let m = meta, m.hasCover, let img = NSImage(contentsOfFile: m.coverPath) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.accent.opacity(0.3))
                    .frame(width: 32, height: 32)
                    .overlay(Image(systemName: "music.note").font(.system(size: 12)).foregroundStyle(.secondary))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let m = meta, !m.artist.isEmpty {
                        Text(m.artist)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    } else if !folder.isEmpty {
                        Text(folder)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
            Button {
                state.removeSong(song)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Vom Mac (Papierkorb) und von der Uhr entfernen")
            .disabled(!state.status.reachable)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}

// MARK: - Library overview (synced / pending)

struct LibrarySheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    private var syncedCount: Int { state.libraryDiff.filter { $0.synced }.count }
    private var pendingCount: Int { state.libraryDiff.filter { !$0.synced }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Bibliothek")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                Spacer()
                HStack(spacing: 8) {
                    pill("checkmark.circle.fill", "\(syncedCount) synced", .green)
                    pill("clock.fill", "\(pendingCount) pending", .orange)
                }
            }

            if state.libraryDiffLoading || state.metaLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            } else if state.libraryDiff.isEmpty {
                Text("Bibliothek leer — Musik in den Ordner legen oder hierher ziehen.")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(state.libraryDiff) { entry in
                            diffRow(entry)
                        }
                    }
                }
                .frame(height: 360)
                .background(RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.25)))
            }

            HStack {
                Button {
                    state.openLibrary()
                } label: {
                    Label("Ordner öffnen", systemImage: "folder")
                }
                .buttonStyle(.glass)
                Spacer()
                Button("Schließen") { dismiss() }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.violet)
            }
        }
        .padding(18)
        .frame(width: 460)
        .preferredColorScheme(.dark)
        .onAppear {
            state.loadDiff()
            state.loadMeta()
        }
    }

    private func pill(_ icon: String, _ text: String, _ tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
            Text(text).font(.caption)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
    }

    private func diffRow(_ entry: LibraryEntry) -> some View {
        let meta = state.songMeta[entry.path]
        let displayName = meta?.title.isEmpty == false ? meta!.title : (entry.path as NSString).deletingPathExtension
        let folder = (entry.path as NSString).deletingLastPathComponent
        return HStack(spacing: 10) {
            // Cover or placeholder
            if let m = meta, m.hasCover, let img = NSImage(contentsOfFile: m.coverPath) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.accent.opacity(0.3))
                    .frame(width: 32, height: 32)
                    .overlay(Image(systemName: "music.note").font(.system(size: 12)).foregroundStyle(.secondary))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let m = meta, !m.artist.isEmpty {
                        Text(m.artist)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    } else if !folder.isEmpty {
                        Text(folder)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
            Image(systemName: entry.synced ? "checkmark.circle.fill" : "clock.fill")
                .font(.system(size: 12))
                .foregroundStyle(entry.synced ? .green : .orange)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}

// MARK: - Settings

struct SettingsSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var bitrate = "320k"
    @State private var mirror = true
    @State private var loaded = false
    @State private var showPair = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Einstellungen")
                .font(.system(size: 16, weight: .bold, design: .rounded))

            HStack {
                Text("MP3-Bitrate")
                Spacer()
                Picker("", selection: $bitrate) {
                    ForEach(["128k", "160k", "192k", "256k", "320k"], id: \.self) { Text($0) }
                }
                .labelsHidden()
                .frame(width: 90)
            }
            Text("Gilt für neu konvertierte Songs; der Konvertierungs-Cache wird geleert.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Toggle("Lokal Gelöschtes auch von der Uhr entfernen", isOn: $mirror)
            Toggle("Uhr wachhalten, solange die App läuft", isOn: $state.keepAwake)
            Text("Verhindert das WLAN-Nickerchen der Uhr — kostet etwas Uhr-Akku.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Divider()

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Musik-Ordner")
                    Text(state.status.library)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Ändern …") { state.chooseLibraryFolder() }
                    .buttonStyle(.glass)
            }
            Text("Nach einem Ordnerwechsel ./install.sh erneut ausführen, damit der Auto-Sync den neuen Ordner überwacht.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Uhr-Kopplung")
                    Text(verbatim: state.status.paired
                         ? "Gekoppelt: ja"
                         : "Noch nicht gekoppelt")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Neu koppeln") { showPair = true }
                    .buttonStyle(.glass)
            }
            Text("Wenn die Uhr sich nicht mehr verbindet: Drahtloses Debugging auf der Uhr reaktivieren und neu koppeln.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            HStack {
                Spacer()
                Button("Fertig") { dismiss() }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.violet)
            }
        }
        .padding(20)
        .frame(width: 400)
        .preferredColorScheme(.dark)
        .onAppear {
            bitrate = state.status.bitrate
            mirror = state.status.mirrorDelete
            DispatchQueue.main.async { loaded = true }
        }
        .onChange(of: bitrate) {
            if loaded { state.setConfig("bitrate", bitrate) }
        }
        .onChange(of: mirror) {
            if loaded { state.setConfig("mirror_delete", mirror ? "true" : "false") }
        }
        .sheet(isPresented: $showPair) { PairSheet().environmentObject(state) }
    }
}

// MARK: - Pairing

struct PairSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var addr = ""
    @State private var code = ""
    @State private var busy = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Theme.accent)
                    Image(systemName: "link")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 32, height: 32)
                Text("Uhr koppeln")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
            }
            Text("""
            Auf der Uhr:
            1. Einstellungen → Uhr-Info → Softwareinformationen → 7× auf „Softwareversion“ tippen
            2. Entwickleroptionen → ADB-Debugging + Drahtloses Debugging einschalten
            3. Drahtloses Debugging → „Gerät koppeln“ antippen
            """)
            .font(.caption)
            .foregroundStyle(.secondary)

            TextField("IP:Port (z. B. 192.168.1.77:46151)", text: $addr)
            TextField("6-stelliger Code", text: $code)

            if failed {
                Text("Kopplung fehlgeschlagen — Code/Port ändern sich. Auf der Uhr neu anzeigen lassen und nochmal versuchen.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Abbrechen") { dismiss() }
                    .buttonStyle(.glass)
                Button(busy ? "Kopple …" : "Koppeln") {
                    busy = true
                    failed = false
                    state.pair(addr: addr.trimmingCharacters(in: .whitespaces),
                               code: code.trimmingCharacters(in: .whitespaces)) { ok in
                        busy = false
                        if ok { dismiss() } else { failed = true }
                    }
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.violet)
                .disabled(busy || addr.isEmpty || code.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .textFieldStyle(.roundedBorder)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Menu bar

struct MenuBarLabel: View {
    @ObservedObject var state = AppState.shared

    private var symbol: String {
        if !state.statusLoaded || !state.status.paired { return "applewatch" }
        return state.status.reachable ? "applewatch.radiowaves.left.and.right" : "applewatch.slash"
    }

    private var badge: String {
        state.statusLoaded && state.status.pending > 0 ? "\(state.status.pending)" : ""
    }

    // NB: the label view must keep a STABLE structure — a conditional (if/else)
    // here makes SwiftUI silently fail to create ANY scene of the app.
    var body: some View {
        Label { Text(badge) } icon: { Image(systemName: symbol) }
            .labelStyle(.titleAndIcon)
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    private var statusLine: String {
        if !state.statusLoaded { return "Suche Uhr …" }
        if !state.status.paired { return "Uhr noch nicht gekoppelt" }
        if state.status.reachable {
            var s = "Uhr verbunden"
            if let w = state.status.watchCount { s += " — \(w) Songs" }
            if let b = state.status.battery { s += " · \(b) %" }
            return s
        }
        return "Uhr nicht erreichbar (Uhr wecken)"
    }

    var body: some View {
        Text(statusLine)
        if state.statusLoaded && state.status.pending > 0 {
            Text("\(state.status.pending) Song\(state.status.pending == 1 ? "" : "s") warten auf die Uhr")
        }
        Divider()
        Button(state.syncing ? "Synct …" : "Jetzt syncen") { state.sync() }
            .disabled(state.syncing || state.cliMissing)
        Button("Player auf der Uhr öffnen") { state.launchPlayer() }
            .disabled(!state.status.reachable)
        Button("Neu verbinden") { state.reconnect() }
            .disabled(state.refreshing || state.cliMissing || !state.status.paired)
        Button("Musik-Ordner öffnen") { state.openLibrary() }
        Divider()
        Button("Fenster öffnen") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("FLAC2Watch beenden") { NSApp.terminate(nil) }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }
    // Files dragged onto the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        AppState.shared.importItems(urls)
    }
    // Stay alive in the menu bar when the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct FLAC2WatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(state)
                .onAppear { state.start() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .windowBackgroundDragBehavior(.enabled)

        MenuBarExtra {
            MenuBarContent().environmentObject(state)
        } label: {
            MenuBarLabel()
        }
    }
}
