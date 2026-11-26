import Foundation

public enum JobStage: String, Sendable, Codable {
    case waiting = "Waiting"
    case analysing = "Analysing video"
    case sampling = "Preparing sample scenes"
    case optimising = "Finding the best settings"
    case encodingAudio = "Encoding audio"
    case firstPass = "Analysing motion"
    case encoding = "Compressing"
    case adjusting = "Fine-tuning file size"
    case measuring = "Checking quality"
    case checkingText = "Checking text is readable"
    case finishing = "Finishing"
    case done = "Done"
}

public struct JobProgress: Sendable, Equatable {
    public var stage: JobStage
    public var fraction: Double          // overall 0…1
    public var stageFraction: Double
    public var detail: String?
    public var eta: Double?              // seconds remaining (overall)
    public var speed: Double?            // encoder speed, × realtime
    public static let idle = JobProgress(stage: .waiting, fraction: 0, stageFraction: 0)

    /// The stage name, with its own progress for the checks that run after the encode
    /// ("Checking quality… 40 %"), so a nearly full bar never looks stuck.
    public var stageTitle: String {
        switch stage {
        case .measuring, .checkingText, .adjusting:
            return "\(stage.rawValue)… \(Int((min(1, max(0, stageFraction)) * 100).rounded(.down)))%"
        default: return stage.rawValue
        }
    }
}

/// Maps per-stage progress onto one overall bar using cost weights, and
/// derives a smoothed ETA. Weights are estimated wall-clock seconds of each stage
/// (from benchmark encoder and VMAF speeds), so the bar doesn't reach 99 % while the
/// checks after the encode still have minutes to go.
final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var weights: [(JobStage, Double)] = []
    private var current: JobStage = .waiting
    private var start = Date()
    private var smoothedETA: Double?
    private let sink: @Sendable (JobProgress) -> Void
    private var last = JobProgress.idle

    init(sink: @escaping @Sendable (JobProgress) -> Void) { self.sink = sink }

    func configure(_ stages: [(JobStage, Double)]) {
        lock.lock(); weights = stages.filter { $0.1 > 0 }; lock.unlock()
    }

    /// Insert/resize a stage after the fact (e.g. a size-correction pass).
    func addStage(_ stage: JobStage, weight: Double, after: JobStage) {
        lock.lock()
        if let i = weights.firstIndex(where: { $0.0 == after }) { weights.insert((stage, weight), at: i + 1) } else { weights.append((stage, weight)) }
        lock.unlock()
    }

    func update(_ stage: JobStage, _ f: Double, detail: String? = nil, speed: Double? = nil) {
        lock.lock()
        current = stage
        let total = weights.reduce(0) { $0 + $1.1 }
        var before = 0.0, w = 0.0
        for (s, wt) in weights { if s == stage { w = wt; break }; before += wt }
        let overall = total > 0 ? min(1, (before + w * min(1, max(0, f))) / total) : 0
        let elapsed = Date().timeIntervalSince(start)
        var eta: Double? = nil
        if overall > 0.03 && elapsed > 3 {
            let raw = elapsed / overall - elapsed
            smoothedETA = smoothedETA.map { $0 * 0.85 + raw * 0.15 } ?? raw
            eta = smoothedETA
        }
        let p = JobProgress(stage: stage, fraction: max(last.fraction, overall), stageFraction: f,
                            detail: detail ?? (stage == last.stage ? last.detail : nil), eta: eta, speed: speed)
        last = p
        lock.unlock()
        sink(p)
    }
}
