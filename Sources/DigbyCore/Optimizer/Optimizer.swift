import Foundation

/// One trial encode of a sample set, with its measured quality.
public struct TrialResult: Sendable {
    public var encoder: EncoderID
    public var params: VideoEncodeParameters
    public var rate: RateControl
    public var encodedSize: PixelSize
    public var kbps: Double
    public var quality: QualityReport
    public var seconds: Double
    /// Frames per second the encoder managed on this trial (for time estimates).
    public var encodeFPS: Double = 0
}

public struct QualitySearchOutcome: Sendable {
    public var value: Double
    public var trial: TrialResult
    public var probes: [TrialResult]
    public var reachedTarget: Bool
    public var cappedBySourceBitrate: Bool
    /// The search stopped early because `giveUp` said it couldn't win.
    public var abandoned = false
}

/// The optimisation engine: trial-encodes samples and measures VMAF to pick
/// settings. Designed to grow — new strategies only need `trial(...)`.
///
/// Objective: maximise perceptual quality subject to size ≤ target
/// (target-size mode), or minimise size subject to quality ≥ level
/// (quality mode). Both are answered from the same trial primitives.
public struct Optimizer: Sendable {
    let tools: ToolPaths
    let workspace: TempWorkspace
    /// (fraction of the optimisation stage 0…1, human-readable detail)
    let onProgress: @Sendable (Double, String) -> Void

    public init(tools: ToolPaths, workspace: TempWorkspace, onProgress: @escaping @Sendable (Double, String) -> Void) {
        self.tools = tools; self.workspace = workspace; self.onProgress = onProgress
    }

    // MARK: primitives

    /// Encode `sample` (which is already at the size the encoder should see),
    /// then measure VMAF against `reference` at `reference.size`.
    public func trial(encoder id: EncoderID, params: VideoEncodeParameters, rate: RateControl,
                      sample: SampleSet, reference: SampleSet) async throws -> TrialResult {
        let enc = EncoderRegistry.encoder(id)
        let out = workspace.file("trial-\(UUID().uuidString.prefix(6)).mkv")
        defer { try? FileManager.default.removeItem(at: out) }
        let run = FFmpegRun(tools: tools)
        let t0 = Date()
        if case .bitrate = rate, enc.supportsTwoPass {
            let log = workspace.file("trialpass-\(UUID().uuidString.prefix(6))").path
            try await run.run(["-i", sample.url.path, "-map", "0:v:0"] + enc.arguments(params, rate: rate, pass: .first(logPrefix: log), threads: nil) + ["-f", "null", "-"],
                              duration: sample.duration)
            try await run.run(["-i", sample.url.path, "-map", "0:v:0"] + enc.arguments(params, rate: rate, pass: .second(logPrefix: log), threads: nil) + [out.path],
                              duration: sample.duration)
        } else {
            try await run.run(["-i", sample.url.path, "-map", "0:v:0"] + enc.arguments(params, rate: rate, pass: .single, threads: nil) + [out.path],
                              duration: sample.duration)
        }
        let secs = Date().timeIntervalSince(t0)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? NSNumber)?.doubleValue ?? 0
        // Score ≤ ~240 frames per trial: pooled VMAF is stable under sub-sampling and
        // this keeps each probe's measurement well under its encode time.
        let frames = reference.duration * reference.fps
        let q = try await QualityMeter(tools: tools).measure(
            reference: reference.url, referenceFilters: nil, distorted: out, size: reference.size, fps: reference.fps,
            subsample: max(1, Int((frames / 240).rounded(.up))), duration: reference.duration, scope: .samples, workspace: workspace)
        let r = TrialResult(encoder: id, params: params, rate: rate, encodedSize: sample.size,
                            kbps: bytes * 8 / max(sample.duration, 0.01) / 1000, quality: q, seconds: secs,
                            encodeFPS: sample.duration * sample.fps / max(secs, 0.01))
        Log.info(String(format: "trial %@ %@ %@ @%@ → %.0f kb/s, VMAF %.2f (p5 %.2f) in %.1fs", id.rawValue, "\(sample.size)",
                        "\(rate)", "preset \(params.speed.label)", r.kbps, q.vmaf, q.vmafP5, secs))
        return r
    }

    // MARK: quality search

    /// Find the most compressed constant-quality value whose sample VMAF ≥ target
    /// (and, optionally, whose bitrate stays under `maxKbps`).
    ///
    /// Works on a normalised "compression axis" c (higher c = smaller file) so
    /// CRF-style and VideoToolbox-style scales are handled identically. The
    /// first steps use a calibrated VMAF-per-unit slope; once a passing and a
    /// failing probe bracket the target, it interpolates. ≤ `maxProbes` encodes.
    public func searchQuality(encoder id: EncoderID, params: VideoEncodeParameters, sample: SampleSet,
                              targetVMAF: Double, initial: Double, maxKbps: Double?, maxProbes: Int = 5,
                              progressBase: Double = 0, progressSpan: Double = 1,
                              giveUp: (@Sendable (TrialResult) -> Bool)? = nil) async throws -> QualitySearchOutcome {
        let scale = EncoderRegistry.encoder(id).qualityScale
        let sign: Double = scale.lowerIsBetter ? 1 : -1
        let limitC = sign * EngineTuning.practicalQualityLimit(id)          // best-quality bound on the c axis
        let slope = EngineTuning.vmafPerUnit(id)
        let maxStep = 5 / slope
        let floorTarget = targetVMAF - 0.25
        func c(_ t: TrialResult) -> Double { sign * value(t) }
        func qualityOK(_ t: TrialResult) -> Bool { t.quality.vmaf >= floorTarget }
        func sizeOK(_ t: TrialResult) -> Bool { maxKbps.map { t.kbps <= $0 } ?? true }
        func quant(_ cc: Double) -> Double { sign * scale.clamp(sign * cc) }

        var probes: [TrialResult] = []
        var nextC = quant(max(limitC, sign * initial))
        for i in 0..<maxProbes {
            try Task.checkCancellation()
            onProgress(progressBase + progressSpan * Double(i) / Double(maxProbes),
                       "Testing quality setting \(Int((sign * nextC).rounded())) on sample scenes (\(i + 1)/\(maxProbes))")
            let t = try await trial(encoder: id, params: params, rate: .quality(sign * nextC), sample: sample, reference: sample)
            probes.append(t)
            if let g = giveUp, g(t) {
                return QualitySearchOutcome(value: value(t), trial: t, probes: probes, reachedTarget: false, cappedBySourceBitrate: false, abandoned: true)
            }
            if qualityOK(t) && sizeOK(t) && t.quality.vmaf - targetVMAF <= 0.5 { break }   // close enough, just above target

            let best = probes.filter { qualityOK($0) && sizeOK($0) }.map(c).max()
            let hiFail = probes.filter { !qualityOK($0) }.map(c).min()                // quality fails at/above this
            let loFail = probes.filter { qualityOK($0) && !sizeOK($0) }.map(c).max()  // too big at/below this
            func vmafAt(_ cc: Double) -> Double { probes.first { c($0) == cc }!.quality.vmaf }
            var candidate: Double
            if let b = best {
                if let h = hiFail {
                    let vb = vmafAt(b), vh = vmafAt(h)
                    let frac = vb > vh ? (vb - targetVMAF) / (vb - vh) : 0.5
                    candidate = quant(b + (h - b) * min(0.85, max(0.15, frac)))
                } else {
                    candidate = quant(b + min(maxStep, max(scale.step, (vmafAt(b) - targetVMAF) / slope)))
                }
            } else if let h = hiFail, let l = loFail {
                candidate = quant((h + l) / 2)                                         // squeezed between both limits
            } else if let h = hiFail {
                candidate = quant(max(limitC, h - min(maxStep, max(scale.step, (targetVMAF - vmafAt(h)) / slope))))
            } else if let l = loFail {
                candidate = quant(l + max(2 * scale.step, min(maxStep, (vmafAt(l) - targetVMAF) / slope)))
            } else { break }
            if probes.contains(where: { c($0) == candidate }) { break }               // converged at quantiser resolution
            if let h = hiFail, candidate >= h { break }
            if let l = loFail, candidate <= l { break }
            nextC = candidate
        }

        let passing = probes.filter { qualityOK($0) && sizeOK($0) }
        let chosen: TrialResult
        if let b = passing.max(by: { c($0) < c($1) }) {
            chosen = b                                                    // most compressed that passes
        } else if maxKbps != nil, let f = probes.filter(sizeOK).max(by: { $0.quality.vmaf < $1.quality.vmaf }) {
            chosen = f                                                    // best quality that stays under the cap
        } else {
            chosen = probes.max(by: { $0.quality.vmaf < $1.quality.vmaf })!
        }
        return QualitySearchOutcome(value: value(chosen), trial: chosen, probes: probes,
                                    reachedTarget: qualityOK(chosen),
                                    cappedBySourceBitrate: probes.contains { qualityOK($0) && !sizeOK($0) })
    }

    private func value(_ t: TrialResult) -> Double { if case .quality(let v) = t.rate { return v }; return 0 }

    /// The search ran with a faster preset. Check its answer with the real preset (one trial),
    /// and move it by the measured offset if the real preset lands away from the target (one more).
    public func calibrate(_ o: QualitySearchOutcome, encoder id: EncoderID, params: VideoEncodeParameters, sample: SampleSet,
                          targetVMAF: Double, maxKbps: Double?) async throws -> QualitySearchOutcome {
        let scale = EncoderRegistry.encoder(id).qualityScale
        let floor = targetVMAF - 0.25
        var best = try await trial(encoder: id, params: params, rate: .quality(o.value), sample: sample, reference: sample)
        var value = o.value
        let gap = best.quality.vmaf - (targetVMAF + 0.2)
        if abs(gap) > 0.6 {
            let units = max(-4, min(4, gap / EngineTuning.vmafPerUnit(id)))
            let v2 = scale.clamp(scale.lowerIsBetter ? value + units : value - units)
            if v2 != value, EngineTuning.practicalQualityLimit(id) <= (scale.lowerIsBetter ? v2 : 1000) {
                let t2 = try await trial(encoder: id, params: params, rate: .quality(v2), sample: sample, reference: sample)
                let ok1 = best.quality.vmaf >= floor && (maxKbps.map { best.kbps <= $0 } ?? true)
                let ok2 = t2.quality.vmaf >= floor && (maxKbps.map { t2.kbps <= $0 } ?? true)
                // the most compressed that reaches the target; otherwise the better one
                if (ok2 && (!ok1 || t2.kbps < best.kbps)) || (!ok1 && !ok2 && t2.quality.vmaf > best.quality.vmaf) { best = t2; value = v2 }
            }
        }
        Log.info(String(format: "calibrated %@: proxy value %.1f → %.1f (VMAF %.2f with the final preset)", id.rawValue, o.value, value, best.quality.vmaf))
        return QualitySearchOutcome(value: value, trial: best, probes: o.probes + [best], reachedTarget: best.quality.vmaf >= floor,
                                    cappedBySourceBitrate: o.cappedBySourceBitrate)
    }

    // MARK: lower-resolution sample

    /// Downscale an existing sample (cheap) for "would a lower resolution look better?" checks.
    public func downscaled(_ s: SampleSet, to size: PixelSize) async throws -> SampleSet {
        let out = workspace.file("samples-\(size.width)x\(size.height).mkv")
        try await FFmpegRun(tools: tools).run([
            "-i", s.url.path, "-vf", "scale=\(size.width):\(size.height):flags=lanczos+accurate_rnd+full_chroma_int,format=yuv420p10le",
            "-c:v", "ffv1", "-level", "3", "-slices", "16", "-g", "1", out.path], duration: s.duration)
        return SampleSet(url: out, duration: s.duration, size: size, fps: s.fps, isWholeVideo: s.isWholeVideo)
    }
}

extension EngineTuning {
    /// Test the media engine only when the software encode would take at least this long
    /// (below it, the extra sample encodes and VMAF runs cost more than they save).
    public static let hardwareMinimumSavingSeconds: Double = 20

    /// How much larger (at equal measured quality) a media-engine encode may be and still be
    /// picked for its speed. "Smallest file" only accepts a near-tie.
    public static func hardwareSizeAllowance(_ p: OutputPriority) -> Double { p == .smallestFile ? 0.03 : 0.10 }

    /// Trial encodes run one preset step faster than the real encode (at most "balanced"):
    /// constant-quality values give nearly the same quality across presets, and slower presets
    /// only make the file a little smaller, so the search stays accurate at a fraction of the time.
    public static func searchProxy(_ p: VideoEncodeParameters, encoder: EncoderID) -> VideoEncodeParameters {
        guard !encoder.isHardware, p.speed > .balanced else { return p }
        var q = p
        q.speed = .balanced
        return q
    }

    /// Never search below this quality value: beyond it files balloon for no
    /// visible gain (and can exceed the source).
    public static func practicalQualityLimit(_ e: EncoderID) -> Double {
        switch e {
        case .svtav1, .vp9: return 16
        case .x265, .x264: return 14
        case .vtHEVC, .vtH264: return 88
        }
    }
}
