import Foundation
import DigbyCore
import CoreGraphics

// digby — command-line front end to the Digby Video Compressor engine.
//
//   digby  probe   <file>
//   digby  analyze <file>
//   digby  plan    <file> [options]
//   digby  compress <file|folder> [options] [--out DIR] [--json] [--replace]
//                   A folder is searched recursively; Digby outputs and videos that already
//                   have a compressed copy next to them are skipped.
//   digby  preview <file> [options]        (encode a few seconds with the final settings)
//   digby  estimate <file> [options]       (the app's size/time estimate: light sample search)
//
// Options:
//   --res original|2160|1440|1080|720|480|WxH
//   --quality max|high|balanced|aggressive|min        (default balanced)
//   --target 150MB | 1.2GB                             (overrides --quality)
//   --priority smallest|apple|everywhere|fastest
//   --depth quick|smart|best
//   --audio auto|high|standard|smaller
//   --encoder svtav1|x265|x264|vt-hevc|vt-h264|vp9
//   --vmaf 94                                          (explicit quality target)
//   --speed 0-4  --no-measure  --no-lower-res
//   --text-guard auto|on|off                           (keep text readable; default auto)
//   --smallest                                         (allow AV1 even if this Mac can't preview it)
//   --min-savings 10                                   (percent; 0 = keep any smaller result)
//   --replace                                          (move originals to the Trash, outputs take their names)
//   --jobs 2                                           (folders: compress this many videos at once)
//   --no-hw-candidate                                  (don't test the Apple media engine during the search)

setvbuf(stdout, nil, _IOLBF, 0)

func fail(_ msg: String) -> Never { FileHandle.standardError.write((msg + "\n").data(using: .utf8)!); exit(1) }

var args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else {
    print("usage: digby probe|analyze|plan|compress <file> [options]  (see Sources/digby/main.swift)")
    exit(2)
}
let command = args.removeFirst()
let input = URL(fileURLWithPath: args.removeFirst()).standardizedFileURL

var settings = CompressionSettings()
var outDir = input.deletingLastPathComponent()
var json = false
var jobs = 1
var replace = false
var autoCrop = false
var outGiven = false
var i = 0
func value() -> String { i += 1; guard i < args.count else { fail("missing value for \(args[i - 1])") }; return args[i] }
while i < args.count {
    switch args[i] {
    case "--res":
        let v = value().lowercased()
        switch v {
        case "original": settings.resolution = .original
        case "2160", "4k": settings.resolution = .uhd2160
        case "1440": settings.resolution = .qhd1440
        case "1080": settings.resolution = .fhd1080
        case "720": settings.resolution = .hd720
        case "480": settings.resolution = .sd480
        default:
            let p = v.split(separator: "x").compactMap { Int($0) }
            guard p.count == 2 else { fail("bad --res \(v)") }
            settings.resolution = .custom(width: p[0], height: p[1], keepAspect: true)
        }
    case "--quality":
        let map: [String: QualityLevel] = ["max": .maximum, "high": .high, "balanced": .balanced, "aggressive": .aggressive, "min": .maximumCompression]
        guard let l = map[value()] else { fail("bad --quality") }
        settings.goal = .quality(l)
    case "--target":
        let v = value().uppercased()
        let num = Double(v.trimmingCharacters(in: CharacterSet.letters)) ?? 0
        let mult: Double = v.hasSuffix("GB") ? 1e9 : v.hasSuffix("KB") ? 1e3 : 1e6
        settings.goal = .targetSize(bytes: Int64(num * mult))
    case "--priority":
        let map: [String: OutputPriority] = ["smallest": .smallestFile, "apple": .appleDevices, "everywhere": .playsEverywhere, "fastest": .fastest]
        guard let p = map[value()] else { fail("bad --priority") }
        settings.priority = p
    case "--depth":
        let map: [String: AnalysisDepth] = ["quick": .quick, "smart": .smart, "best": .bestPossible]
        guard let d = map[value()] else { fail("bad --depth") }
        settings.depth = d
    case "--audio":
        let map: [String: AudioQuality] = ["auto": .automatic, "high": .high, "standard": .standard, "smaller": .smaller]
        guard let a = map[value()] else { fail("bad --audio") }
        settings.audio = a
    case "--encoder":
        let map: [String: EncoderID] = ["svtav1": .svtav1, "x265": .x265, "x264": .x264, "vt-hevc": .vtHEVC, "vt-h264": .vtH264, "vp9": .vp9]
        guard let e = map[value()] else { fail("bad --encoder") }
        settings.advanced.encoder = e
    case "--speed":
        guard let s = Int(value()).flatMap(EncoderSpeed.init(rawValue:)) else { fail("bad --speed") }
        settings.advanced.speed = s
    case "--vmaf":
        guard let v = Double(value()) else { fail("bad --vmaf") }
        settings.advanced.targetVMAF = v
        if case .targetSize = settings.goal { fail("--vmaf and --target are exclusive") }
    case "--text-guard":
        guard let m = TextGuardMode(rawValue: value().replacingOccurrences(of: "auto", with: "automatic")) else { fail("bad --text-guard") }
        settings.textGuard = m
    case "--smallest": settings.previewableOnThisMac = false
    case "--min-savings":
        guard let v = Double(value()) else { fail("bad --min-savings") }
        settings.minimumSavings = v / 100
    case "--container":
        let map: [String: ContainerChoice] = ["auto": .automatic, "mp4": .mp4, "mov": .mov, "mkv": .mkv]
        guard let c = map[value()] else { fail("bad --container (auto|mp4|mov|mkv)") }
        settings.advanced.container = c
    case "--trim":
        // --trim 5-20  or  --trim 5-   (seconds)
        let p = value().split(separator: "-", omittingEmptySubsequences: false).map { Double($0) }
        guard p.count == 2 else { fail("bad --trim (start-end)") }
        settings.edits.trimStart = p[0]; settings.edits.trimEnd = p[1]
    case "--crop":
        let v = value()
        if v == "auto" { autoCrop = true } else {
            let n = v.split(separator: ",").compactMap { Int($0) }
            guard n.count == 4 else { fail("bad --crop (auto | top,bottom,left,right)") }
            settings.edits.crop = CropInsets(top: n[0], bottom: n[1], left: n[2], right: n[3])
        }
    case "--rotate":
        guard let r = Int(value()), r % 90 == 0 else { fail("bad --rotate (90, 180, 270)") }
        settings.edits.rotate = r
    case "--flip": settings.edits.flipHorizontal = true
    case "--normalize": settings.edits.normalizeLoudness = true
    case "--sdr": settings.edits.toneMapToSDR = true
    case "--denoise":
        guard let d = DenoiseStrength(rawValue: value().capitalized) else { fail("bad --denoise (light|medium|strong)") }
        settings.edits.denoise = d
    case "--main-audio-only": settings.advanced.audioTracks = .first
    case "--no-subtitles": settings.advanced.keepSubtitles = false
    case "--strip-metadata": settings.advanced.keepMetadata = false
    case "--replace": replace = true
    case "--no-measure": settings.measureQuality = false
    case "--no-lower-res": settings.advanced.allowLowerResolution = false
    case "--no-hw-candidate": settings.advanced.tryHardware = false
    case "--jobs":
        guard let n = Int(value()), n > 0 else { fail("bad --jobs (1 or more)") }
        jobs = n
    case "--out": outDir = URL(fileURLWithPath: value(), isDirectory: true); outGiven = true
    case "--json": json = true
    case "--exact": break                              // estimate: run the full search
    case "--verbose": Log.echoToStderr = true
    default: fail("unknown option \(args[i])")
    }
    i += 1
}

func emit<T: Encodable>(_ v: T) {
    let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try! e.encode(v), as: UTF8.self))
}

func compressOne(_ engine: CompressionEngine, _ file: URL) async throws {
    let item = try await engine.inspect(file)
    var settings = settings
    if autoCrop {
        settings.edits.crop = item.blackBars
        FileHandle.standardError.write("black bars: \(item.blackBars.map { "\($0)" } ?? "none")\n".data(using: .utf8)!)
    }
    let t0 = Date()
    final class Clock: @unchecked Sendable { var last = Date.distantPast; var stage = ""; var stageStart = Date() }
    let clock = Clock()
    // DIGBY_STAGE_LOG=1: one line per stage change with its wall time (for profiling)
    let stageLog = ProcessInfo.processInfo.environment["DIGBY_STAGE_LOG"] != nil
    let dir = outGiven ? outDir : file.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var r = try await engine.compress(item, settings: settings, destinationDirectory: dir) { p in
        let key = p.stage.rawValue + " " + (p.detail ?? "")
        if stageLog, key != clock.stage {
            FileHandle.standardError.write(String(format: "\n[stage] %6.1f s  (prev %5.1f s)  %5.1f%%  %@", Date().timeIntervalSince(t0), Date().timeIntervalSince(clock.stageStart), p.fraction * 100, key).data(using: .utf8)!)
            clock.stage = key; clock.stageStart = Date()
        }
        if Date().timeIntervalSince(clock.last) > 2 || p.stage == .finishing {
            clock.last = Date()
            let eta = p.eta.map { " ETA " + Fmt.eta($0) } ?? ""
            FileHandle.standardError.write(String(format: "\r%5.1f%%  %@ %@%@        ", p.fraction * 100, p.stage.rawValue, p.detail ?? "", eta).data(using: .utf8)!)
        }
    }
    FileHandle.standardError.write("\n".data(using: .utf8)!)
    if replace {
        let o = try await OriginalReplacer(tools: engine.tools).replace(original: item.media, compressed: r.outputURL,
                                                                         expectAudio: !item.media.audio.isEmpty && r.audioSummary != "No audio", expectedDuration: r.duration)
        r.outputURL = o.finalURL
        if let n = o.note { r.notes.append(n) }
        r.notes.append("Original moved to the Trash.")
    }
    if json { emit(r); return }
    print("ORIGINAL     \(Fmt.bytes(r.originalBytes))")
    print("COMPRESSED   \(Fmt.bytes(r.outputBytes))" + (r.targetBytes.map { " (target \(Fmt.bytes($0)))" } ?? ""))
    print(String(format: "REDUCTION    %.1f%%", r.reduction * 100))
    print("RESOLUTION   \(r.outputSize)")
    print("CODEC        \(r.codec.rawValue) — \(r.settingsSummary)")
    print("AUDIO        \(r.audioSummary)")
    if let q = r.quality { print(String(format: "QUALITY      %@ (VMAF %.2f, worst 5%% %.2f, PSNR %.2f dB)", q.rating.rawValue, q.vmaf, q.vmafP5, q.psnr ?? 0)) }
    else { print("QUALITY      not measured") }
    if let t = r.textCheck { print("TEXT         \(t.summary)") }
    print("QUICK LOOK   \(r.previewableOnThisMac ? "plays on this Mac" : "won't play on this Mac (AV1 needs M3 or later)")")
    print(String(format: "TIME         %.0f s", Date().timeIntervalSince(t0)))
    for n in r.notes { print("note: \(n)") }
    for w in r.warnings { print("warning: \(w)") }
    print("→ \(r.outputURL.path)")
}

let task = Task {
    do {
        let engine = try await CompressionEngine.make()
        switch command {
        case "probe":
            emit(try await MediaProbe(tools: engine.tools).probe(input))
        case "analyze":
            let item = try await engine.inspect(input)
            emit(item.analysis)
            emit(item.text)
            print("text: \(item.text.hasText ? item.text.summary : "none detected")")
            print("kind: \(item.analysis.kind.rawValue) (confidence \(String(format: "%.2f", item.analysis.confidence))), complexity \(String(format: "%.2f", item.analysis.complexity)), mono audio: \(item.effectivelyMono)")
        case "plan":
            let item = try await engine.inspect(input)
            let p = try engine.plan(item, settings: settings)
            print("encoder   \(p.encoder.rawValue) [\(p.params.speed.label)], \(p.params.tenBit ? 10 : 8)-bit, profile \(p.params.profile.rawValue), grain \(p.params.filmGrain)")
            print("output    \(p.outputSize)  filters: \(p.filterChain ?? "none")")
            print("rate      \(p.rate)")
            print("audio     \(p.audio.summary)")
            print("text      \(p.textGuard.active ? "guard on" : "guard off") — \(p.textGuard.reason)" +
                  (p.textGuard.minimumShortSide.map { ", keep ≥ \($0)p" } ?? ""))
            print("preview   \(p.previewableOnThisMac ? "plays in Finder Quick Look on this Mac" : "won't play in Quick Look on this Mac")")
            for n in p.notes { print("note      \(n)") }
            for w in p.warnings { print("warning   \(w)") }
        case "estimate":
            // what the settings panel / Preview Studio would show: light sample search + encoded frame
            let item = try await engine.inspect(input)
            let ws = try TempWorkspace(label: "cli-estimate")
            let t0 = Date()
            if let plan = try? engine.plan(item, settings: settings) {
                let level: QualityLevel = { if case .quality(let l) = settings.goal { return l }; return .balanced }()
                let m = item.applying(settings.edits).media
                let kbps = SizeEstimator.instantVideoKbps(media: m, analysis: item.analysis, plan: plan, level: level)
                let bytes = (kbps + Double(plan.streams.audioKbps)) * 125 * m.duration
                print(String(format: "instant      ≈ %@ (video %.0f kbps) in %.1f ms", Fmt.bytes(Int64(bytes)), kbps, Date().timeIntervalSince(t0) * 1000))
            }
            let exact = CommandLine.arguments.contains("--exact")
            let e = try await engine.evaluate(item, settings: settings, workspace: ws, exact: exact) { _, _ in }
            print("estimate     ≈ \(Fmt.bytes(e.predictedBytes)) (\(e.outputSize), \(e.codec.rawValue)) in \(Int(Date().timeIntervalSince(t0))) s")
            print("settings     \(e.summary)")
            print("time         about \(Fmt.eta(e.estimatedSeconds)) to compress")
            if let v = e.sampleVMAF { print(String(format: "VMAF         %.2f on samples", v)) }
            if let t = e.textCheck { print("text         \(t.summary)") }
            let f = try await engine.encodedFrame(item, decision: e.decision, at: item.media.duration * 0.5, workspace: ws)
            print("frame        \(f.width)×\(f.height) encoded with these settings")
            ws.remove()
        case "studio-bench":
            // what Preview Studio does for its three default options, timed
            let item = try await engine.inspect(input)
            let ws = try TempWorkspace(label: "cli-studio")
            let t = item.text.moments.first?.time ?? item.media.duration * 0.3
            var opts = [settings]
            var smaller = settings; smaller.goal = .quality(.aggressive); opts.append(smaller)
            var av1 = settings; av1.previewableOnThisMac = false; av1.priority = .smallestFile; opts.append(av1)
            let t0 = Date()
            for (i, o) in opts.enumerated() {
                let d = try engine.predictedDecision(item, settings: o)
                _ = try await engine.encodedFrame(item, decision: d, at: t, workspace: ws)
                print(String(format: "option %d predicted frame   at %5.1f s", i + 1, Date().timeIntervalSince(t0)))
            }
            for (i, o) in opts.enumerated() {
                let e = try await engine.evaluate(item, settings: o, workspace: ws) { _, _ in }
                _ = try await engine.encodedFrame(item, decision: e.decision, at: t, workspace: ws)
                print(String(format: "option %d measured (%@)  at %5.1f s", i + 1, Fmt.bytes(e.predictedBytes), Date().timeIntervalSince(t0)))
            }
            ws.remove()
        case "ocr-compare":
            // debug: OCR legibility of <file> vs a lossless (FFV1) clip of itself, at the text moments
            let item = try await engine.inspect(input)
            let ws = try TempWorkspace(label: "cli-ocr")
            let g = FrameGrabber(tools: engine.tools)
            var pairs: [(CGImage, CGImage)] = []
            for t in item.text.moments.prefix(4).map(\.time) {
                let start = max(0, t - 5), out = ws.file("ll-\(Int(t)).mkv")
                try await FFmpegRun(tools: engine.tools).run(["-ss", String(format: "%.3f", start), "-t", String(format: "%.3f", t - start + 0.5), "-i", input.path,
                    "-map", "0:v:0", "-c:v", "ffv1", "-an", out.path], duration: 6)
                let a = try await g.frame(input, at: t, exactSize: item.media.displaySize), b = try await g.frame(out, at: t - start, exactSize: item.media.displaySize)
                let ra = OCR.normalisedText(a), rb = OCR.normalisedText(b)
                print(String(format: "t=%.1f  lossless accuracy %.1f%%  (%d chars)", t, OCR.accuracy(reference: ra, candidate: rb) * 100, ra.count))
                pairs.append((a, b))
            }
            ws.remove()
        case "preview":
            let item = try await engine.inspect(input)
            let ws = try TempWorkspace(label: "cli-preview")
            let p = try await engine.preview(item, settings: settings, at: item.media.duration * 0.3, workspace: ws) { f, d in
                FileHandle.standardError.write(String(format: "\r%5.1f%%  %@        ", f * 100, d).data(using: .utf8)!)
            }
            FileHandle.standardError.write("\n".data(using: .utf8)!)
            print("segment      \(Fmt.duration(p.start))–\(Fmt.duration(p.start + p.duration)) at \(p.outputSize)")
            print("settings     \(p.summary)")
            print(String(format: "bitrate      %.0f kbps here", p.kbps))
            if let b = p.predictedBytes { print("predicted    ≈ \(Fmt.bytes(b)) for the whole video") }
            if let q = p.quality { print(String(format: "VMAF here    %.2f (worst 5%% %.2f)", q.vmaf, q.vmafP5)) }
            let grab = FrameGrabber(tools: engine.tools)
            let a = try await grab.frame(p.referenceURL, at: p.duration / 2), b = try await grab.frame(p.encodedURL, at: p.duration / 2)
            print("frames       \(a.width)×\(a.height) original, \(b.width)×\(b.height) compressed decoded OK")
        case "compress":
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: input.path, isDirectory: &isDir)
            let files: [URL]
            if isDir.boolValue {
                let scan = VideoScanner.scan([input])
                for s in scan.skipped { print("skip  \(s.url.path) — \(s.reason.rawValue)") }
                files = scan.videos
                print("\(files.count) videos to compress, \(scan.skipped.count) skipped")
            } else { files = [input] }
            var failures = 0
            let t0 = Date()
            if !isDir.boolValue {
                do { try await compressOne(engine, input) }
                catch DigbyError.notWorthIt(let why) { print("skip  \(input.lastPathComponent) — \(why)") }
            } else {
                // up to `jobs` videos at once
                failures = try await withThrowingTaskGroup(of: Bool.self) { group in
                    var next = 0, failed = 0
                    func add() {
                        let file = files[next]; next += 1
                        group.addTask {
                            do { try await compressOne(engine, file); return true }
                            catch DigbyError.cancelled { throw DigbyError.cancelled }
                            catch DigbyError.notWorthIt(let why) { print("skip  \(file.lastPathComponent) — \(why)"); return true }
                            catch { print("FAILED \(file.lastPathComponent): \(error.localizedDescription)"); return false }
                        }
                    }
                    while next < min(jobs, files.count) { add() }
                    while let ok = try await group.next() {
                        if !ok { failed += 1 }
                        if next < files.count { add() }
                    }
                    return failed
                }
            }
            if files.count > 1 { print(String(format: "batch time %.1f s (%d at once)", Date().timeIntervalSince(t0), jobs)) }
            if files.count > 1 || failures > 0 { print("\(files.count - failures) of \(files.count) done") }
            if failures > 0 { Log.flush(); exit(1) }
        default:
            fail("unknown command \(command)")
        }
        Log.flush()
        exit(0)
    } catch {
        Log.flush()
        fail("error: \(error.localizedDescription)")
    }
}
// Ctrl-C cancels the job through the same path as the app's Cancel button
// (encoders stopped, partial output deleted); a second Ctrl-C exits at once.
signal(SIGINT, SIG_IGN)
var interrupted = false
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler {
    if interrupted { ProcessRegistry.shared.terminateAll(); exit(130) }
    interrupted = true
    FileHandle.standardError.write("\ncancelling…\n".data(using: .utf8)!)
    task.cancel()
}
sigint.resume()
dispatchMain()
