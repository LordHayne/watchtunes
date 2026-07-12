// WatchTunes.app — native front-end for the watchtunes CLI.
//
// All real work (FLAC→MP3 conversion, watch discovery, adb push) lives in the
// CLI at ~/.local/bin/watchtunes; this app only shows status and triggers it.
// Built by install.sh with plain `swiftc` — no Xcode project needed.
// UI: dark Liquid-Glass look (macOS 26 "Tahoe") + menu bar companion.
//
// Multi-library support: sidebar with library tree, scan command, addfolder/rmfolder.

import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

// MARK: - Data models

struct ScannedSong: Identifiable, Hashable {
    let id = UUID()
    let library: String       // absolute path of library
    let libraryName: String   // basename of library
    let relPath: String       // library_name/Album/Song.mp3
    let absPath: String       // /full/path/to/source.flac
    let artist: String
    let album: String
    let title: String
    let coverPath: String
    let hasCover: Bool
    let synced: Bool
}

// MARK: - App state

final class AppState: ObservableObject {

    static let shared = AppState()
    static let cliPath = NSHomeDirectory() + "/.local/bin/watchtunes"

    struct Status {
        var libraries: [String] = []
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
    @Published var scannedSongs: [ScannedSong] = []
    @Published var scanLoading = false
    @Published var nowPlaying: ScannedSong?
    @Published var isPlaying = false
    @Published var queue: [ScannedSong] = []
    @Published var queueIndex = 0
    @Published var libraries: [String] = []

    private var audioPlayer: AVAudioPlayer?
    @Published var keepAwake = UserDefaults.standard.bool(forKey: "keepAwake") {
        didSet { UserDefaults.standard.set(keepAwake, forKey: "keepAwake") }
    }

    private var timer: Timer?
    private var pingTimer: Timer?
    private var pendingSync = false
    private var wasReachable = false
    private let workQueue = DispatchQueue(label: "watchtunes.work")

    func start() {
        guard timer == nil else { return }
        cliMissing = !FileManager.default.isExecutableFile(atPath: Self.cliPath)
        refresh()
        loadScan()
        timer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // Keep-awake: a tiny adb no-op every 10s keeps the watch's Wi-Fi from
        // napping. Always on when reachable — the watch's Wi-Fi sleeps when
        // the screen turns off, which kills the adb connection.
        pingTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self, self.status.reachable, !self.syncing else { return }
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
            var libs: [String] = []
            for line in lines {
                guard let eq = line.firstIndex(of: "=") else { continue }
                let key = String(line[..<eq])
                let val = String(line[line.index(after: eq)...])
                switch key {
                case "libraries":   break // count, handled below
                case let k where k.hasPrefix("library_"):
                    libs.append(val)
                case "local":       s.localCount = Int(val) ?? 0
                case "paired":      s.paired = !val.isEmpty
                case "reachable":   s.reachable = (val == "1")
                case "endpoint":    s.endpoint = val
                case "watch":       s.watchCount = Int(val)
                case "player":      s.playerInstalled = (val == "1")
                case "pending":     s.pending = Int(val) ?? 0
                case "battery":     s.battery = Int(val)
                case "free_kb":     s.freeKB = Int64(val)
                case "total_kb":    s.totalKB = Int64(val)
                case "bitrate":     s.bitrate = val
                case "mirror_delete": s.mirrorDelete = (val == "true")
                default: break
                }
            }
            if libs.isEmpty { libs = [NSHomeDirectory() + "/Music/WatchSync"] }
            s.libraries = libs
            if !s.reachable { s.watchCount = nil }
            DispatchQueue.main.async {
                let justReconnected = !self.wasReachable && s.reachable
                self.wasReachable = s.reachable
                self.status = s
                self.libraries = libs
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
                self.loadScan()
                if self.pendingSync { self.pendingSync = false; self.sync() }
            }
        }
    }

    /// Copy dropped files/folders into the first library, then sync.
    func importItems(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let libPath = status.libraries.first ?? (NSHomeDirectory() + "/Music/WatchSync")
        let libURL = URL(fileURLWithPath: libPath, isDirectory: true)
        workQueue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: libURL, withIntermediateDirectories: true)
            let libResolved = libURL.standardizedFileURL.resolvingSymlinksInPath().path
            let audioExts = ["flac", "mp3", "m4a"]
            var copied = 0, skipped = 0, alreadyIn = 0
            for src in urls {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: src.path, isDirectory: &isDir) else { continue }
                let srcPath = src.standardizedFileURL.resolvingSymlinksInPath().path
                if srcPath == libResolved || srcPath.hasPrefix(libResolved + "/") {
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

    func disconnect() {
        guard !cliMissing else { return }
        appendLog("— Verbindung getrennt —")
        workQueue.async {
            self.runCLI(["disconnect"]) { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { self.appendLog(t) }
            }
            DispatchQueue.main.async {
                self.wasReachable = false
                self.status.reachable = false
                self.status.watchCount = nil
                self.status.battery = nil
                self.status.freeKB = nil
                self.status.pending = 0
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

    // MARK: - Scan (replaces loadDiff + loadMeta)

    func loadScan() {
        scanLoading = true
        workQueue.async {
            var songs: [ScannedSong] = []
            self.runCLI(["scan"]) { line in
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                let lib = obj["library"] as? String ?? ""
                let rel = obj["rel"] as? String ?? ""
                let abs = obj["abs"] as? String ?? ""
                guard !rel.isEmpty else { return }
                let libName = (lib as NSString).lastPathComponent
                let song = ScannedSong(
                    library: lib,
                    libraryName: libName,
                    relPath: rel,
                    absPath: abs,
                    artist: obj["artist"] as? String ?? "",
                    album: obj["album"] as? String ?? "",
                    title: obj["title"] as? String ?? "",
                    coverPath: obj["cover"] as? String ?? "",
                    hasCover: obj["has_cover"] as? Bool ?? false,
                    synced: false
                )
                songs.append(song)
            }
            // Determine synced status by comparing with watch songs
            self.runCLI(["list"]) { _ in } // ensure on_watch.list is fresh if reachable
            // Read cached watch list
            let owPath = NSHomeDirectory() + "/.cache/watchtunes/on_watch.list"
            let watchSet: Set<String>
            if let content = try? String(contentsOfFile: owPath, encoding: .utf8) {
                watchSet = Set(content.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            } else {
                watchSet = []
            }
            let finalSongs = songs.map { song -> ScannedSong in
                ScannedSong(library: song.library, libraryName: song.libraryName, relPath: song.relPath,
                            absPath: song.absPath, artist: song.artist, album: song.album,
                            title: song.title, coverPath: song.coverPath, hasCover: song.hasCover,
                            synced: watchSet.contains(song.relPath))
            }
            DispatchQueue.main.async {
                self.scannedSongs = finalSongs
                self.scanLoading = false
            }
        }
    }

    // MARK: - Folder management

    func addFolder(_ path: String) {
        workQueue.async {
            self.runCLI(["addfolder", path]) { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { self.appendLog(t) }
            }
            DispatchQueue.main.async {
                self.refresh()
                self.loadScan()
            }
        }
    }

    func rmFolder(_ path: String) {
        workQueue.async {
            self.runCLI(["rmfolder", path]) { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { self.appendLog(t) }
            }
            DispatchQueue.main.async {
                self.refresh()
                self.loadScan()
            }
        }
    }

    // MARK: - Local preview player

    func previewPlay(_ song: ScannedSong) {
        guard FileManager.default.fileExists(atPath: song.absPath) else { return }
        // Toggle off if same song is playing
        if nowPlaying?.absPath == song.absPath && isPlaying {
            audioPlayer?.pause()
            isPlaying = false
            return
        }
        // Build queue from all loaded songs matching the current context
        if queue.isEmpty || nowPlaying == nil {
            queue = scannedSongs
            queueIndex = queue.firstIndex(where: { $0.absPath == song.absPath }) ?? 0
        } else if nowPlaying?.absPath != song.absPath {
            queueIndex = queue.firstIndex(where: { $0.absPath == song.absPath }) ?? 0
        }
        playFile(song.absPath, song: song)
    }

    private func playFile(_ src: String, song: ScannedSong) {
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: src))
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
            nowPlaying = song
            isPlaying = true
        } catch {
            appendLog("Abspielen fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    func previewPlayNext() {
        guard !queue.isEmpty else { return }
        queueIndex = min(queueIndex + 1, queue.count - 1)
        let next = queue[queueIndex]
        if FileManager.default.fileExists(atPath: next.absPath) {
            playFile(next.absPath, song: next)
        }
    }

    func previewPlayPrev() {
        guard !queue.isEmpty else { return }
        queueIndex = max(queueIndex - 1, 0)
        let prev = queue[queueIndex]
        if FileManager.default.fileExists(atPath: prev.absPath) {
            playFile(prev.absPath, song: prev)
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
    /// deleted directly.
    func removeSong(_ song: ScannedSong) {
        scannedSongs.removeAll { $0.id == song.id }
        workQueue.async {
            let fm = FileManager.default
            if (try? fm.trashItem(at: URL(fileURLWithPath: song.absPath), resultingItemURL: nil)) != nil {
                self.appendLog("In den Papierkorb: \(song.title.isEmpty ? song.relPath : song.title)")
            }
            self.runCLI(["remove", song.relPath]) { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { self.appendLog(t) }
            }
            DispatchQueue.main.async { self.refresh(); self.loadScan() }
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

    func openLibrary(_ path: String) {
        let lib = URL(fileURLWithPath: path, isDirectory: true)
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

// MARK: - Sidebar tree node

struct LibraryNode: Identifiable, Hashable {
    let id: String   // unique key = path
    let name: String // display name
    let libraryPath: String
    let isLibrary: Bool
    var songCount: Int = 0
}

// MARK: - Main window

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var dropTargeted = false
    @State private var showPair = false
    @State private var showSettings = false
    @State private var searchText = ""
    @State private var sortMode: SortMode = .artist
    @State private var showGrid = false
    @State private var selectedNode: String? = nil  // nil = "Alle Bibliotheken"
    @State private var showAddFolder = false
    @State private var manualFolderPath = ""
    @State private var expandedLibs: Set<String> = []

    enum SortMode: String, CaseIterable {
        case artist = "Artist", album = "Album", title = "Titel", date = "Datum"
    }

    // Build tree nodes for sidebar
    private var sidebarNodes: [LibraryNode] {
        var nodes: [LibraryNode] = []
        for lib in state.libraries {
            let libName = (lib as NSString).lastPathComponent
            let count = state.scannedSongs.filter { $0.library == lib }.count
            nodes.append(LibraryNode(id: lib, name: libName, libraryPath: lib, isLibrary: true, songCount: count))
            if expandedLibs.contains(lib) {
                // Album folders under this library
                let albums = state.scannedSongs
                    .filter { $0.library == lib }
                    .map { ($0.relPath as NSString).deletingLastPathComponent }
                let uniqueAlbums = Array(Set(albums)).sorted()
                for album in uniqueAlbums {
                    let albumKey = lib + "/" + album
                    let albumCount = state.scannedSongs.filter { $0.library == lib && ($0.relPath as NSString).deletingLastPathComponent == album }.count
                    nodes.append(LibraryNode(id: albumKey, name: (album as NSString).lastPathComponent, libraryPath: lib, isLibrary: false, songCount: albumCount))
                }
            }
        }
        return nodes
    }

    // Filter songs based on selected node
    private var filteredSongs: [ScannedSong] {
        var songs: [ScannedSong]
        if let sel = selectedNode {
            // Check if it's a library or an album folder
            if let lib = state.libraries.first(where: { $0 == sel }) {
                songs = state.scannedSongs.filter { $0.library == lib }
            } else {
                // It's an album folder: sel = lib/albumPath
                songs = state.scannedSongs.filter { song in
                    let albumPath = (song.relPath as NSString).deletingLastPathComponent
                    return sel == song.library + "/" + albumPath
                }
            }
        } else {
            songs = state.scannedSongs
        }
        // Apply search
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            songs = songs.filter { song in
                song.title.lowercased().contains(q)
                || song.artist.lowercased().contains(q)
                || song.album.lowercased().contains(q)
                || song.relPath.lowercased().contains(q)
            }
        }
        // Apply sort
        return sortedSongs(songs)
    }

    private func sortedSongs(_ songs: [ScannedSong]) -> [ScannedSong] {
        switch sortMode {
        case .artist:
            return songs.sorted { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
        case .album:
            return songs.sorted { $0.album.localizedCaseInsensitiveCompare($1.album) == .orderedAscending }
        case .title:
            return songs.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .date:
            return songs
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if state.statusLoaded && state.status.reachable && !state.status.playerInstalled {
                playerWarning
            }
            toolbar
            // Main content: sidebar + song list
            HStack(spacing: 0) {
                // Left: sidebar with library tree
                sidebar
                Divider()
                // Right: song list
                songListContent
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            if state.nowPlaying != nil {
                miniPlayer
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
            }
        }
        .padding(.top, 16)
        .frame(minWidth: 700, minHeight: 450)
        .background(windowBackground.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showPair) { PairSheet().environmentObject(state) }
        .sheet(isPresented: $showSettings) { SettingsSheet().environmentObject(state) }
        .sheet(isPresented: $showAddFolder) { AddFolderSheet().environmentObject(state) }
        .onAppear {
            state.loadScan()
        }
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
        if state.cliMissing { return "watchtunes-CLI fehlt" }
        if !state.statusLoaded { return "Suche Uhr …" }
        if !state.status.paired { return "Uhr noch nicht gekoppelt" }
        return state.status.reachable ? "Uhr verbunden" : "Uhr nicht erreichbar"
    }

    private var headerSub: String {
        if state.cliMissing { return "Bitte ./install.sh im watchtunes-Repo ausführen" }
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
                Text("WatchTunes")
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
            if state.statusLoaded && state.status.paired && state.status.reachable {
                Button { state.disconnect() } label: {
                    Image(systemName: "applewatch.slash")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Verbindung trennen")
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

    // MARK: player warning

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

    // MARK: sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Sidebar header with +/- buttons
            HStack {
                Text("Bibliotheken")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { showAddFolder = true } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.violet)
                }
                .buttonStyle(.plain)
                .help("Bibliothek hinzufügen")
                if selectedNode != nil && state.libraries.contains(selectedNode!) {
                    Button { state.rmFolder(selectedNode!) } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Bibliothek entfernen")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            // Tree content
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // "Alle Bibliotheken" node
                    sidebarRow(label: "Alle Bibliotheken", count: state.scannedSongs.count,
                               isSelected: selectedNode == nil, icon: "music.note.house",
                               indent: 0) {
                        selectedNode = nil
                    }
                    // Library nodes
                    ForEach(sidebarNodes) { node in
                        sidebarRow(label: node.name, count: node.songCount,
                                   isSelected: selectedNode == node.id,
                                   icon: node.isLibrary ? "folder.fill" : "music.note",
                                   indent: node.isLibrary ? 0 : 12) {
                            selectedNode = node.id
                        }
                        .onTapGesture(count: 2) {
                            if node.isLibrary {
                                if expandedLibs.contains(node.id) {
                                    expandedLibs.remove(node.id)
                                } else {
                                    expandedLibs.insert(node.id)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 200)
        .background(RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.2)))
    }

    private func sidebarRow(label: String, count: Int, isSelected: Bool, icon: String, indent: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Theme.cyan : .secondary)
                Text(label)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.leading, indent)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Theme.cyan.opacity(0.15) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            // Search field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                TextField("Suchen …", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: .capsule)
            .frame(maxWidth: .infinity)

            // Sort picker
            Picker("", selection: $sortMode) {
                ForEach(SortMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .labelsHidden()
            .frame(width: 90)

            // List/Grid toggle
            Button { showGrid.toggle() } label: {
                Image(systemName: showGrid ? "list.bullet" : "square.grid.2x2")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(showGrid ? "Listenansicht" : "Grid-Ansicht")

            // Sync button
            Button { state.sync() } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12))
                    .foregroundStyle(state.syncing ? .secondary : Theme.violet)
            }
            .buttonStyle(.plain)
            .disabled(state.syncing || state.cliMissing)
            .help("Syncen")

            if state.status.pending > 0 {
                Text("\(state.status.pending)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.orange))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    // MARK: - Song list content (right side)

    @ViewBuilder
    private var songListContent: some View {
        let songs = filteredSongs
        Group {
            if state.scanLoading && songs.isEmpty {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.large)
                    Text("Scanne Bibliotheken …")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if songs.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                    if searchText.isEmpty {
                        Text("Keine Songs in der Auswahl")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text("Musik hierher ziehen oder Ordner hinzufügen")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("Keine Treffer")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if showGrid {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 8)], spacing: 8) {
                        ForEach(songs) { song in
                            gridCell(song)
                        }
                    }
                    .padding(8)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(songs) { song in
                            songRow(song)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.2)))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(dropTargeted ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.clear), lineWidth: 2)
                .animation(.easeOut(duration: 0.15), value: dropTargeted)
        )
    }

    private func gridCell(_ song: ScannedSong) -> some View {
        VStack(spacing: 3) {
            ZStack {
                if song.hasCover, let img = NSImage(contentsOfFile: song.coverPath) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.accent.opacity(0.3))
                        .frame(width: 60, height: 60)
                        .overlay(Image(systemName: "music.note").font(.system(size: 16)).foregroundStyle(.secondary))
                }
                if !song.synced {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .padding(3)
                        .background(Circle().fill(.black.opacity(0.6)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(2)
                }
            }
            .frame(width: 60, height: 60)
            Text(song.title.isEmpty ? (song.relPath as NSString).lastPathComponent : song.title)
                .font(.system(size: 9))
                .lineLimit(1)
                .frame(width: 60)
        }
        .onTapGesture(count: 2) {
            state.previewPlay(song)
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(state.nowPlaying?.absPath == song.absPath ? Theme.cyan.opacity(0.12) : Color.clear)
        )
    }

    private func songRow(_ song: ScannedSong) -> some View {
        let displayName = song.title.isEmpty ? (song.relPath as NSString).lastPathComponent : song.title
        let folder = (song.relPath as NSString).deletingLastPathComponent
        return HStack(spacing: 8) {
            // Cover
            if song.hasCover, let img = NSImage(contentsOfFile: song.coverPath) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Theme.accent.opacity(0.25))
                    .frame(width: 28, height: 28)
                    .overlay(Image(systemName: "music.note").font(.system(size: 10)).foregroundStyle(.secondary))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(.system(size: 11))
                    .lineLimit(1)
                if !song.artist.isEmpty {
                    Text(song.artist)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else if !folder.isEmpty {
                    Text(folder)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            // Play button
            Button { state.previewPlay(song) } label: {
                Image(systemName: state.nowPlaying?.absPath == song.absPath && state.isPlaying
                      ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(state.nowPlaying?.absPath == song.absPath ? Theme.cyan : Color.gray.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("Vorschau")
            // Sync status
            Image(systemName: song.synced ? "checkmark.circle.fill" : "clock.fill")
                .font(.system(size: 10))
                .foregroundStyle(song.synced ? .green : .orange)
            // Remove
            Button { state.removeSong(song) } label: {
                Image(systemName: "trash")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Entfernen")
            .disabled(!state.status.reachable)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(state.nowPlaying?.absPath == song.absPath
                      ? Theme.cyan.opacity(0.12) : Color.clear)
        )
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

    @ViewBuilder
    private var miniPlayer: some View {
        if let song = state.nowPlaying {
            HStack(spacing: 10) {
                // Cover thumbnail
                if song.hasCover, let img = NSImage(contentsOfFile: song.coverPath) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                } else {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Theme.accent.opacity(0.3))
                        .frame(width: 28, height: 28)
                        .overlay(Image(systemName: "music.note").font(.system(size: 10)).foregroundStyle(.secondary))
                }
                // Title + artist
                VStack(alignment: .leading, spacing: 1) {
                    Text(song.title.isEmpty ? (song.relPath as NSString).lastPathComponent : song.title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    if !song.artist.isEmpty {
                        Text(song.artist)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                // Controls: prev, play/pause, next, stop
                Button { state.previewPlayPrev() } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(state.queueIndex <= 0)
                Button { state.previewTogglePause() } label: {
                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                Button { state.previewPlayNext() } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(state.queueIndex >= state.queue.count - 1)
                Button { state.previewStop() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
        }
    }
}

// MARK: - Add Folder Sheet

struct AddFolderSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var manualPath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Theme.accent)
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 32, height: 32)
                Text("Bibliothek hinzufügen")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
            }

            // Local folder picker
            HStack {
                Text("Lokaler Ordner:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Auswählen …") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    panel.prompt = "Hinzufügen"
                    if panel.runModal() == .OK, let url = panel.url {
                        state.addFolder(url.path)
                        dismiss()
                    }
                }
                .buttonStyle(.glass)
            }

            Divider()

            // Network path
            VStack(alignment: .leading, spacing: 6) {
                Text("Netzwerk-Pfad:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("z.B. /Volumes/Music oder smb://server/share", text: $manualPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                Text("Für smb:// Pfade: zuerst im Finder verbinden, dann den /Volumes/ Pfad verwenden.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }
                    .buttonStyle(.glass)
                Button("Hinzufügen") {
                    let p = manualPath.trimmingCharacters(in: .whitespaces)
                    if !p.isEmpty {
                        state.addFolder(p)
                        dismiss()
                    }
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.violet)
                .disabled(manualPath.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .preferredColorScheme(.dark)
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

            // Libraries list
            VStack(alignment: .leading, spacing: 6) {
                Text("Bibliotheken (\(state.libraries.count))")
                    .font(.system(size: 12, weight: .semibold))
                ForEach(state.libraries, id: \.self) { lib in
                    HStack {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.violet)
                        Text(lib)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button { state.rmFolder(lib) } label: {
                            Image(systemName: "minus.circle")
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .help("Entfernen")
                        Button { state.openLibrary(lib) } label: {
                            Image(systemName: "folder")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Im Finder öffnen")
                    }
                    .padding(.vertical, 2)
                }
            }

            Divider()

            HStack(alignment: .firstTextBaseline) {
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
        .frame(width: 420)
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
        Button("Verbindung trennen") { state.disconnect() }
            .disabled(state.cliMissing || !state.status.paired || !state.status.reachable)
        Button("Musik-Ordner öffnen") {
            if let first = state.libraries.first {
                state.openLibrary(first)
            }
        }
        Divider()
        Button("Fenster öffnen") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("WatchTunes beenden") { NSApp.terminate(nil) }
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
struct WatchTunesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(state)
                .onAppear { state.start() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarContent().environmentObject(state)
        } label: {
            MenuBarLabel()
        }
    }
}