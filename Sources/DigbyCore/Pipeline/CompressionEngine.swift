import Foundation
import CoreGraphics

/// A source video that has been probed and analysed.
public struct SourceItem: Sendable, Identifiable {
    public let id = UUID()
    public var media: MediaInfo
    public var analysis: ContentAnalysis
    public var effectivelyMono: Bool
    /// Text found by on-device recognition (slides, captions, UI).
    public var text: TextAnalysis = .none
    /// Black bars found around the picture (letterboxing), in display orientation.
    public var blackBars: CropInsets? = nil
    /// The trim has already been applied (so applying it again changes nothing).
    var trimApplied = false

    public init(media: MediaInfo, analysis: ContentAnalysis, effectivelyMono: Bool, text: TextAnalysis = .none, blackBars: CropInsets? = nil) {
        self.media = media; self.analysis = analysis; self.effectivelyMono = effectivelyMono; self.text = text; self.blackBars = blackBars
    }

    /// The video as these edits leave it: only the kept part (times shift so 0 is the trim's start).
    public func applying(_ edits: EditSettings) -> SourceItem {
        guard edits.isTrimmed, media.duration > 0, !trimApplied else { return self }
        let w = edits.window(duration: media.duration)
        var s = self
        s.trimApplied = true
        s.media = media.clipped(start: w.start, duration: w.duration)
        let inside: (Double) -> Bool = { $0 >= w.start && $0 <= w.start + w.duration - 0.5 }
        s.text.moments = text.moments.filter { inside($0.time) }.map { var m = $0; m.time -= w.start; return m }
        s.analysis.demandingMoments = analysis.demandingMoments.filter(inside).map { $0 - w.start }
        return s
    }
}

/// Final encoding decision produced by the optimisation stage.
public struct EncodeDecision: Sendable {
    public enum FinalRate: Sendable, Equatable {
        case constantQuality(Double)
        case twoPass(kbps: Int)            // or single-pass ABR for encoders without 2-pass
    }
    public var encoder: EncoderID
    public var params: VideoEncodeParameters
    public var outputSize: PixelSize
    public var filters: String?
    public var rate: FinalRate
    public var audio: AudioPlan
    public var streams: StreamPlan
    /// Trial result on samples at the chosen settings (Smart / Best Possible).
    public var sampleTrial: TrialResult?
    public var notes: [String]
    public var warnings: [String]
    /// Text legibility measured on sample moments at the chosen settings.
    public var textCheck: TextLegibilityReport? = nil
    /// OCR agreement of a near-lossless encode of the same moments (the 100 % mark).
    public var textCeiling: TextLegibilityReport? = nil
    /// Extra size the text guard added on samples (fraction, e.g. 0.12 = +12 %).
    public var textGuardCost: Double? = nil
    /// The perceptual target the decision aims for (quality modes).
    public var targetVMAF: Double? = nil
    /// Measure the finished file and re-encode once if it misses the target (hardware encoders).
    public var correctAfterEncode = false
    /// Set when the media engine was picked automatically because it passed the same checks.
    public var hardwareChoice: HardwareChoice? = nil
}

/// Why the Apple media engine was used instead of the software encoder.
public struct HardwareChoice: Sendable, Codable, Hashable {
    public var software: EncoderID
    public var hardware: EncoderID
    public var softwareKbps: Double
    public var hardwareKbps: Double
    public var vmaf: Double
    /// How much faster the media engine encoded the samples.
    public var speedup: Double
    public var sizeDifference: Double { softwareKbps > 0 ? hardwareKbps / softwareKbps - 1 : 0 }
    public var summary: String {
        let size = abs(sizeDifference) < 0.01 ? "the same size" :
            String(format: "%.0f%% %@", abs(sizeDifference) * 100, sizeDifference > 0 ? "larger" : "smaller")
        return String(format: "Used the Apple media engine: it passed the same quality (VMAF %.1f) and text checks as %@ at %@, and encodes about %.0f× faster.",
                      vmaf, software.rawValue, size, max(1, speedup))
    }
}

public struct CompressionResult: Sendable, Codable {
    public var outputURL: URL
    public var sourceURL: URL
    public var originalBytes: Int64
    public var outputBytes: Int64
    public var targetBytes: Int64?
    public var outputSize: PixelSize
    public var codec: VideoCodec
    public var encoder: EncoderID
    public var speedLabel: String
    public var tenBit: Bool
    public var videoKbps: Int
    public var audioSummary: String
    public var duration: Double
    public var quality: QualityReport?
    public var sampleQuality: QualityReport?
    public var elapsed: Double
    public var notes: [String]
    public var warnings: [String]
    public var settingsSummary: String
    /// Text legibility of the finished file (when the text guard was active).
    public var textCheck: TextLegibilityReport? = nil
    public var textGuardActive: Bool = false
    /// Plays in Finder's Quick Look / QuickTime on this Mac.
    public var previewableOnThisMac: Bool = true
    /// Where the original went when it was replaced (so it can be restored).
    public var trashedOriginal: URL? = nil
    /// The original's picture size, to say when detail was reduced ("720p, was 4K").
    public var sourceSize: PixelSize? = nil
    /// What came along besides the picture ("2 audio tracks · subtitles (English) · chapters · date & place recorded").
    public var kept: String? = nil
    /// What had to be left out, and why.
    public var dropped: [String]? = nil
    /// The original's length, when only part of it was kept.
    public var trimmedFrom: Double? = nil
    /// Where the kept part starts in the original, and the picture filters used (to line up comparisons).
    public var clipStart: Double? = nil
    public var filters: String? = nil
    /// The media engine was picked automatically because it passed the same checks.
    public var hardwareChoice: HardwareChoice? = nil

    /// The output has noticeably fewer pixels than the original (the quality rating doesn't include that).
    public var reducedDetail: Bool { sourceSize.map { outputSize.shortSide < $0.shortSide * 9 / 10 } ?? false }

    public var reduction: Double { originalBytes > 0 ? 1 - Double(outputBytes) / Double(originalBytes) : 0 }
    public var metTarget: Bool? { targetBytes.map { outputBytes <= $0 } }
}

/// The engine façade used by the app and the CLI.
public final class CompressionEngine: Sendable {
    public let tools: ToolPaths
    public let caps: FFmpegCapabilities
    let decisionCache = DecisionCache()

    public init(tools: ToolPaths, caps: FFmpegCapabilities) { self.tools = tools; self.caps = caps }

    public static func make() async throws -> CompressionEngine {
        let tools = try ToolLocator.locate()
        let caps = try await ToolLocator.capabilities(of: tools)
        Log.info("FFmpeg: \(caps.version); SVT-AV1 \(caps.hasSVTAV1), x265 \(caps.hasX265), x264 \(caps.hasX264), VT \(caps.hasVTHEVC), VMAF \(caps.hasVMAF)")
        TempWorkspace.sweepStale()
        return CompressionEngine(tools: tools, caps: caps)
    }

    // MARK: inspection

    public func inspect(_ url: URL) async throws -> SourceItem {
        let media = try await MediaProbe(tools: tools).probe(url)
        async let analysis = ContentAnalyzer(tools: tools).analyze(media)
        async let mono = AudioAnalyzer(tools: tools).isEffectivelyMono(media)
        async let text = TextAnalyzer(tools: tools).analyze(media)
        async let bars = BlackBarDetector(tools: tools).detect(media)
        return SourceItem(media: media, analysis: try await analysis, effectivelyMono: await mono, text: await text, blackBars: await bars)
    }

    public func plan(_ item: SourceItem, settings: CompressionSettings) throws -> EncodePlan {
        let item = item.applying(settings.edits)
        return try EncodePlanner.plan(media: item.media, analysis: item.analysis, settings: settings, caps: caps,
                               effectivelyMono: item.effectivelyMono, text: item.text)
    }

    // MARK: decision (optimisation)

    /// - Parameter light: shorter samples and fewer probes (Preview Studio and estimates). The
    ///   real compression always runs the full search.
    func decide(_ item: SourceItem, plan: EncodePlan, settings: CompressionSettings, workspace: TempWorkspace,
                tracker: ProgressTracker, light: Bool = false) async throws -> EncodeDecision {
        var d = EncodeDecision(encoder: plan.encoder, params: plan.params, outputSize: plan.outputSize, filters: plan.filterChain,
                               rate: .constantQuality(0), audio: plan.audio, streams: plan.streams, sampleTrial: nil, notes: plan.notes, warnings: plan.warnings)
        let media = item.media
        let canMeasure = caps.hasVMAF

        func buildSamples() async throws -> SampleSet {
            let key = "\(item.id)|\(media.clipStart)|\(media.duration)|\(plan.filterChain ?? "")|\(plan.outputSize)|\(light)|\(workspace.url.path)"
            if let cached = await decisionCache.sample(key) { tracker.update(.sampling, 1); return cached }
            tracker.update(.sampling, 0, detail: "Extracting representative scenes")
            let s = try await SampleBuilder(tools: tools).build(media: media, filters: plan.filterChain, outputSize: plan.outputSize,
                                                                fps: plan.params.frameRate, totalSeconds: light ? 8 : (media.duration > 300 ? 16 : 12), workspace: workspace,
                                                                label: "samples-\(UUID().uuidString.prefix(4))")
            await decisionCache.setSample(key, s)
            tracker.update(.sampling, 1)
            return s
        }
        let optimiser = Optimizer(tools: tools, workspace: workspace) { f, detail in tracker.update(.optimising, f, detail: detail) }
        // Re-compressing an already-compressed file must not make it bigger.
        let sourceVideoKbps = media.video.bitrate.map { Double($0) / 1000 }
        let isMezzanine = ["prores", "dnxhd", "ffv1", "rawvideo", "huffyuv", "utvideo", "v210", "qtrle", "png"].contains(media.video.codec)
        let pixelRatio = (Double(plan.outputSize.pixels) / Double(max(1, media.video.codedSize.pixels))).squareRoot().clamped(0.5, 1)
        let sizeCap: Double? = (sourceVideoKbps != nil && !isMezzanine) ? sourceVideoKbps! * 0.85 * pixelRatio : nil

        switch plan.rate {
        case .fixedQuality(let v):
            d.rate = .constantQuality(v)

        case .searchQuality(let target, let guess):
            guard canMeasure else { d.rate = .constantQuality(guess); d.notes.append("VMAF unavailable: used predicted settings."); break }
            if plan.encoder.isHardware && plan.depth == .smart {
                // The media engine encodes in seconds, so measuring the real file and correcting it
                // once is faster (and more accurate) than searching on samples.
                d.rate = .constantQuality(guess); d.targetVMAF = target; d.correctAfterEncode = true
                break
            }
            let samples = try await buildSamples()
            var outcomes: [(EncoderID, VideoEncodeParameters, QualitySearchOutcome)] = []
            let candidates = plan.depth == .bestPossible ? bestPossibleCandidates(plan) : [plan.encoder]
            for (i, enc) in candidates.enumerated() {
                var p = plan.params
                if enc != plan.encoder { p = paramsFor(enc, base: plan.params, settings: settings, duration: media.duration) }
                let g = enc == plan.encoder ? guess : EngineTuning.initialQuality(enc, levelFor(target), kind: p.profile, synthetic: p.synthetic)
                let proxy = EngineTuning.searchProxy(p, encoder: enc)
                var o = try await optimiser.searchQuality(encoder: enc, params: proxy, sample: samples, targetVMAF: target, initial: g,
                                                          maxKbps: sizeCap, maxProbes: light ? 3 : 5, progressBase: Double(i) / Double(candidates.count),
                                                          progressSpan: 1 / Double(candidates.count))
                if proxy != p && !light {
                    tracker.update(.optimising, Double(i + 1) / Double(candidates.count) * 0.95, detail: "Confirming the setting with the final encoder preset")
                    o = try await optimiser.calibrate(o, encoder: enc, params: p, sample: samples, targetVMAF: target, maxKbps: sizeCap)
                }
                outcomes.append((enc, p, o))
            }
            // Smallest bitrate among encoders that reached the target; prefer earlier (more efficient / preferred) on near-ties.
            let reached = outcomes.filter { $0.2.reachedTarget }
            let pool = reached.isEmpty ? outcomes : reached
            var best = pool[0]
            for o in pool.dropFirst() where o.2.trial.kbps < best.2.trial.kbps * 0.97 { best = o }
            if reached.isEmpty { best = outcomes.max { $0.2.trial.quality.vmaf < $1.2.trial.quality.vmaf }! }
            d.encoder = best.0; d.params = best.1; d.rate = .constantQuality(best.2.value); d.sampleTrial = best.2.trial
            d.targetVMAF = target
            if outcomes.count > 1 {
                let summary = outcomes.map { "\($0.0.codec.rawValue) \(Int($0.2.trial.kbps)) kbps" }.joined(separator: " vs ")
                d.notes.append("Compared on samples at equal quality: \(summary). Chose \(best.0.codec.rawValue).")
            }
            // ---- the Apple media engine as a candidate: same samples, same VMAF target, same text check.
            var usedHardware = false
            if best.2.reachedTarget, let hw = hardwareCandidate(plan, settings: settings, software: best.0, light: light) {
                let swEncodeSeconds = media.duration * plan.params.frameRate / max(1, best.2.trial.encodeFPS)
                if swEncodeSeconds >= EngineTuning.hardwareMinimumSavingSeconds {
                    var hp = paramsFor(hw, base: best.1, settings: settings, duration: media.duration)
                    hp.speed = settings.advanced.speed ?? .balanced
                    tracker.update(.optimising, 0.8, detail: "Testing the Apple media engine on the same scenes")
                    let allowance = EngineTuning.hardwareSizeAllowance(settings.priority)
                    let swKbps = best.2.trial.kbps
                    // Stop after a probe that already shows it can't win: too big while short of the
                    // target (it needs more data still), or far too big while near it.
                    let limit = swKbps * (1 + allowance)
                    let ho = try await optimiser.searchQuality(encoder: hw, params: hp, sample: samples, targetVMAF: target,
                                                               initial: EngineTuning.initialQuality(hw, levelFor(target), kind: hp.profile, synthetic: hp.synthetic),
                                                               maxKbps: sizeCap, maxProbes: light ? 3 : 4, progressBase: 0.8, progressSpan: 0.1,
                                                               giveUp: { t in t.kbps > limit && (t.quality.vmaf < target || (t.quality.vmaf < target + 2 && t.kbps > limit * 1.3)) })
                    var verdict: String
                    if ho.abandoned {
                        verdict = String(format: "needed far more data for the same quality (%.0f%% more on its first try)", (ho.trial.kbps / swKbps - 1) * 100)
                    } else if !ho.reachedTarget {
                        verdict = String(format: "didn’t reach the quality target (VMAF %.1f)", ho.trial.quality.vmaf)
                    } else if ho.trial.kbps > swKbps * (1 + allowance) {
                        verdict = String(format: "needed %.0f%% more data for the same quality", (ho.trial.kbps / swKbps - 1) * 100)
                    } else {
                        var hd = d
                        hd.encoder = hw; hd.params = hp; hd.rate = .constantQuality(ho.value); hd.sampleTrial = ho.trial
                        if plan.textGuard.active && !plan.textGuard.moments.isEmpty {
                            try await guardText(item, plan: plan, decision: &hd, samples: samples, optimiser: optimiser, tracker: tracker)
                        }
                        let textOK = hd.textCheck.map { $0.accuracy >= TextLegibility.requiredAccuracy } ?? true
                        let hdKbps = hd.sampleTrial?.kbps ?? ho.trial.kbps
                        if !textOK {
                            verdict = "didn’t keep small text readable"
                        } else if hdKbps > swKbps * (1 + allowance) {
                            verdict = String(format: "needed %.0f%% more data to keep small text readable", (hdKbps / swKbps - 1) * 100)
                        } else {
                            let speedup = ho.trial.encodeFPS / max(1, best.2.trial.encodeFPS)
                            hd.hardwareChoice = HardwareChoice(software: best.0, hardware: hw, softwareKbps: swKbps, hardwareKbps: hdKbps,
                                                               vmaf: ho.trial.quality.vmaf, speedup: speedup)
                            hd.notes.append(hd.hardwareChoice!.summary)
                            d = hd; usedHardware = true
                            verdict = ""
                        }
                    }
                    if !usedHardware {
                        d.notes.append("The Apple media engine was tested too but \(verdict), so \(best.0.rawValue) was used.")
                    }
                }
            }
            if !usedHardware && plan.textGuard.active && !plan.textGuard.moments.isEmpty {
                try await guardText(item, plan: plan, decision: &d, samples: samples, optimiser: optimiser, tracker: tracker)
            }
            if !best.2.reachedTarget {
                if best.2.cappedBySourceBitrate {
                    d.notes.append("The original is already efficiently compressed; quality was capped so the result stays smaller than it.")
                } else {
                    d.notes.append(String(format: "This footage tops out around VMAF %.1f even at very high bitrates (common with noisy or already-compressed sources).", best.2.trial.quality.vmaf))
                }
            }

        case .targetSize(let bytes, let kbps0):
            var kbps = kbps0
            guard plan.depth != .quick, canMeasure else { d.rate = .twoPass(kbps: kbps); break }
            let samples = try await buildSamples()
            // Candidate (encoder, resolution) pairs.
            var sizes = [plan.outputSize]
            if plan.allowLowerResolution, let lower = OutputResolution.stepDown(from: plan.outputSize) {
                let sensible = Double(SizeMath.minimumSensibleKbps(size: plan.outputSize, fps: plan.params.frameRate, codec: plan.encoder.codec))
                    * min(3, max(0.1, item.analysis.complexity))
                let tight = Double(kbps) < sensible * 2
                if plan.depth == .bestPossible || tight { sizes.append(lower) }
                // very tight: also try two steps down
                if Double(kbps) < sensible, let lower2 = OutputResolution.stepDown(from: lower) { sizes.append(lower2) }
                // text guard: never scale below the size where the smallest text stays readable
                if plan.textGuard.active, let m = plan.textGuard.minimumShortSide {
                    let before = sizes.count
                    sizes = sizes.filter { $0 == plan.outputSize || $0.shortSide >= m }
                    if sizes.count < before { d.notes.append("Lower resolutions weren’t tried: they would make the smallest text too small to read.") }
                }
            }
            let encoders = plan.depth == .bestPossible ? bestPossibleCandidates(plan) : [plan.encoder]
            var trials: [(TrialResult, PixelSize)] = []
            let total = Double(encoders.count * sizes.count)
            var n = 0.0
            var lowerSamples: [PixelSize: SampleSet] = [:]
            for enc in encoders {
                let p = enc == plan.encoder ? plan.params : paramsFor(enc, base: plan.params, settings: settings, duration: media.duration)
                for size in sizes {
                    tracker.update(.optimising, n / total, detail: "Testing \(enc.codec.rawValue) at \(size.shortSide)p on sample scenes")
                    var s = samples
                    if size != plan.outputSize {
                        if lowerSamples[size] == nil { lowerSamples[size] = try await optimiser.downscaled(samples, to: size) }
                        s = lowerSamples[size]!
                    }
                    var t = try await optimiser.trial(encoder: enc, params: EngineTuning.searchProxy(p, encoder: enc), rate: .bitrate(kbps: kbps), sample: s, reference: samples)
                    t.params = p      // measured with a faster preset; the real encode uses the planned one
                    trials.append((t, size)); n += 1
                }
            }
            // Pick best measured quality; a lower resolution or different codec must win clearly.
            var best = trials[0]
            for t in trials.dropFirst() {
                let margin = (t.1 != plan.outputSize ? 1.0 : 0) + (t.0.encoder != plan.encoder ? 0.4 : 0)
                if t.0.quality.vmaf > best.0.quality.vmaf + margin { best = t }
            }
            d.encoder = best.0.encoder; d.params = best.0.params; d.sampleTrial = best.0
            if trials.count > 1 {
                d.notes.append("Compared on samples at \(kbps) kbps: " + trials.map { String(format: "%@ %dp VMAF %.1f", $0.0.encoder.codec.rawValue, $0.1.shortSide, $0.0.quality.vmaf) }.joined(separator: ", ") + ".")
            }
            if best.1 != plan.outputSize {
                d.outputSize = best.1
                d.filters = Self.replaceScale(in: plan.filterChain, with: best.1)
                d.notes.append("At this size, \(best.1.shortSide)p looks better than \(plan.outputSize.shortSide)p (measured), so the video was scaled to \(best.1).")
                kbps = Int(Double(kbps) * EngineTuning.sizeSafety(d.encoder) / EngineTuning.sizeSafety(plan.encoder))
            }
            d.rate = .twoPass(kbps: kbps)

            // Generous budget? If the target bitrate is already transparent, find the
            // constant-quality setting for "Maximum Quality" and use only what's needed.
            if best.0.quality.vmaf >= QualityLevel.maximum.targetVMAF {
                tracker.update(.optimising, 0.9, detail: "Budget is generous — checking how little space is needed")
                let o = try await optimiser.searchQuality(encoder: d.encoder, params: EngineTuning.searchProxy(d.params, encoder: d.encoder), sample: samples,
                                                          targetVMAF: QualityLevel.maximum.targetVMAF,
                                                          initial: EngineTuning.initialQuality(d.encoder, .maximum, kind: d.params.profile, synthetic: d.params.synthetic),
                                                          maxKbps: Double(kbps) * 0.9, maxProbes: 3, progressBase: 0.9, progressSpan: 0.1)
                if o.reachedTarget {
                    d.rate = .constantQuality(o.value); d.sampleTrial = o.trial
                    d.notes.append("\(Fmt.bytes(bytes)) is more than this video needs: it reaches near-transparent quality with less, so the file will come in under the target.")
                }
            } else if best.0.quality.vmaf < 70 {
                d.warnings.append(String(format: "Measured on samples, quality at this size is low (VMAF %.0f). A larger target or lower resolution will look noticeably better.", best.0.quality.vmaf))
            }
        }
        return d
    }

    /// Text legibility guard (constant-quality modes): encode short clips around the moments with
    /// the smallest text, read the text back with on-device OCR, and raise quality until at least
    /// `TextLegibility.requiredAccuracy` of the characters read identically to the original.
    func guardText(_ item: SourceItem, plan: EncodePlan, decision d: inout EncodeDecision, samples: SampleSet,
                   optimiser: Optimizer, tracker: ProgressTracker) async throws {
        guard case .constantQuality(var v) = d.rate else { return }
        let scale = EncoderRegistry.encoder(d.encoder).qualityScale
        let stepAmount = max(scale.step, (2.5 / EngineTuning.vmafPerUnit(d.encoder) / scale.step).rounded() * scale.step)
        let limit = EngineTuning.practicalQualityLimit(d.encoder)
        var report: TextLegibilityReport? = nil
        var raised = 0
        let ceilingKey = "\(item.id)|\(d.encoder.rawValue)|\(d.filters ?? "")|\(d.outputSize)"
        var ceiling = await decisionCache.ceiling(ceilingKey)
        if ceiling == nil {
            tracker.update(.optimising, 0.9, detail: "Reading on-screen text at near-lossless quality (reference)")
            ceiling = try await textClipCheck(item, decision: d, value: limit, plan: plan, reference: true)
            if let c = ceiling { await decisionCache.setCeiling(ceilingKey, c) }
        }
        d.textCeiling = ceiling
        if let c = ceiling, c.accuracy < TextLegibility.reliableCeiling {
            d.notes.append(String(format: "Text was found, but it can’t be read reliably even at near-lossless quality (%.0f%%: moving or blurred text), so quality wasn’t raised for it.", c.accuracy * 100))
            return
        }
        while true {
            tracker.update(.optimising, 0.92, detail: raised == 0 ? "Checking that text stays readable" : "Raising quality for small text (step \(raised))")
            report = try await textClipCheck(item, decision: d, value: v, plan: plan)?.relative(to: ceiling)
            guard let r = report, r.accuracy < TextLegibility.requiredAccuracy, raised < 3 else { break }
            let next = scale.better(v, by: stepAmount)
            if next == v || (scale.lowerIsBetter ? next < limit : next > limit) { break }
            v = next; raised += 1
        }
        d.textCheck = report
        guard raised > 0 else { return }
        let before = d.sampleTrial?.kbps
        d.rate = .constantQuality(v)
        let t = try await optimiser.trial(encoder: d.encoder, params: d.params, rate: .quality(v), sample: samples, reference: samples)
        d.sampleTrial = t
        if let b = before, b > 0 { d.textGuardCost = t.kbps / b - 1 }
        let cost = d.textGuardCost.map { String(format: " (about %+.0f%% size)", $0 * 100) } ?? ""
        d.notes.append("Quality raised so small text stays readable\(cost).")
        if let r = report, r.accuracy < TextLegibility.requiredAccuracy {
            d.warnings.append(String(format: "Some small text still doesn’t read perfectly (%.0f%% of characters match). A higher resolution would help.", r.accuracy * 100))
        }
    }

    /// Encode 2-second clips around the text moments at `value` and score legibility.
    /// - Parameter reference: the near-lossless "100 %" mark. At that quality the preset makes no visible
    ///   difference, so it is encoded with the fastest one (it used to cost as much as a second full encode).
    func textClipCheck(_ item: SourceItem, decision d: EncodeDecision, value: Double, plan: EncodePlan, reference: Bool = false) async throws -> TextLegibilityReport? {
        let ws = try TempWorkspace(label: "text")
        defer { ws.remove() }
        let enc = EncoderRegistry.encoder(d.encoder)
        let run = FFmpegRun(tools: tools)
        var starts: [Double] = []
        var clips: [URL] = []
        for (i, t) in plan.textGuard.moments.enumerated() {
            // The checked frame sits ~5 s after the clip's keyframe, like most frames of the real
            // encode (a frame right after a keyframe looks better than average and would flatter the check).
            let start = max(0, t - 5)
            let out = ws.file("text-\(i).mkv")
            var a = item.media.inputArgs(from: start, duration: t - start + 0.5) + ["-map", "0:v:0"]
            if let f = d.filters { a += ["-vf", f] }
            var p = d.params
            if reference { p.speed = .fastest; p.filmGrain = 0 }
            try await run.run(a + enc.arguments(p, rate: .quality(value), pass: .single, threads: nil) + ["-an", out.path], duration: t - start + 0.5)
            starts.append(start); clips.append(out)
        }
        let checker = TextLegibilityChecker(tools: tools)
        let g = FrameGrabber(tools: tools)
        let refFilters = d.filters.map(TextLegibilityChecker.withoutScale).flatMap { $0.isEmpty ? nil : $0 }
        var pairs: [([CGImage], CGImage)] = []
        for (i, t) in plan.textGuard.moments.enumerated() {
            let refs = try await checker.referenceFrames(item.media.url, at: item.media.sourceTime(t), fps: d.params.frameRate, size: d.outputSize, filters: refFilters)
            let e = try await g.frame(clips[i], at: t - starts[i], exactSize: d.outputSize)
            pairs.append((refs, e))
        }
        let report = TextLegibilityChecker.score(pairs, smallestLinePx: item.text.smallestLine(at: d.outputSize))
        if let r = report { Log.info(String(format: "text check @%.1f: %.1f%% of %d chars", value, r.accuracy * 100, r.characters)) }
        return report
    }

    /// The hardware encoder worth testing alongside `software` in a quality search, if any:
    /// HEVC (or H.264 when the priority needs H.264) from the media engine, unless the user
    /// picked an encoder, turned the test off, or the search is a quick preview.
    func hardwareCandidate(_ plan: EncodePlan, settings: CompressionSettings, software: EncoderID, light: Bool) -> EncoderID? {
        let adv = settings.advanced
        guard !light, adv.tryHardware, !adv.preferHardware, adv.encoder == nil, !software.isHardware,
              adv.qualityValue == nil, plan.depth != .quick else { return nil }
        let hw = plan.candidates.filter(\.isHardware)
        if let same = hw.first(where: { $0.codec == software.codec }) { return same }
        // AV1 → HEVC is fine (HEVC plays in more places); H.264 priorities never get HEVC.
        if software.codec == .av1, hw.contains(.vtHEVC) { return .vtHEVC }
        return nil
    }

    /// Encoders worth comparing in Best Possible mode (efficient software encoders of the chosen priority).
    func bestPossibleCandidates(_ plan: EncodePlan) -> [EncoderID] {
        var c = [plan.encoder]
        for e in plan.candidates where !e.isHardware && e != plan.encoder && c.count < 2 {
            if plan.encoder == .svtav1 && e == .x265 { c.append(e) }
            if plan.encoder == .x265 && e == .x264 { continue }
        }
        return c
    }

    func paramsFor(_ e: EncoderID, base: VideoEncodeParameters, settings: CompressionSettings, duration: Double) -> VideoEncodeParameters {
        var p = base
        p.speed = settings.advanced.speed ?? EngineTuning.speed(for: settings.goal, duration: duration, encoder: e)
        p.tenBit = EncoderRegistry.encoder(e).supports10Bit && base.tenBit
        if e != .svtav1 { p.filmGrain = 0 }
        p.extraEncoderParams = nil
        return p
    }

    func levelFor(_ vmaf: Double) -> QualityLevel { QualityLevel.allCases.min { abs($0.targetVMAF - vmaf) < abs($1.targetVMAF - vmaf) }! }

    static func replaceScale(in chain: String?, with size: PixelSize) -> String {
        let scale = "scale=\(size.width):\(size.height):flags=lanczos+accurate_rnd+full_chroma_int"
        var parts = (chain ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        if let i = parts.firstIndex(where: { $0.hasPrefix("scale=") }) { parts[i] = scale } else { parts += [scale, "setsar=1"] }
        return parts.joined(separator: ",")
    }

    // MARK: compress

    /// Compress one item. Never touches the source; writes to a hidden partial
    /// file next to the destination and renames it only on success.
    /// - Parameter versionLabel: names the output "<name> (<label>).mp4" (several versions of one video).
    public func compress(_ item: SourceItem, settings: CompressionSettings, destinationDirectory: URL, versionLabel: String? = nil,
                         progress: @escaping @Sendable (JobProgress) -> Void) async throws -> CompressionResult {
        let started = Date()
        let sourceDuration = item.media.duration
        let item = item.applying(settings.edits)
        let media = item.media
        let tracker = ProgressTracker(sink: progress)
        let plan = try self.plan(item, settings: settings)
        let workspace = try TempWorkspace(label: "job")
        defer { workspace.remove() }

        let container = plan.streams.container
        let outURL = try Self.outputURL(for: media.url, in: destinationDirectory, settings: settings, label: versionLabel, container: container)
        let partial = destinationDirectory.appendingPathComponent(".\(outURL.deletingPathExtension().lastPathComponent).digby-partial-\(UUID().uuidString.prefix(6)).\(container.fileExtension)")
        let cleanup = { try? FileManager.default.removeItem(at: partial) }

        // Disk space: output can't be bigger than the source (or target), plus samples.
        // The share of the original this output covers (all of it, unless trimmed).
        let originalShare = Int64(Double(media.fileSize) * min(1, media.duration / max(0.1, sourceDuration)))
        let expected = { () -> Int64 in if case .targetSize(let b) = settings.goal { return b }; return originalShare }()
        if let avail = DiskSpace.available(at: destinationDirectory), avail < expected + 200_000_000 {
            throw DigbyError.insufficientDiskSpace(needed: expected + 200_000_000, available: avail)
        }

        // Stage weights in "seconds of final-encode work".
        let D = media.duration
        let searching: Bool = {
            if case .fixedQuality = plan.rate { return false }
            if case .targetSize = plan.rate { return plan.depth != .quick }
            return !(plan.encoder.isHardware && plan.depth == .smart)
        }()
        let candidates = Double(plan.depth == .bestPossible ? 2 : 1)
        let optimiseCost = searching ? min(D * 1.5, 12 * 2 * candidates) : 0
        let twoPass: Bool = { if case .targetSize = plan.rate { return EncoderRegistry.encoder(plan.encoder).supportsTwoPass }; return false }()
        tracker.configure([(.sampling, searching ? min(D, 20) * 0.3 : 0), (.optimising, optimiseCost), (.encodingAudio, plan.streams.audio.allSatisfy { $0.codec == .none || $0.codec == .copy } ? 0 : D * (settings.edits.normalizeLoudness ? 0.03 : 0.01) * Double(plan.streams.audio.count)),
                           (.firstPass, twoPass ? D * 0.3 : 0), (.encoding, D), (.measuring, settings.measureQuality && caps.hasVMAF ? D * 0.2 : 0),
                           (.finishing, D * 0.01)])

        do {
            var d = try await cachedDecision(item, plan: plan, settings: settings, workspace: workspace, tracker: tracker)
            try Task.checkCancellation()

            // ---- not worth it? (sample prediction; the finished file is checked again below)
            let mustShrink: Bool = { if case .targetSize(let b) = settings.goal { return originalShare > b }; return false }()
            let minSave = mustShrink ? 0 : max(0, settings.minimumSavings)
            if minSave > 0, let t = d.sampleTrial, media.fileSize > 0, D > 0 {
                let predicted = (t.kbps + Double(d.streams.audioKbps)) * 1000 / 8 * D
                let saving = 1 - predicted / Double(max(1, originalShare))
                if saving < minSave * 0.5 {
                    throw DigbyError.notWorthIt(String(format: "Skipped: this video is already efficiently compressed. Re-encoding would save only about %.0f%% (your minimum is %.0f%%), so the original was left as it is.", max(0, saving) * 100, minSave * 100))
                }
            }

            // ---- audio first (every track), so its exact size is known before the video budget is fixed
            var audioInput: URL? = nil
            var audioBytes: Double = 0
            let tracks = d.streams.audio.filter { $0.codec != .none && $0.streamIndex != nil }
            if !tracks.isEmpty {
                tracker.update(.encodingAudio, 0, detail: tracks.count == 1 ? tracks[0].summary : "\(tracks.count) audio tracks")
                var planned = tracks
                for i in planned.indices where planned[i].normalize {
                    tracker.update(.encodingAudio, 0, detail: "Measuring loudness" + (planned.count > 1 ? " (track \(i + 1))" : ""))
                    planned[i].loudnormFilter = try await LoudnessMeter(tools: tools).filter(for: media, streamIndex: planned[i].streamIndex!)
                }
                let a = workspace.file("audio.\(container == .mkv ? "mka" : container.fileExtension)")
                var args = media.inputArgs() + ["-vn", "-sn", "-dn"]
                for (o, t) in planned.enumerated() { args += t.streamArguments(output: o) }
                try await FFmpegRun(tools: tools).run(args + ["-map_metadata", "-1", a.path], duration: D) { tracker.update(.encodingAudio, $0.fraction) }
                audioInput = a
                audioBytes = Double((try? FileManager.default.attributesOfItem(atPath: a.path)[.size] as? NSNumber)?.int64Value ?? 0)
            }
            var targetBytes: Int64? = nil
            if case .targetSize(let bytes) = settings.goal {
                targetBytes = bytes
                if case .twoPass = d.rate {
                    let overhead = SizeMath.containerOverhead(duration: D, fps: d.params.frameRate, hasAudio: audioInput != nil)
                    let video = (Double(bytes) - audioBytes - overhead) * EngineTuning.sizeSafety(d.encoder)
                    let kbps = max(8, Int(video * 8 / max(D, 0.1) / 1000))
                    d.rate = .twoPass(kbps: kbps)
                }
            }

            // ---- video
            let enc = EncoderRegistry.encoder(d.encoder)
            let passlog = workspace.file("pass").path
            var finalKbps: Int? = nil
            var didFirstPass = false
            func encodeArgs(_ rate: RateControl, _ pass: EncodePass, output: String) -> [String] {
                var a = media.inputArgs()
                if let audioInput { a += ["-i", audioInput.path] }
                a += ["-map", "0:v:0"]
                if let f = d.filters { a += ["-vf", f] }
                if media.video.isVariableFrameRate && !(d.filters ?? "").contains("fps=") { a += ["-fps_mode", "passthrough"] }
                a += enc.arguments(d.params, rate: rate, pass: pass, threads: nil)
                if case .first = pass { return a + ["-an", "-sn", "-f", "null", "-"] }
                if audioInput != nil {
                    a += ["-map", "1:a", "-c:a", "copy"]
                    // keep which track plays by default; others stay selectable (languages, commentary)
                    let defaultIndex = media.audio.firstIndex { $0.isDefault }.flatMap { di in tracks.firstIndex { $0.streamIndex == media.audio[di].index } } ?? 0
                    for o in tracks.indices { a += ["-disposition:a:\(o)", o == defaultIndex ? "default" : "0"] }
                    for (o, t) in tracks.enumerated() {
                        if let src = media.audio.first(where: { $0.index == t.streamIndex }) {
                            if let l = src.language { a += ["-metadata:s:a:\(o)", "language=\(l)"] }
                            if let title = src.title { a += ["-metadata:s:a:\(o)", "title=\(title)"] }
                        }
                    }
                }
                for (o, s) in d.streams.subtitles.enumerated() {
                    a += ["-map", "0:\(s.streamIndex)", "-c:s:\(o)", s.codec]
                    var disp: [String] = []
                    if s.isDefault { disp.append("default") }
                    if s.isForced { disp.append("forced") }
                    a += ["-disposition:s:\(o)", disp.isEmpty ? "0" : disp.joined(separator: "+")]
                }
                a += StreamPlanner.metadataArguments(media: media, keep: d.streams.keepMetadata, container: container)
                a += ["-map_chapters", d.streams.keepChapters ? "0" : "-1"]
                if container != .mkv { a += ["-movflags", "+faststart"] }
                a += ["-f", container.ffmpegFormat, output]
                return a
            }
            let run = FFmpegRun(tools: tools)
            switch d.rate {
            case .constantQuality(let v):
                tracker.update(.encoding, 0, detail: "\(d.encoder.codec.rawValue) · \(d.outputSize)")
                try await run.run(encodeArgs(.quality(v), .single, output: partial.path), duration: D) {
                    tracker.update(.encoding, $0.fraction, speed: $0.speed)
                }
            case .twoPass(let kbps):
                finalKbps = kbps
                if enc.supportsTwoPass {
                    tracker.update(.firstPass, 0, detail: "Pass 1 of 2")
                    try await run.run(encodeArgs(.bitrate(kbps: kbps), .first(logPrefix: passlog), output: "-"), duration: D) {
                        tracker.update(.firstPass, $0.fraction, speed: $0.speed)
                    }
                    didFirstPass = true
                }
                tracker.update(.encoding, 0, detail: enc.supportsTwoPass ? "Pass 2 of 2" : nil)
                try await run.run(encodeArgs(.bitrate(kbps: kbps), enc.supportsTwoPass ? .second(logPrefix: passlog) : .single, output: partial.path), duration: D) {
                    tracker.update(.encoding, $0.fraction, speed: $0.speed)
                }
            }

            // ---- size verification (target mode): never silently exceed the target
            if let target = targetBytes {
                var attempt = 0
                var actual = Self.fileSize(partial)
                while actual > target && attempt < 2 {
                    attempt += 1
                    let nonVideo = audioBytes + SizeMath.containerOverhead(duration: D, fps: d.params.frameRate, hasAudio: audioInput != nil)
                    let prevKbps: Int = finalKbps ?? Int((Double(actual) - nonVideo) * 8 / D / 1000)
                    let ratio = (Double(target) * 0.985 - nonVideo) / max(1, Double(actual) - nonVideo)
                    let kbps = max(8, Int(Double(prevKbps) * ratio))
                    Log.warning("output \(actual) B > target \(target) B; re-encoding at \(kbps) kbps (attempt \(attempt))")
                    tracker.addStage(.adjusting, weight: D, after: .encoding)
                    tracker.update(.adjusting, 0, detail: "Slightly over target — tightening")
                    if enc.supportsTwoPass && !didFirstPass {
                        // came from a constant-quality encode: needs a first pass now
                        try await run.run(encodeArgs(.bitrate(kbps: kbps), .first(logPrefix: passlog), output: "-"), duration: D) {
                            tracker.update(.adjusting, $0.fraction * 0.3)
                        }
                        didFirstPass = true
                    }
                    try? FileManager.default.removeItem(at: partial)
                    try await run.run(encodeArgs(.bitrate(kbps: kbps), enc.supportsTwoPass ? .second(logPrefix: passlog) : .single, output: partial.path), duration: D) {
                        tracker.update(.adjusting, 0.3 + $0.fraction * 0.7)
                    }
                    finalKbps = kbps
                    actual = Self.fileSize(partial)
                    d.rate = .twoPass(kbps: kbps)
                }
                if actual > target {
                    d.warnings.append("The result is \(Fmt.bytes(actual - target)) over the target after two corrections.")
                }
            }

            // ---- worth keeping?
            let partialBytes = Self.fileSize(partial)
            if media.fileSize > 0 && !mustShrink {
                let saving = 1 - Double(partialBytes) / Double(max(1, originalShare))
                if saving <= 0 || saving < minSave {
                    cleanup()
                    throw DigbyError.notWorthIt(saving <= 0
                        ? "Skipped: the result wasn’t smaller than the original, so the original was left as it is."
                        : String(format: "Skipped: compressing saved only %.0f%% (your minimum is %.0f%%), so the original was left as it is.", saving * 100, minSave * 100))
                }
            }

            // ---- quality measurement on the real output
            var report: QualityReport? = nil
            func measure(_ detail: String) async -> QualityReport? {
                tracker.update(.measuring, 0, detail: detail)
                let frames = D * d.params.frameRate
                let sub = max(1, Int((frames / 900).rounded(.up)))       // ≤ ~900 scored frames, spread over the whole video
                do {
                    return try await QualityMeter(tools: tools).measure(
                        reference: media.url, referenceInput: QualityMeter.decodeArgs(media.video.codec) + media.inputArgs(),
                        referenceFilters: d.filters, distorted: partial, distortedCodec: d.encoder.codec, size: d.outputSize, fps: d.params.frameRate,
                        subsample: sub, duration: D, scope: .fullVideo, workspace: workspace) { tracker.update(.measuring, $0) }
                } catch { if Task.isCancelled { return nil }; d.warnings.append("Quality measurement failed: \(error.localizedDescription)"); return nil }
            }
            if (settings.measureQuality || d.correctAfterEncode) && caps.hasVMAF {
                report = await measure("Comparing the result with the original (VMAF)")
                try Task.checkCancellation()
                // Hardware encodes: one correction if the file misses its target (or overshoots it a lot).
                if d.correctAfterEncode, let r = report, let target = d.targetVMAF, case .constantQuality(let q) = d.rate,
                   r.vmaf < target - 0.75 || r.vmaf > target + 2.5 {
                    let scale = EncoderRegistry.encoder(d.encoder).qualityScale
                    let step = (target + 0.25 - r.vmaf) / EngineTuning.vmafPerUnit(d.encoder)
                    let q2 = scale.clamp(scale.lowerIsBetter ? q - step : q + step)
                    if q2 != q {
                        tracker.addStage(.adjusting, weight: D * 0.3, after: .measuring)
                        tracker.update(.adjusting, 0, detail: r.vmaf < target ? "Quality a little low — re-encoding one step better" : "Better than needed — re-encoding smaller")
                        let previous = workspace.file("first-try.\(container.fileExtension)")
                        try? FileManager.default.moveItem(at: partial, to: previous)
                        try await run.run(encodeArgs(.quality(q2), .single, output: partial.path), duration: D) { tracker.update(.adjusting, $0.fraction * 0.7) }
                        let r2 = await measure("Checking the corrected file")
                        // keep whichever meets the target with fewer bytes (or the better one if neither does)
                        let firstOK = r.vmaf >= target - 0.75, secondOK = (r2?.vmaf ?? 0) >= target - 0.75
                        if (firstOK && !secondOK) || (firstOK && secondOK && Self.fileSize(previous) < Self.fileSize(partial))
                            || (!firstOK && !secondOK && r.vmaf > (r2?.vmaf ?? 0)) {
                            try? FileManager.default.removeItem(at: partial); try? FileManager.default.moveItem(at: previous, to: partial)
                        } else { report = r2; d.rate = .constantQuality(q2) }
                    }
                }
            }

            // ---- text legibility of the finished file
            var textReport: TextLegibilityReport? = nil
            if !plan.textGuard.moments.isEmpty {
                tracker.update(.measuring, 1, detail: "Checking that on-screen text is readable")
                if d.textCeiling == nil, case let limit = EngineTuning.practicalQualityLimit(d.encoder) {
                    d.textCeiling = try? await textClipCheck(item, decision: d, value: limit, plan: plan, reference: true)
                }
                textReport = try? await TextLegibilityChecker(tools: tools).check(
                    source: media.url, sourceFilters: d.filters, encoded: partial, size: d.outputSize, fps: d.params.frameRate,
                    moments: plan.textGuard.moments.map(media.sourceTime),
                    encodedTime: { $1 - media.clipStart }, smallestLinePx: item.text.smallestLine(at: d.outputSize))?.relative(to: d.textCeiling)
                // With the guard on, the promise is `requiredAccuracy`: anything short of it is said, gently above `warnAccuracy`.
                let warnBelow = plan.textGuard.active ? TextLegibility.requiredAccuracy : TextLegibility.warnAccuracy
                if let r = textReport, r.isReliable, r.accuracy < warnBelow {
                    if r.accuracy >= TextLegibility.warnAccuracy {
                        d.warnings.append(String(format: "Small text reads a little less reliably than Digby aims for: %.0f%% of the characters read the same as the original (aim: %.0f%%). A higher quality level will help.",
                                                 r.accuracy * 100, TextLegibility.requiredAccuracy * 100))
                    } else {
                        d.warnings.append(String(format: "Some small text may be hard to read: %.0f%% of the characters read the same as the original. %@", r.accuracy * 100,
                                                 plan.textGuard.active ? "A higher quality level or resolution will help." : "Turn on “Keep text readable” to protect it."))
                    }
                }
            }

            tracker.update(.finishing, 0)
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: partial, to: outURL)
            DigbyMarker.mark(outURL, summary: Self.describe(d))
            // The copy sorts next to its original in Finder (by date created), like the recording it is.
            if d.streams.keepMetadata, let created = try? media.url.resourceValues(forKeys: [.creationDateKey]).creationDate {
                var v = URLResourceValues(); v.creationDate = created
                var u = outURL; try? u.setResourceValues(v)
            }
            tracker.update(.finishing, 1)

            let outBytes = Self.fileSize(outURL)
            if let t = targetBytes, Double(outBytes) < Double(t) * 0.85, !d.notes.contains(where: { $0.contains("under the target") }) {
                let q = report.map { String(format: " (measured VMAF %.1f)", $0.vmaf) } ?? ""
                d.notes.append("Finished under the target: \(Fmt.bytes(outBytes)) of \(Fmt.bytes(t)). This video reached its quality\(q) without needing the rest — the encoder had nothing useful to spend it on.")
            }
            let vKbps = Int((Double(outBytes) - audioBytes) * 8 / max(D, 0.1) / 1000)
            let result = CompressionResult(
                outputURL: outURL, sourceURL: media.url, originalBytes: media.fileSize, outputBytes: outBytes, targetBytes: targetBytes,
                outputSize: d.outputSize, codec: d.encoder.codec, encoder: d.encoder, speedLabel: d.params.speed.label, tenBit: d.params.tenBit,
                videoKbps: vKbps, audioSummary: d.audio.summary, duration: D, quality: report, sampleQuality: d.sampleTrial?.quality,
                elapsed: Date().timeIntervalSince(started), notes: d.notes, warnings: d.warnings,
                settingsSummary: Self.describe(d), textCheck: textReport ?? d.textCheck, textGuardActive: plan.textGuard.active,
                previewableOnThisMac: EncodePlanner.playsInQuickLook(d.encoder.codec, caps: caps),
                sourceSize: media.displaySize, kept: d.streams.keptSummary(media), dropped: d.streams.dropped,
                trimmedFrom: media.isClipped ? sourceDuration : nil, clipStart: media.isClipped ? media.clipStart : nil, filters: d.filters, hardwareChoice: d.hardwareChoice)
            Log.info("done \(outURL.lastPathComponent): \(Fmt.bytes(outBytes)) (\(String(format: "%.1f", result.reduction * 100))% smaller), \(result.settingsSummary), VMAF \(report.map { String(format: "%.2f", $0.vmaf) } ?? "n/a") in \(Int(result.elapsed)) s")
            return result
        } catch {
            cleanup()
            if Task.isCancelled { throw DigbyError.cancelled }
            throw error
        }
    }

    static func describe(_ d: EncodeDecision) -> String {
        var s = "\(d.encoder.rawValue) \(presetName(d.encoder, d.params.speed)), \(d.params.tenBit ? "10" : "8")-bit"
        switch d.rate {
        case .constantQuality(let v): s += ", constant quality \(Int(v))"
        case .twoPass(let k): s += ", \(k) kbps \(EncoderRegistry.encoder(d.encoder).supportsTwoPass ? "two-pass" : "average")"
        }
        if d.params.filmGrain > 0 { s += ", film grain \(d.params.filmGrain)" }
        return s
    }

    /// The encoder's own name for the effort level ("preset 4", "slow").
    public static func presetName(_ e: EncoderID, _ s: EncoderSpeed) -> String {
        switch e {
        case .svtav1: return "preset \(SVTAV1Encoder.preset(s))"
        case .x265: return "preset \(X265Encoder.preset(s))"
        case .x264: return "preset \(X264Encoder.preset(s))"
        case .vp9: return "cpu-used \(VP9Encoder.cpuUsed(s))"
        case .vtHEVC, .vtH264: return "hardware"
        }
    }

    static func fileSize(_ u: URL) -> Int64 { (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? NSNumber)?.int64Value ?? 0 }

    /// "<name> (compressed).mp4" or "<name> (<label>).mov", made unique; never the source itself.
    public static func outputURL(for source: URL, in dir: URL, settings: CompressionSettings, label: String? = nil,
                                 container: OutputContainer = .mp4) throws -> URL {
        let stem = source.deletingPathExtension().lastPathComponent
        let tag = (label ?? "compressed").replacingOccurrences(of: "/", with: "-")
        let ext = container.fileExtension
        var candidate = dir.appendingPathComponent("\(stem) (\(tag)).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) || candidate.standardizedFileURL == source.standardizedFileURL {
            candidate = dir.appendingPathComponent("\(stem) (\(tag) \(n)).\(ext)"); n += 1
        }
        return candidate
    }
}

extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(hi, Swift.max(lo, self)) }
}
