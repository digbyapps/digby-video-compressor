import SwiftUI
import DigbyCore

/// An estimated outcome for one combination of settings on one video.
struct SizeEstimate {
    var bytes: Int64
    var seconds: Double
    /// Measured directly on this video's samples (vs. scaled from a measurement).
    var measured: Bool
    /// What the number rests on, which sets how wide its range is.
    var basis: Basis = .scaled
    /// Likely range: the result should land between these.
    var low: Int64 { Int64(Double(bytes) / basis.spread) }
    var high: Int64 { Int64(Double(bytes) * basis.spread) }

    enum Basis {
        /// From the content analysis and source bitrate alone (instant, no encoding).
        case model
        /// A sample measurement at other settings, scaled by benchmark ratios.
        case scaled
        /// Measured on sample scenes at exactly these settings.
        case sampled
        /// The full search the compression itself runs.
        case exact
        /// Multiplicative half-width of the range (from the benchmark spread of each method).
        var spread: Double {
            switch self { case .model: return 3; case .scaled: return 1.6; case .sampled: return 1.4; case .exact: return 1.1 }
        }
        var help: String {
            switch self {
            case .model: return "Quick estimate from the video’s content and bitrate (no test encode yet) — it can be well off."
            case .scaled: return "Estimated from a test encode of sample scenes, scaled to these settings."
            case .sampled: return "Measured with a test encode of sample scenes at these settings."
            case .exact: return "Measured with the same search the compression runs."
            }
        }
    }
    /// Would be skipped by "Skip if saving under…".
    var wouldSkip: Bool
    var outputSize: PixelSize
    var previewable: Bool
}

@MainActor
extension QueueItem {
    /// Estimate for `s`: the measured anchor scaled by benchmark ratios between settings.
    func estimate(for s: CompressionSettings, engine: CompressionEngine?) -> SizeEstimate? {
        guard let engine, let source, let plan = try? engine.plan(source, settings: s) else { return nil }
        guard case .ready(let anchor) = estimate else { return instantEstimate(for: s, plan: plan, source: source, engine: engine) }
        // only the kept part counts (trim), compared with that share of the original
        let full = source.media
        let media = source.applying(s.edits).media
        let D = media.duration
        let originalShare = Double(full.fileSize) * min(1, D / max(0.1, full.duration))
        let synthetic = source.analysis.isSynthetic || source.analysis.kind == .screenRecording
        let ev = anchor.evaluation
        let anchorAudio = Double(anchor.plan.streams.audioKbps) * 125 * D
        let anchorVideo = max(1, Double(ev.predictedBytes) - anchorAudio)
        let audio = Double(plan.streams.audioKbps) * 125 * D
        var bytes: Double
        var measured = false
        var basis = SizeEstimate.Basis.scaled
        let level: QualityLevel? = { if case .quality(let l) = s.goal { return l }; return nil }()
        let anchorLevel: QualityLevel = { if case .quality(let l) = anchor.settings.goal { return l }; return .balanced }()
        if case .targetSize(let b) = s.goal {
            // the encoder fills a target unless the video needs less (then Maximum Quality is the cap)
            let maxQuality = SizeEstimator.scale(videoBytes: anchorVideo, from: anchor.plan, aLevel: anchorLevel, to: plan, bLevel: .maximum,
                                                 synthetic: synthetic) + audio
            bytes = min(Double(b) * 0.97, maxQuality)
        } else {
            let l = level ?? .balanced
            if s == anchor.settings { bytes = Double(ev.predictedBytes); measured = true; basis = anchor.exact ? .exact : .sampled }
            else {
                bytes = SizeEstimator.scale(videoBytes: anchorVideo, from: anchor.plan, aLevel: anchorLevel, to: plan, bLevel: l,
                                            synthetic: synthetic) + audio
            }
            // the engine never lets a re-encode grow past ~85 % of an already-compressed source
            if let vb = media.video.bitrate, !["prores", "dnxhd", "ffv1", "rawvideo"].contains(media.video.codec) {
                let ratio = (Double(plan.outputSize.pixels) / Double(max(1, media.video.codedSize.pixels))).squareRoot()
                bytes = min(bytes, Double(vb) / 8 * D * 0.85 * min(1, max(0.5, ratio)) + audio)
            }
        }
        let speedA = SizeEstimator.speed(anchor.plan.encoder, anchor.plan.params.speed, synthetic: synthetic)
        let speedB = SizeEstimator.speed(plan.encoder, plan.params.speed, synthetic: synthetic)
        var secs = ev.estimatedSeconds * speedA / max(1, speedB) * Double(plan.outputSize.pixels) / Double(max(1, anchor.plan.outputSize.pixels))
        if case .targetSize = s.goal, EncoderRegistry.encoder(plan.encoder).supportsTwoPass { secs *= 1.3 }
        let saving = 1 - bytes / max(1, originalShare)
        let mustShrink: Bool = { if case .targetSize(let b) = s.goal { return originalShare > Double(b) }; return false }()
        if case .targetSize = s.goal, bytes >= Double(Self.targetBytes(s) ?? 0) * 0.9 { basis = .exact }   // the encoder fills the target
        return SizeEstimate(bytes: Int64(bytes), seconds: secs, measured: measured, basis: basis,
                            wouldSkip: !mustShrink && (saving <= 0 || saving < s.minimumSavings), outputSize: plan.outputSize,
                            previewable: plan.previewableOnThisMac)
    }
}

@MainActor
extension QueueItem {
    static func targetBytes(_ s: CompressionSettings) -> Int64? { if case .targetSize(let b) = s.goal { return b }; return nil }

    /// Instant estimate (well under a millisecond) before any test encode has run: a bitrate model
    /// from the content analysis and the source's bitrate (`SizeEstimator.instantVideoKbps`).
    func instantEstimate(for s: CompressionSettings, plan: EncodePlan, source: SourceItem, engine: CompressionEngine) -> SizeEstimate {
        let full = source.media
        let applied = source.applying(s.edits)
        let media = applied.media
        let D = media.duration
        let originalShare = Double(full.fileSize) * min(1, D / max(0.1, full.duration))
        let synthetic = source.analysis.isSynthetic || source.analysis.kind == .screenRecording
        let audio = Double(plan.streams.audioKbps) * 125 * D
        var bytes: Double
        var basis = SizeEstimate.Basis.model
        switch s.goal {
        case .targetSize(let b):
            let maxQuality = SizeEstimator.instantVideoKbps(media: media, analysis: source.analysis, plan: plan, level: .maximum) * 125 * D + audio
            bytes = min(Double(b) * 0.97, maxQuality)
            if bytes >= Double(b) * 0.9 { basis = .exact }
        case .quality(let l):
            bytes = SizeEstimator.instantVideoKbps(media: media, analysis: source.analysis, plan: plan, level: l) * 125 * D + audio
        }
        let saving = 1 - bytes / max(1, originalShare)
        let mustShrink = Self.targetBytes(s).map { originalShare > Double($0) } ?? false
        let secs = SizeEstimator.roughSeconds(plan, settings: s, duration: D, synthetic: synthetic, canMeasure: engine.caps.hasVMAF)
        return SizeEstimate(bytes: Int64(bytes), seconds: secs, measured: false, basis: basis,
                            wouldSkip: !mustShrink && (saving <= 0 || saving < s.minimumSavings), outputSize: plan.outputSize,
                            previewable: plan.previewableOnThisMac)
    }
}

/// "~214 MB · −91 %", or a quiet placeholder while the measurement runs.
struct EstimateLabel: View {
    var estimate: SizeEstimate?
    var original: Int64
    var compact = false
    var body: some View {
        if let e = estimate {
            let pct = (1 - Double(e.bytes) / Double(max(1, original))) * 100
            HStack(spacing: 4) {
                Text("≈ \(Fmt.bytes(e.bytes))").monospacedDigit()
                if !compact { Text(pct >= 0 ? String(format: "−%.0f%%", pct) : String(format: "+%.0f%%", -pct)).foregroundStyle(pct >= 0 ? Brand.good : Brand.warn) }
            }
        } else {
            Text("…").foregroundStyle(.tertiary)
        }
    }
}

/// How long jobs really took against their estimates (running side by side included).
struct BatchTiming {
    var estimated = 0.0, actual = 0.0, jobs = 0
    mutating func record(estimated e: Double, actual a: Double) { estimated += e; actual += a; jobs += 1 }
    /// Multiply a solo estimate by this to get its time in this batch; nil until a job has finished.
    var factor: Double? { jobs > 0 && estimated > 0 ? min(4, max(0.25, actual / estimated)) : nil }
}

@MainActor
extension QueueItem {
    /// Time to make one version on its own: measured on this video's samples when that has run,
    /// otherwise from benchmark encoder speeds.
    func timeEstimate(for s: CompressionSettings, engine: CompressionEngine?) -> (seconds: Double, measured: Bool)? {
        if case .ready = estimate, let e = estimate(for: s, engine: engine) { return (e.seconds, true) }
        guard let engine, let source, let plan = try? engine.plan(source, settings: s) else { return nil }
        let synthetic = source.analysis.isSynthetic || source.analysis.kind == .screenRecording
        return (SizeEstimator.roughSeconds(plan, settings: s, duration: source.applying(s.edits).media.duration, synthetic: synthetic,
                                           canMeasure: engine.caps.hasVMAF), false)
    }

    /// Time for every version still to make (queued or not yet started).
    func remainingTime(engine: CompressionEngine?) -> Double? {
        var t = 0.0
        for v in versions {
            switch v.job {
            case .running(let p): t += p.eta ?? (timeEstimate(for: v.settings, engine: engine)?.seconds ?? 0) * (1 - p.fraction)
            case .queued: guard let e = timeEstimate(for: v.settings, engine: engine) else { return nil }; t += e.seconds
            default: if v.isEditable, let e = timeEstimate(for: v.settings, engine: engine) { t += e.seconds }
            }
        }
        return t
    }
}

@MainActor
extension AppModel {
    /// Wall-clock time for the whole batch: each lane's work spread over its parallel slots.
    /// Before anything finishes, parallel software jobs are assumed to slow each other down
    /// (the encoders are already multi-threaded); after that, the batch's own timings are used.
    /// - Parameter pendingToo: count videos that aren't queued yet (the "before starting" figure).
    func batchTimeEstimate(pendingToo: Bool) -> Double? {
        guard let engine else { return nil }
        var lane: [Lane: Double] = [:]
        for item in items where item.source != nil {
            for v in item.versions {
                let l = Self.lane(v.settings)
                let n = Double(Self.slots(l))
                let contention = l == .software ? n / (1 + 0.35 * (n - 1)) : 1
                let factor = batch?.finished == nil ? (batch?.timing[l]?.factor ?? contention) : contention
                switch v.job {
                case .running(let p):
                    lane[l, default: 0] += p.eta ?? (item.timeEstimate(for: v.settings, engine: engine)?.seconds ?? 0) * factor * (1 - p.fraction)
                case .queued:
                    lane[l, default: 0] += (item.timeEstimate(for: v.settings, engine: engine)?.seconds ?? 0) * factor
                default:
                    if pendingToo, v.isEditable {
                        lane[l, default: 0] += (item.timeEstimate(for: v.settings, engine: engine)?.seconds ?? 0) * factor
                    }
                }
            }
        }
        let t = lane.map { $0.value / Double(Self.slots($0.key)) }.max() ?? 0
        return t > 0 ? t : nil
    }
}
