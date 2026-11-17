import SwiftUI
import DigbyCore

/// An estimated outcome for one combination of settings on one video.
struct SizeEstimate {
    var bytes: Int64
    var seconds: Double
    /// Measured directly on this video's samples (vs. scaled from a measurement).
    var measured: Bool
    /// Would be skipped by "Skip if saving under…".
    var wouldSkip: Bool
    var outputSize: PixelSize
    var previewable: Bool
}

@MainActor
extension QueueItem {
    /// Estimate for `s`: the measured anchor scaled by benchmark ratios between settings.
    func estimate(for s: CompressionSettings, engine: CompressionEngine?) -> SizeEstimate? {
        guard let engine, let source, case .ready(let anchor) = estimate,
              let plan = try? engine.plan(source, settings: s) else { return nil }
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
        let level: QualityLevel? = { if case .quality(let l) = s.goal { return l }; return nil }()
        let anchorLevel: QualityLevel = { if case .quality(let l) = anchor.settings.goal { return l }; return .balanced }()
        if case .targetSize(let b) = s.goal {
            // the encoder fills a target unless the video needs less (then Maximum Quality is the cap)
            let maxQuality = SizeEstimator.scale(videoBytes: anchorVideo, from: anchor.plan, aLevel: anchorLevel, to: plan, bLevel: .maximum,
                                                 synthetic: synthetic) + audio
            bytes = min(Double(b) * 0.97, maxQuality)
        } else {
            let l = level ?? .balanced
            if s == anchor.settings { bytes = Double(ev.predictedBytes); measured = true }
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
        return SizeEstimate(bytes: Int64(bytes), seconds: secs, measured: measured,
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
        if let e = estimate(for: s, engine: engine) { return (e.seconds, true) }
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
