import Foundation
import DigbyCore

/// The first question Digby asks: what are you trying to do? Each goal sets sensible
/// engine settings; everything can still be changed under "More options".
enum Goal: String, CaseIterable, Identifiable {
    case smaller, fit, share, space, archive, quick
    var id: String { rawValue }

    var title: String {
        switch self {
        case .smaller: return "Make it smaller"
        case .fit: return "Fit a size limit"
        case .share: return "Share anywhere"
        case .space: return "Free up space"
        case .archive: return "Best quality"
        case .quick: return "Quick"
        }
    }
    var symbol: String {
        switch self {
        case .smaller: return "arrow.down.right.and.arrow.up.left"
        case .fit: return "target"
        case .share: return "paperplane"
        case .space: return "internaldrive"
        case .archive: return "sparkles"
        case .quick: return "hare"
        }
    }
    /// One line under the goal, in plain words.
    var blurb: String {
        switch self {
        case .smaller: return "A much smaller file that looks as good. Plays on Apple devices and in Finder."
        case .fit: return "Under a limit, for email, chat apps or upload forms. Guaranteed not to go over."
        case .share: return "Plays on any phone, computer, TV or app, even old ones. Up to 1080p."
        case .space: return "Shrink videos you keep, with no visible difference. Skips files that wouldn’t shrink much."
        case .archive: return "Visually identical to the original, in the most efficient format. Takes longer."
        case .quick: return "Done in seconds using your Mac’s video engine. Files are bigger than the other goals make."
        }
    }

    static func of(_ s: CompressionSettings) -> Goal { s.intent.flatMap(Goal.init) ?? (isTarget(s) ? .fit : .smaller) }
    static func isTarget(_ s: CompressionSettings) -> Bool { if case .targetSize = s.goal { return true }; return false }

    /// Settings for this goal, keeping what belongs to the video (trim, crop…) and the user's expert choices.
    func apply(to s: inout CompressionSettings, source: MediaInfo?, macDecodesAV1: Bool) {
        let edits = s.edits
        let advanced = s.advanced
        s = CompressionSettings()
        s.edits = edits
        s.advanced.container = advanced.container
        s.advanced.audioTracks = advanced.audioTracks
        s.advanced.keepSubtitles = advanced.keepSubtitles
        s.advanced.keepMetadata = advanced.keepMetadata
        s.intent = rawValue
        switch self {
        case .smaller:
            s.goal = .quality(.balanced)
            FormatChoice.hevc.apply(to: &s, macDecodesAV1: macDecodesAV1)
            if macDecodesAV1 { FormatChoice.av1.apply(to: &s, macDecodesAV1: true) }
        case .fit:
            let size = source?.fileSize ?? 100_000_000
            let limit = Destination.all.first { $0.bytes < size }?.bytes ?? max(1_000_000, size / 4)
            s.goal = .targetSize(bytes: limit)
            FormatChoice.h264.apply(to: &s, macDecodesAV1: macDecodesAV1)
            s.minimumSavings = 0
        case .share:
            s.goal = .quality(.balanced)
            s.resolution = .fhd1080
            FormatChoice.h264.apply(to: &s, macDecodesAV1: macDecodesAV1)
        case .space:
            s.goal = .quality(.high)
            FormatChoice.hevc.apply(to: &s, macDecodesAV1: macDecodesAV1)
            if macDecodesAV1 { FormatChoice.av1.apply(to: &s, macDecodesAV1: true) }
            s.minimumSavings = 0.15
        case .archive:
            s.goal = .quality(.maximum)
            FormatChoice.av1.apply(to: &s, macDecodesAV1: macDecodesAV1)
            s.depth = .bestPossible
            s.minimumSavings = 0.05
        case .quick:
            s.goal = .quality(.balanced)
            FormatChoice.hardware.apply(to: &s, macDecodesAV1: macDecodesAV1)
        }
    }
}

/// Size limits of the places people send videos. Kept as data: limits change, so each
/// carries the date it was last checked, and the email figure leaves room for the ~37 %
/// that attachments grow by when mailed.
struct Destination: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var symbol: String
    var bytes: Int64
    var note: String

    static let checked = "November 2026"
    static let all: [Destination] = [
        Destination(name: "Email", symbol: "envelope", bytes: 18_000_000, note: "Gmail and Outlook allow 20–25 MB per message; an attachment grows by about a third when sent."),
        Destination(name: "WhatsApp", symbol: "message", bytes: 16_000_000, note: "Videos sent as video (not as a document) are limited to about 16 MB on many phones."),
        Destination(name: "Discord", symbol: "bubble.left.and.bubble.right", bytes: 10_000_000, note: "The free plan’s upload limit. Nitro allows more."),
    ]
    static let sizesMB: [Int] = [500, 250, 100, 50]
}

extension QualityLevel {
    /// Position on the "Smaller ↔ Better" control (0 = smallest, 4 = best).
    var sliderPosition: Double { Double(4 - rawValue) }
    init(sliderPosition p: Double) { self = QualityLevel(rawValue: 4 - Int(p.rounded()).clamped(0, 4)) ?? .balanced }
    /// Short name on the control.
    var shortLabel: String {
        switch self {
        case .maximum: return "Best"
        case .high: return "High"
        case .balanced: return "Balanced"
        case .aggressive: return "Small"
        case .maximumCompression: return "Smallest"
        }
    }
}

extension Int {
    func clamped(_ lo: Int, _ hi: Int) -> Int { Swift.min(hi, Swift.max(lo, self)) }
}
