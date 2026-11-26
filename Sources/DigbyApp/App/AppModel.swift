import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DigbyCore

/// Application state: the engine, the queue of videos and preferences.
@MainActor @Observable
final class AppModel {
    static weak var shared: AppModel?

    enum EngineState { case loading, ready(CompressionEngine), failed(String) }

    var engineState: EngineState = .loading
    var items: [QueueItem] = []
    var selection: QueueItem.ID?
    var prefs = Preferences.load()
    var alert: AlertInfo?
    /// Videos left out when a folder was added (shown as a banner with "Add Anyway").
    var skipNotice: SkipNotice?
    /// Videos waiting for the user to confirm "Replace originals".
    var replaceConfirmation: [QueueItem]?
    /// Unfinished videos from the previous session (stopped by closing, or failed), not yet resumed or removed.
    var resumeOffer: [SavedQueue.Entry]?
    /// The summary shown once after reopening, when the last session left work undone.
    var lastSession: LastSessionReport?
    /// The batch in progress or just finished.
    var batch: BatchRecord?
    var showBatchReport = false

    /// Jobs run in two lanes: software encoders (which share the CPU cores and memory) and the
    /// Apple Silicon media engine alongside them, since it barely touches the CPU. Each lane runs
    /// up to `slots(_:)` jobs at once.
    enum Lane: Hashable { case software, mediaEngine }
    private var workers: [Lane: Int] = [:]
    /// Software jobs at once: one per ~5 performance-class cores and ~6 GB of memory (4K encodes plus
    /// VMAF need 2–3 GB each), at most 3. Several jobs overlap the single-threaded stages (analysis,
    /// sampling, VMAF, muxing) with encoding. `DIGBY_JOBS` overrides it.
    static let softwareSlots: Int = {
        if let n = ProcessInfo.processInfo.environment["DIGBY_JOBS"].flatMap(Int.init), n > 0 { return n }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let gb = Int(ProcessInfo.processInfo.physicalMemory >> 30)
        return max(1, min(3, cores / 5, gb / 6))
    }()
    /// Media-engine jobs at once: Max and Ultra chips have two or more encode engines.
    static let mediaEngineSlots: Int = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        let chip = String(cString: buf)
        return chip.contains("Ultra") ? 4 : chip.contains("Max") ? 2 : 1
    }()
    static func slots(_ lane: Lane) -> Int { lane == .software ? softwareSlots : mediaEngineSlots }
    static func lane(_ s: CompressionSettings) -> Lane {
        (s.priority == .fastest || s.advanced.preferHardware || (s.advanced.encoder?.isHardware ?? false)) ? .mediaEngine : .software
    }
    private var inspectQueue: [QueueItem] = []
    private var inspecting = 0
    private var activity: NSObjectProtocol?

    struct AlertInfo: Identifiable { let id = UUID(); var title: String; var message: String }
    struct SkipNotice: Identifiable {
        let id = UUID()
        var added: Int
        var skipped: [(url: URL, reason: VideoScanner.SkipReason)]
        var summary: String {
            let outputs = skipped.filter { $0.reason == .digbyOutput }.count
            let copies = skipped.count - outputs
            var parts: [String] = []
            if outputs > 0 { parts.append("\(outputs) already compressed by Digby") }
            if copies > 0 { parts.append("\(copies) with a compressed copy next to \(copies == 1 ? "it" : "them")") }
            return "Added \(added) video\(added == 1 ? "" : "s"). Skipped \(skipped.count): " + parts.joined(separator: ", ") + "."
        }
    }

    init() { AppModel.shared = self }

    var engine: CompressionEngine? { if case .ready(let e) = engineState { return e }; return nil }
    var selected: QueueItem? { items.first { $0.id == selection } }
    var isBusy: Bool { items.contains { $0.isActive } }
    var canCompressSelected: Bool { selected.map { $0.source != nil && !$0.pendingVersions.isEmpty } ?? false }
    var compressibleItems: [QueueItem] { items.filter { $0.source != nil && !$0.pendingVersions.isEmpty } }

    func start() async {
        guard engine == nil else { return }
        do {
            engineState = .ready(try await CompressionEngine.make())
            for item in items where item.source == nil { scheduleInspect(item) }
        } catch {
            engineState = .failed(error.localizedDescription)
        }
        if let saved = SavedQueue.load() { openLastSession(saved) }
    }

    /// Reads what the last session left behind: builds the summary, tidies half-written files and
    /// encoders a force quit left running, and tells Digby Video Downloader about its stopped videos.
    func openLastSession(_ saved: SavedQueue) {
        let fm = FileManager.default
        if let e = engine, e.tools.ffmpeg.path.hasPrefix(Bundle.main.bundlePath + "/") { Leftovers.stopOrphans(of: e.tools.ffmpeg.path) }
        var entries = saved.entries
        var rows: [LastSessionItem] = []
        var folders = Set<URL>()
        for i in entries.indices {
            entries[i].key = "\(i)"
            let e = entries[i]
            guard var o = e.outcome ?? (e.pending ? .stopped : nil) else { continue }
            let exists = fm.fileExists(atPath: e.url.path)
            var reason = e.note
            if o == .stopped {
                reason = e.wasRunning == true ? "Was being compressed" : e.wasRunning == false ? "Was waiting its turn" : "Stopped when Digby closed"
                let dir = destination(for: e.url)
                folders.formUnion([dir, e.url.deletingLastPathComponent(),
                                   dir.appendingPathComponent(e.url.deletingPathExtension().lastPathComponent + " versions")])
            }
            if (o == .stopped || o == .failed) && !exists {
                o = .failed; reason = "The video is no longer in \(e.url.deletingLastPathComponent().lastPathComponent)"
            }
            var name = e.url.lastPathComponent
            if entries.filter({ $0.url == e.url }).count > 1 { name += " (\(e.settings.versionLabel(macDecodesAV1: macDecodesAV1)))" }
            rows.append(LastSessionItem(id: "\(i)", name: name, outcome: o, reason: reason, canResume: exists && (o == .stopped || o == .failed)))
        }
        for f in folders { Leftovers.sweepPartials(in: f) }
        let report = LastSessionReport(items: rows, noun: "video")
        guard report.worthShowing else { SavedQueue.clear(); return }
        let open = Set(rows.filter(\.canResume).map(\.id))
        resumeOffer = entries.filter { open.contains($0.key ?? "") }
        lastSession = report
        for e in entries where e.handoffSetting != nil && rows.contains(where: { $0.id == e.key && $0.outcome == .stopped }) {
            reportHandoff(e, .cancelled, note: "Stopped when Digby Video Compressor closed. Resume it there to finish.")
        }
    }

    // MARK: adding

    func add(urls: [URL], skipExisting: Bool = true, settings: CompressionSettings? = nil) {
        let scan = VideoScanner.scan(urls, skipExisting: skipExisting)
        var firstNew: QueueItem?
        var added = 0
        for u in scan.videos where !items.contains(where: { $0.url.standardizedFileURL == u.standardizedFileURL }) {
            var s = settings ?? prefs.settings
            let ticket = HandoffTicket.take(for: u)
            if let g = ticket?.goal { s.goal = g }
            let item = QueueItem(url: u, settings: s)
            if let t = ticket {
                item.autoStart = true; item.replaceOriginal = t.replaceOriginal
                item.handoffSetting = HandoffResult.setting(for: t.goal)
            }
            items.append(item)
            added += 1
            if firstNew == nil { firstNew = item }
            scheduleInspect(item)
        }
        if let f = firstNew { selection = f.id }
        if !scan.skipped.isEmpty { skipNotice = SkipNotice(added: added, skipped: scan.skipped) }
        if scan.videos.isEmpty && scan.skipped.isEmpty && !urls.isEmpty {
            alert = AlertInfo(title: scan.foldersScanned > 0 ? "No videos found" : "Not a video",
                              message: scan.foldersScanned > 0 ? "The folder doesn’t contain any video files Digby can open."
                                  : "Digby Video Compressor can open MP4, MOV, MKV, WebM, AVI and most other video files.")
        }
        saveQueue()
    }

    func addSkippedAnyway() {
        guard let n = skipNotice else { return }
        skipNotice = nil
        add(urls: n.skipped.map(\.url), skipExisting: false)
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie, .avi] + ["mkv", "webm"].compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "Add"
        panel.message = "Choose videos, or folders to add every video inside them (subfolders included)."
        if panel.runModal() == .OK { add(urls: panel.urls) }
    }

    /// Analysis runs two videos at a time, so dropping a folder of hundreds stays responsive.
    func scheduleInspect(_ item: QueueItem) {
        guard engine != nil else { return }
        inspectQueue.append(item)
        pumpInspections()
    }

    private func pumpInspections() {
        while inspecting < 2, !inspectQueue.isEmpty {
            let item = inspectQueue.removeFirst()
            guard items.contains(where: { $0.id == item.id }) else { continue }
            inspecting += 1
            Task {
                await inspect(item)
                inspecting -= 1
                pumpInspections()
            }
        }
    }

    func inspect(_ item: QueueItem) async {
        guard let engine else { return }
        item.inspectError = nil
        do {
            let src = try await engine.inspect(item.url)
            item.source = src
            if item.settings.advanced.profile == nil { item.detectedKind = src.analysis.kind }
            item.thumbnail = try? await FrameGrabber(tools: engine.tools).frame(item.url, at: min(src.media.duration * 0.15, 30), maxDimension: 960)
            if item.autoStart {
                item.autoStart = false
                enqueue(item, remember: false)
                report(item, .compressing)
            } else if item.id == selection { ensureEstimate(item) }
        } catch {
            item.inspectError = error.localizedDescription
            if item.autoStart { item.autoStart = false; report(item, .failed, note: "Couldn’t read the video: \(error.localizedDescription)") }
        }
    }

    func remove(_ item: QueueItem) {
        if item.isActive { item.cancel() }
        item.estimateTask?.cancel()
        items.removeAll { $0.id == item.id }
        if selection == item.id { selection = items.first?.id }
        saveQueue()
    }

    func clearFinished() {
        items.removeAll { $0.isFinished }
        if selected == nil { selection = items.first?.id }
        saveQueue()
    }

    // MARK: settings

    /// Copy one video's settings to every video in the list (or only `targets`), except
    /// per-video content-type overrides. Videos already compressing keep theirs.
    func applySettings(_ s: CompressionSettings, to targets: [QueueItem]? = nil) -> Int {
        var n = 0
        for item in targets ?? items where item.current.isEditable {
            let profile = item.settings.advanced.profile
            let edits = item.settings.edits          // trim, crop… belong to each video
            item.settings = s
            item.settings.advanced.profile = profile
            item.settings.edits = edits
            n += 1
        }
        prefs.settings = s.withoutEdits
        prefs.save()
        saveQueue()
        return n
    }

    func apply(_ preset: Preset, to targets: [QueueItem]?) {
        prefs.selectedPresetID = preset.id
        if let list = preset.versions, list.count > 1 {
            for item in targets ?? items where !item.isActive {
                let edits = item.settings.edits
                item.setVersions(list.map { var c = $0; c.edits = edits; return c })
            }
            prefs.settings = list[0].withoutEdits; prefs.save(); saveQueue()
        } else {
            _ = applySettings(preset.settings, to: targets)
        }
    }

    /// Give other videos the same set of versions as `item` (finished versions stay).
    @discardableResult
    func applyVersions(of item: QueueItem, to targets: [QueueItem]? = nil) -> Int {
        let list = item.versions.map(\.settings.withoutEdits)
        var n = 0
        for t in targets ?? items where t.id != item.id && !t.isActive {
            let edits = t.settings.edits
            t.setVersions(list.map { var c = $0; c.edits = edits; return c }); n += 1
        }
        saveQueue()
        return n + 1
    }

    func savePreset(named name: String, from s: CompressionSettings, versions: [CompressionSettings]? = nil) {
        var p = Preset(name: name, settings: s.withoutEdits)
        if let v = versions, v.count > 1 { p.versions = v.map { var c = $0.withoutEdits; c.advanced.profile = nil; return c } }
        p.settings.advanced.profile = nil
        prefs.presets.append(p)
        prefs.selectedPresetID = p.id
        prefs.save()
    }

    func deletePreset(_ p: Preset) {
        prefs.presets.removeAll { $0.id == p.id }
        if prefs.selectedPresetID == p.id { prefs.selectedPresetID = nil }
        prefs.save()
    }

    // MARK: versions

    /// Another version of the same video, selected for editing.
    @discardableResult
    func addVersion(to item: QueueItem, settings: CompressionSettings? = nil, purpose: String? = nil) -> OutputVersion {
        let v = item.addVersion(settings ?? item.settings, purpose: purpose)
        item.appliedNote = nil
        saveQueue()
        return v
    }

    var macDecodesAV1: Bool { engine?.caps.systemDecodesAV1 ?? false }

    // MARK: estimates

    /// Refine the instant estimate in the background (only while no software encode is using the
    /// CPU). Quick: one light sample search per video, every other choice scaled from it.
    /// Accurate: a light search at exactly the chosen settings, redone (debounced) when they change.
    /// Exact: the full search the compression runs, cached so compressing reuses it.
    /// The panel shows the instant figure meanwhile, so nothing here ever blocks the UI.
    func ensureEstimate(_ item: QueueItem) {
        guard let engine, let source = item.source, !softwareBusy else { return }
        let accuracy = prefs.estimateAccuracy
        var s = item.settings
        if accuracy == .quick, case .targetSize = s.goal { s.goal = .quality(.balanced) }
        switch item.estimate {
        case .none, .failed: break
        case .running: if item.estimateFor == s { return }
        case .ready(let a):
            if accuracy == .quick || (a.settings == s && (a.exact || accuracy != .exact)) { return }
        }
        guard let plan = try? engine.plan(source, settings: s) else { return }
        item.estimateTask?.cancel()
        if case .ready = item.estimate {} else { item.estimate = .running }
        item.estimateFor = s
        item.estimateRefining = true
        let exact = accuracy == .exact
        let debounce = accuracy != .quick
        item.estimateTask = Task {
            if debounce { try? await Task.sleep(for: .milliseconds(700)) }
            guard !Task.isCancelled else { return }
            do {
                let ws = try TempWorkspace(label: "estimate")
                defer { ws.remove() }
                let e = try await engine.evaluate(source, settings: s, workspace: ws, exact: exact) { _, _ in }
                guard !Task.isCancelled else { return }
                item.estimate = .ready(.init(settings: s, plan: plan, evaluation: e, exact: exact))
            } catch {
                if Task.isCancelled { return }
                if case .ready = item.estimate {} else { item.estimate = .failed }
            }
            item.estimateRefining = false
            item.estimateFor = nil
        }
    }

    // MARK: queue

    func compressSelected() { if let s = selected { requestCompress([s]) } }
    func compressAll() { requestCompress(compressibleItems) }
    func cancelSelected() { selected?.cancel() }

    /// Start (or queue) every version still to make for these videos, asking first when
    /// originals will be replaced.
    func requestCompress(_ list: [QueueItem]) {
        let ready = list.filter { $0.source != nil && !$0.pendingVersions.isEmpty }
        guard !ready.isEmpty else { return }
        if prefs.outputMode == .replaceOriginals {
            if let multi = ready.first(where: \.hasVersions) {
                alert = AlertInfo(title: "Several versions can’t replace one original",
                                  message: "“\(multi.name)” has \(multi.versions.count) versions, but only one file can take the original’s place. Remove the extra versions, or choose “Save Next to the Original”.")
                return
            }
            replaceConfirmation = ready; return
        }
        for i in ready { enqueue(i) }
    }

    /// Compress just one version of a video.
    func requestCompress(_ v: OutputVersion, of item: QueueItem) {
        guard item.source != nil, v.isEditable else { return }
        if prefs.outputMode == .replaceOriginals { requestCompress([item]); return }
        enqueue(item, only: [v])
    }

    func confirmReplace() {
        let list = replaceConfirmation ?? []
        replaceConfirmation = nil
        for i in list { enqueue(i) }
    }

    /// - Parameter remember: make these the settings for the next video (not for Downloader hand-offs,
    ///   whose choice is made in the Downloader and shouldn't change this app's own defaults).
    func enqueue(_ item: QueueItem, only: [OutputVersion]? = nil, remember: Bool = true) {
        let list = (only ?? item.pendingVersions).filter(\.isEditable)
        guard item.source != nil, !list.isEmpty else { return }
        if remember {
            prefs.settings = item.versions[0].settings
            prefs.save()
        }
        // estimates would compete with a software encoder for the CPU
        if list.contains(where: { Self.lane($0.settings) == .software }) {
            for i in items where i.estimateRefining {
                i.estimateTask?.cancel(); i.estimateRefining = false; i.estimateFor = nil
                if case .running = i.estimate { i.estimate = .none }
            }
        }
        for v in list { v.job = .queued }
        saveQueue()
        startRunner()
    }

    /// Resume All: every video stopped by closing (`keys` nil), or just the rows given (Resume / Try Again).
    func resumeSavedQueue(_ keys: [String]? = nil) {
        guard let offer = resumeOffer else { return }
        let stopped = Set(lastSession?.resumable.map(\.id) ?? [])
        let entries = offer.filter { keys?.contains($0.key ?? "") ?? stopped.contains($0.key ?? "") }
        resumeOffer = offer.filter { e in !entries.contains { $0.key == e.key } }
        lastSession?.items.removeAll { r in entries.contains { $0.key == r.id } }
        var seen: [URL: QueueItem] = [:]
        for e in entries {
            if let item = seen[e.url] { item.addVersion(e.settings, select: false); continue }
            let existing = items.first { $0.url.standardizedFileURL == e.url.standardizedFileURL }
            add(urls: [e.url], skipExisting: false, settings: e.settings)
            guard let item = items.first(where: { $0.url.standardizedFileURL == e.url.standardizedFileURL }) else { continue }
            seen[e.url] = item
            if let h = e.handoffSetting { item.handoffSetting = h; item.replaceOriginal = e.replaceOriginal ?? false }
            if existing != nil { item.addVersion(e.settings, select: false) }
            // queued as soon as it has been read (now, if it already was)
            if item.source != nil { Task { @MainActor in self.enqueue(item, remember: false); self.report(item, .compressing) } }
            else { item.autoStart = true }
        }
        closeLastSessionIfDone()
        saveQueue()
    }

    /// Remove one row of the summary without resuming it.
    func removeFromLastSession(_ key: String) {
        if let e = resumeOffer?.first(where: { $0.key == key }) {
            reportHandoff(e, .cancelled, note: "Removed in Digby Video Compressor")
            resumeOffer?.removeAll { $0.key == key }
        }
        lastSession?.items.removeAll { $0.id == key }
        closeLastSessionIfDone()
        saveQueue()
    }

    /// Dismiss: forget what wasn't resumed.
    func dismissResume() {
        for e in resumeOffer ?? [] { reportHandoff(e, .cancelled, note: "Not resumed in Digby Video Compressor") }
        resumeOffer = nil; lastSession = nil; SavedQueue.clear(); saveQueue()
    }

    private func closeLastSessionIfDone() {
        if lastSession?.worthShowing != true { lastSession = nil }
        if lastSession == nil, resumeOffer?.isEmpty == true { resumeOffer = nil }
    }

    /// The hand-off note for a saved entry (videos sent by Digby Video Downloader only).
    private func reportHandoff(_ e: SavedQueue.Entry, _ state: HandoffResult.State, note: String) {
        guard let setting = e.handoffSetting else { return }
        HandoffResult(file: e.url.standardizedFileURL.path, state: state, setting: setting, note: note).write()
    }

    /// On quit: videos sent by the Downloader that are being compressed are reported as stopped there
    /// (reopening this app resumes them and reports again).
    func reportStoppedHandoffs() {
        for i in items where i.handoffSetting != nil && i.isActive {
            report(i, .cancelled, note: "Stopped when Digby Video Compressor quit. Open it to resume.")
        }
    }

    private func startRunner() {
        if workers.values.reduce(0, +) == 0 {
            if batch == nil || batch?.finished != nil { batch = BatchRecord(started: Date(), outputMode: prefs.outputMode) }
            // Keep the Mac awake (the display may sleep) until the queue is empty.
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                             reason: "Compressing videos")
        }
        for lane in [Lane.software, .mediaEngine] {
            var waiting = queuedCount(lane)
            while workers[lane, default: 0] < Self.slots(lane) && waiting > 0 {
                workers[lane, default: 0] += 1; waiting -= 1
                Task { [weak self] in
                    while let self, let next = self.nextQueued(lane) {
                        next.1.job = .running(.idle)          // claim it before another worker can
                        await self.run(next.0, next.1)
                        self.saveQueue()
                    }
                    self?.workerFinished(lane)
                }
            }
        }
    }

    var softwareBusy: Bool { workers[.software, default: 0] > 0 }
    /// Jobs running now.
    var runningCount: Int { workers.values.reduce(0, +) }

    private func workerFinished(_ lane: Lane) {
        workers[lane, default: 1] -= 1
        if lane == .software, workers[.software, default: 0] == 0, let s = selected { ensureEstimate(s) }
        if workers.values.reduce(0, +) == 0 { runnerFinished() }
    }

    private func nextQueued(_ lane: Lane) -> (QueueItem, OutputVersion)? {
        for i in items { for v in i.versions { if case .queued = v.job, Self.lane(v.settings) == lane { return (i, v) } } }
        return nil
    }
    private var queuedCount: Int { items.reduce(0) { $0 + $1.versions.filter { if case .queued = $0.job { return true }; return false }.count } }
    private func queuedCount(_ lane: Lane) -> Int {
        items.reduce(0) { $0 + $1.versions.filter { if case .queued = $0.job { return Self.lane($0.settings) == lane }; return false }.count }
    }

    /// Batch progress on the Dock icon: finished jobs plus the running ones, over all jobs in the batch.
    func updateDock() {
        let running = items.flatMap(\.versions).compactMap { v -> Double? in if case .running(let p) = v.job { return p.fraction }; return nil }
        let done = batch?.entries.count ?? 0
        let total = done + running.count + queuedCount
        DockProgress.shared.set((Double(done) + running.reduce(0, +)) / Double(max(1, total)))
    }

    private func runnerFinished() {
        DockProgress.shared.set(nil)
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        guard var b = batch else { return }
        b.finished = Date()
        batch = b
        if b.entries.count >= 2 {
            showBatchReport = true
            if prefs.notifyWhenDone { Notifier.post(title: "Batch finished", body: b.headline) }
        }
        if !items.contains(where: { $0.isActive }) { SavedQueue.clear() }
        if let s = selected { ensureEstimate(s) }
    }

    private func run(_ item: QueueItem, _ version: OutputVersion) async {
        guard let engine, let source = item.source else { version.job = .failed("Not ready"); return }
        let mode = item.replaceOriginal ? .replaceOriginals : prefs.outputMode
        let dest = destination(for: item)
        let label: String? = item.hasVersions ? version.settings.versionLabel(macDecodesAV1: macDecodesAV1) : nil
        version.job = .running(.idle)
        let estimated = item.timeEstimate(for: version.settings, engine: engine)?.seconds
        let started = Date()
        let settings = version.settings
        let throttle = Throttle()
        let task = Task.detached(priority: .userInitiated) { () -> Result<CompressionResult, Error> in
            do {
                var r = try await engine.compress(source, settings: settings, destinationDirectory: dest, versionLabel: label) { p in
                    guard throttle.allow(p) else { return }
                    Task { @MainActor in
                        if case .running = version.job { version.job = .running(p) }
                        AppModel.shared?.updateDock()
                    }
                }
                if mode == .replaceOriginals {
                    do {
                        let o = try await OriginalReplacer(tools: engine.tools).replace(
                            original: source.media, compressed: r.outputURL,
                            expectAudio: !source.media.audio.isEmpty && r.audioSummary != AudioPlan.none.summary, expectedDuration: r.duration)
                        r.outputURL = o.finalURL
                        r.trashedOriginal = o.trashedOriginal
                        r.notes.insert("Original moved to the Trash. The compressed file took its place\(o.finalURL.lastPathComponent == source.media.url.lastPathComponent ? "" : " as \(o.finalURL.lastPathComponent)").", at: 0)
                        if let n = o.note { r.notes.append(n) }
                    } catch {
                        r.warnings.insert("The original was kept: \(error.localizedDescription)", at: 0)
                    }
                }
                return .success(r)
            } catch { return .failure(error) }
        }
        version.runningTask = task
        let result = await task.value
        version.runningTask = nil
        switch result {
        case .success(let r):
            version.job = .done(r)
            if let e = estimated, e > 0 { batch?.timing[Self.lane(settings), default: BatchTiming()].record(estimated: e, actual: Date().timeIntervalSince(started)) }
            prefs.totalSavedBytes += max(0, r.originalBytes - r.outputBytes)
            prefs.save()
            batch?.entries.append(.init(item: item, version: version, result: r))
            if prefs.notifyWhenDone && (batch?.entries.count ?? 0) < 2 && queuedCount == 0 {
                Notifier.notify(r)
            }
            Self.announce("\(item.name) compressed: \(Fmt.bytes(r.outputBytes)), \(Int((r.reduction * 100).rounded())) percent smaller" +
                          (r.quality.map { ", quality \($0.rating.rawValue)" } ?? "") + ".")
        case .failure(let e):
            if case DigbyError.notWorthIt(let why) = e {
                version.job = .skipped(why)
                batch?.entries.append(.init(item: item, version: version, status: .skipped, note: why))
            } else if (e as? DigbyError) == .cancelled || Task.isCancelled || version.cancelRequested {
                version.job = .cancelled
                batch?.entries.append(.init(item: item, version: version, status: .cancelled, note: "Cancelled"))
            } else {
                version.job = .failed(e.localizedDescription)
                batch?.entries.append(.init(item: item, version: version, status: .failed, note: e.localizedDescription))
                Self.announce("\(item.name) couldn’t be compressed. \(e.localizedDescription)")
            }
        }
        version.cancelRequested = false
        switch version.job {
        case .done(let r): report(item, .done, result: r)
        case .skipped(let why): report(item, .skipped, note: why)
        case .failed(let why): report(item, .failed, note: why)
        case .cancelled: report(item, .cancelled, note: "Cancelled in Digby Video Compressor")
        default: break
        }
    }

    /// Tell Digby Video Downloader what happened to a video it sent (nothing for any other video).
    private func report(_ item: QueueItem, _ state: HandoffResult.State, result r: CompressionResult? = nil, note: String? = nil) {
        guard let setting = item.handoffSetting else { return }
        var h = HandoffResult(file: item.url.standardizedFileURL.path, state: state, setting: setting, note: note)
        if let r {
            h.output = r.outputURL.standardizedFileURL.path
            h.originalBytes = r.originalBytes
            h.outputBytes = r.outputBytes
            h.format = "\(r.codec.rawValue) · \(r.outputSize.width)×\(r.outputSize.height)"
            h.quality = r.quality?.rating.rawValue
            h.vmaf = r.quality?.vmaf
            h.originalTrashed = r.trashedOriginal != nil
            if !h.originalTrashed, item.replaceOriginal { h.note = r.warnings.first { $0.hasPrefix("The original was kept") } }
        }
        h.write()
    }

    /// Tell VoiceOver users what happened without moving their focus.
    static func announce(_ text: String) {
        NSAccessibility.post(element: NSApp.mainWindow as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Where results go: the source's folder by default (and in Replace mode), or the chosen
    /// folder. Falls back to ~/Movies if the source folder isn't writable.
    func destination(for source: URL) -> URL {
        if prefs.outputMode == .folder, let f = prefs.outputFolder, FileManager.default.isWritableFile(atPath: f.path) { return f }
        let dir = source.deletingLastPathComponent()
        if FileManager.default.isWritableFile(atPath: dir.path) { return dir }
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Digby Video Compressor")
        try? FileManager.default.createDirectory(at: movies, withIntermediateDirectories: true)
        return movies
    }

    /// As above, inside "<name> versions" when the video has several versions and that option is on.
    func destination(for item: QueueItem, create: Bool = true) -> URL {
        let base = destination(for: item.url)
        guard item.hasVersions, prefs.versionsInOwnFolder, prefs.outputMode != .replaceOriginals else { return base }
        let sub = base.appendingPathComponent(item.url.deletingPathExtension().lastPathComponent + " versions", isDirectory: true)
        if create { try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true) }
        return sub
    }

    func saveQueue() {
        var entries = items.flatMap { i in i.versions.map { v in
            SavedQueue.Entry(url: i.url, settings: v.settings, pending: v.job.isActive, outcome: Self.outcome(v.job), note: Self.note(v.job),
                             wasRunning: v.job.isActive ? { if case .running = v.job { return true }; return false }() : nil,
                             handoffSetting: i.handoffSetting, replaceOriginal: i.handoffSetting == nil ? nil : i.replaceOriginal)
        } }
        // what the previous session left, still waiting for an answer, survives another quit
        let offer = resumeOffer ?? []
        entries += offer.filter { e in !items.contains { $0.url.standardizedFileURL == e.url.standardizedFileURL } }.map { var e = $0; e.key = nil; return e }
        if entries.contains(where: \.pending) || !offer.isEmpty { SavedQueue(entries: entries, outputMode: prefs.outputMode).save() }
        else if resumeOffer == nil { SavedQueue.clear() }
    }

    static func outcome(_ j: JobState) -> LastSessionOutcome? {
        switch j {
        case .queued, .running: return .stopped
        case .done, .skipped: return .finished
        case .failed: return .failed
        case .cancelled: return .cancelled
        case .idle: return nil
        }
    }
    static func note(_ j: JobState) -> String? {
        switch j {
        case .skipped(let why): return "Kept as it was: \(why)"
        case .failed(let why): return why
        default: return nil
        }
    }

    /// Undo "Replace originals" for the last batch: originals back from the Trash, copies to the Trash.
    func restoreOriginals() -> (restored: Int, problems: [String]) {
        guard var b = batch else { return (0, []) }
        var n = 0, problems: [String] = []
        for i in b.entries.indices {
            let e = b.entries[i]
            guard let t = e.trashedOriginal, !e.restored, let out = e.outputPath else { continue }
            do {
                try OriginalReplacer.restore(original: URL(fileURLWithPath: e.originalPath), from: t, compressed: URL(fileURLWithPath: out))
                b.entries[i].restored = true; n += 1
            } catch { problems.append("\(e.name): \(error.localizedDescription)") }
        }
        batch = b
        return (n, problems)
    }

    func revealLog() {
        if let u = Log.logFileURL { NSWorkspace.shared.activateFileViewerSelecting([u]) }
    }
}

/// What happened to each video in a batch, for the summary report and CSV export.
struct BatchRecord {
    /// Estimated vs. actual time of finished jobs, per lane, to refine the time left.
    var timing: [AppModel.Lane: BatchTiming] = [:]
    enum Status: String { case compressed = "Compressed", skipped = "Skipped", failed = "Failed", cancelled = "Cancelled" }
    struct Entry: Identifiable {
        let id = UUID()
        var name: String
        var folder: String
        var status: Status
        var originalBytes: Int64
        var outputBytes: Int64?
        var outputPath: String?
        var vmaf: Double?
        var textAccuracy: Double?
        var seconds: Double?
        var note: String

        var originalPath: String
        var trashedOriginal: URL?
        var restored = false

        @MainActor init(item: QueueItem, version: OutputVersion, result r: CompressionResult) {
            name = Self.name(item, version); folder = item.url.deletingLastPathComponent().path; status = .compressed
            originalPath = item.url.path; trashedOriginal = r.trashedOriginal
            originalBytes = r.originalBytes; outputBytes = r.outputBytes; outputPath = r.outputURL.path
            vmaf = r.quality?.vmaf; textAccuracy = r.textCheck?.accuracy; seconds = r.elapsed
            note = (r.warnings + r.notes.prefix(1)).first ?? ""
        }
        @MainActor init(item: QueueItem, version: OutputVersion, status: Status, note: String) {
            name = Self.name(item, version); folder = item.url.deletingLastPathComponent().path; self.status = status
            originalPath = item.url.path
            originalBytes = item.source?.media.fileSize ?? 0; self.note = note
        }
        var saved: Int64 { outputBytes.map { originalBytes - $0 } ?? 0 }

        @MainActor static func name(_ item: QueueItem, _ v: OutputVersion) -> String {
            guard item.hasVersions else { return item.name }
            return "\(item.name) · \(item.letter(v)): \(v.settings.versionLabel(macDecodesAV1: AppModel.shared?.macDecodesAV1 ?? false))"
        }
    }
    var started: Date
    var finished: Date?
    var outputMode: Preferences.OutputMode
    var entries: [Entry] = []

    var compressed: [Entry] { entries.filter { $0.status == .compressed } }
    var totalOriginal: Int64 { compressed.reduce(0) { $0 + $1.originalBytes } }
    var totalOutput: Int64 { compressed.reduce(0) { $0 + ($1.outputBytes ?? 0) } }
    var saved: Int64 { totalOriginal - totalOutput }
    var headline: String {
        "\(compressed.count) of \(entries.count) videos compressed, \(Fmt.bytes(max(0, saved))) saved"
    }

    var restorable: [Entry] { entries.filter { $0.trashedOriginal != nil && !$0.restored } }

    func csv() -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = ["File,Folder,Status,Original bytes,Compressed bytes,Saved %,VMAF,Text read identically %,Seconds,Output,Note"]
        for e in entries {
            let pct = e.outputBytes.map { String(format: "%.1f", (1 - Double($0) / Double(max(1, e.originalBytes))) * 100) } ?? ""
            lines.append([q(e.name), q(e.folder), e.status.rawValue, "\(e.originalBytes)", e.outputBytes.map { "\($0)" } ?? "", pct,
                          e.vmaf.map { String(format: "%.2f", $0) } ?? "", e.textAccuracy.map { String(format: "%.1f", $0 * 100) } ?? "",
                          e.seconds.map { String(format: "%.0f", $0) } ?? "", q(e.outputPath ?? ""), q(e.note)].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Limits UI updates to ~8 per second (stage changes always pass).
final class Throttle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    private var lastStage: JobStage?
    func allow(_ p: JobProgress) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        if p.stage != lastStage || now.timeIntervalSince(last) > 0.12 { last = now; lastStage = p.stage; return true }
        return false
    }
}
