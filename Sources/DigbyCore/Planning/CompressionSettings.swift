import Foundation

/// Requested output resolution. Presets describe a bounding box (oriented to
/// match the source, so "1080p" of a portrait phone video is 1080 × 1920);
/// the aspect ratio is always preserved unless a custom size asks otherwise,
/// and video is never upscaled unless explicitly allowed.
public enum OutputResolution: Hashable, Codable, Sendable, Identifiable {
    case original, uhd2160, qhd1440, fhd1080, hd720, sd480
    case custom(width: Int, height: Int, keepAspect: Bool)

    public var id: String { label }
    public static let presets: [OutputResolution] = [.original, .uhd2160, .qhd1440, .fhd1080, .hd720, .sd480]

    public var label: String {
        switch self {
        case .original: return "Original"
        case .uhd2160: return "4K (2160p)"
        case .qhd1440: return "1440p"
        case .fhd1080: return "1080p"
        case .hd720: return "720p"
        case .sd480: return "480p"
        case .custom(let w, let h, _): return "Custom \(w) × \(h)"
        }
    }

    public var box: PixelSize? {
        switch self {
        case .original: return nil
        case .uhd2160: return PixelSize(3840, 2160)
        case .qhd1440: return PixelSize(2560, 1440)
        case .fhd1080: return PixelSize(1920, 1080)
        case .hd720: return PixelSize(1280, 720)
        case .sd480: return PixelSize(854, 480)
        case .custom(let w, let h, _): return PixelSize(w, h)
        }
    }

    /// Resolve against a source's display size.
    public func resolve(source: PixelSize, allowUpscale: Bool = false) -> PixelSize {
        guard var box else { return Self.even(source) }
        if case .custom(_, _, false) = self { return Self.even(allowUpscale ? box : PixelSize(min(box.width, source.width), min(box.height, source.height))) }
        // orient the box like the source
        if source.isPortrait != box.isPortrait && box.width != box.height { box = PixelSize(box.height, box.width) }
        let scale = min(Double(box.width) / Double(source.width), Double(box.height) / Double(source.height))
        let s = allowUpscale ? scale : min(1.0, scale)
        return Self.even(PixelSize(Int((Double(source.width) * s).rounded()), Int((Double(source.height) * s).rounded())))
    }

    static func even(_ p: PixelSize) -> PixelSize { PixelSize(max(2, p.width / 2 * 2), max(2, p.height / 2 * 2)) }

    /// Next lower preset (for "would a lower resolution look better?" checks).
    public static func stepDown(from size: PixelSize) -> PixelSize? {
        let ladder = [2160, 1440, 1080, 720, 540, 480, 360]
        guard let next = ladder.first(where: { $0 < size.shortSide - 8 }), next >= 360 else { return nil }
        let s = Double(next) / Double(size.shortSide)
        return even(PixelSize(Int((Double(size.width) * s).rounded()), Int((Double(size.height) * s).rounded())))
    }
}

/// The five plain-English compression levels.
public enum QualityLevel: Int, Codable, Sendable, CaseIterable, Identifiable {
    case maximum = 0, high, balanced, aggressive, maximumCompression
    public var id: Int { rawValue }
    public var label: String {
        switch self {
        case .maximum: return "Maximum Quality"
        case .high: return "High Quality"
        case .balanced: return "Balanced"
        case .aggressive: return "Aggressive"
        case .maximumCompression: return "Maximum Compression"
        }
    }
    public var blurb: String {
        switch self {
        case .maximum: return "Visually indistinguishable from the original. Still much smaller."
        case .high: return "Excellent quality; differences only visible frame-by-frame."
        case .balanced: return "Strong compression with very good quality. Recommended."
        case .aggressive: return "Small files. Fine detail softens in busy scenes."
        case .maximumCompression: return "Smallest files. Some visible quality loss is likely."
        }
    }
    /// Perceptual target (VMAF, 0–100) the optimiser aims for on this level.
    /// ~93+ is generally considered "good to excellent", 97+ near-transparent.
    public var targetVMAF: Double {
        switch self {
        case .maximum: return 97
        case .high: return 95
        case .balanced: return 93
        case .aggressive: return 90
        case .maximumCompression: return 85
        }
    }
}

public enum SizeGoal: Hashable, Codable, Sendable {
    case quality(QualityLevel)
    /// Maximum output size in bytes (decimal MB, as Finder shows them).
    case targetSize(bytes: Int64)
}

/// What matters most beyond quality-per-megabyte.
public enum OutputPriority: String, Codable, Sendable, CaseIterable, Identifiable {
    case smallestFile = "Smallest File"
    case appleDevices = "Apple Devices"
    case playsEverywhere = "Plays Everywhere"
    case fastest = "Fastest"
    public var id: String { rawValue }
    public var blurb: String {
        switch self {
        case .smallestFile: return "Best quality per megabyte (AV1). Plays in browsers, VLC, IINA, YouTube and on M3+ Macs and recent iPhones."
        case .appleDevices: return "HEVC. Plays natively on every modern Mac, iPhone, iPad and Apple TV."
        case .playsEverywhere: return "H.264. Plays on practically any device or app, at a larger size."
        case .fastest: return "Uses the Apple Silicon media engine. Very fast; larger files than the other options."
        }
    }
}

/// How much work the engine may spend finding the best settings.
public enum AnalysisDepth: String, Codable, Sendable, CaseIterable, Identifiable {
    case quick = "Quick"
    case smart = "Smart"
    case bestPossible = "Best Possible"
    public var id: String { rawValue }
    public var blurb: String {
        switch self {
        case .quick: return "Settings predicted from content analysis. No trial encodes."
        case .smart: return "Trial-encodes short samples and measures quality (VMAF) to tune settings. Adds a few percent to encode time."
        case .bestPossible: return "Compares encoders and resolutions on samples and verifies the result. Slowest, best result."
        }
    }
}

public enum TenBitMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case automatic = "Automatic", on = "Always 10-bit", off = "8-bit"
    public var id: String { rawValue }
}

/// Expert options. Every field defaults to "let the engine decide".
public struct AdvancedSettings: Codable, Sendable, Hashable {
    public var encoder: EncoderID? = nil
    public var speed: EncoderSpeed? = nil
    public var frameRateCap: Double? = nil
    public var audioCodec: AudioCodecChoice = .automatic
    public var audioBitrateKbps: Int? = nil
    public var keyframeSeconds: Double? = nil
    public var preferHardware: Bool = false
    /// Also test the Apple media engine during the quality search, and use it when it passes the
    /// same VMAF and text-legibility checks at a similar size (much faster final encode).
    public var tryHardware: Bool = true
    /// Constant-quality value on the chosen encoder's native scale.
    public var qualityValue: Double? = nil
    /// Explicit perceptual target (VMAF) overriding the quality level's target.
    public var targetVMAF: Double? = nil
    public var tenBit: TenBitMode = .automatic
    public var profile: ContentKind? = nil
    public var filmGrain: Bool? = nil
    public var allowLowerResolution: Bool = true
    public var extraEncoderParams: String = ""
    /// File format. Automatic keeps QuickTime sources as .mov (so Photos and Finder keep the
    /// recording's date, place and camera) and makes .mp4 otherwise.
    public var container: ContainerChoice = .automatic
    /// Every audio track (languages, commentary) or only the main one.
    public var audioTracks: TrackSelection = .all
    /// Keep subtitle tracks (text subtitles are converted for MP4/MOV; DVD/Blu-ray picture subtitles need MKV).
    public var keepSubtitles: Bool = true
    /// Keep when and where it was recorded, the camera, title and other information.
    public var keepMetadata: Bool = true
    public init() {}

    enum CodingKeys: String, CodingKey {
        case encoder, speed, frameRateCap, audioCodec, audioBitrateKbps, keyframeSeconds, preferHardware, tryHardware, qualityValue, targetVMAF,
             tenBit, profile, filmGrain, allowLowerResolution, extraEncoderParams, container, audioTracks, keepSubtitles, keepMetadata
    }
    // Tolerant decoding: settings saved by older versions lack newer keys (and had `keepAllAudioTracks`, now ignored).
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? def }
        encoder = v(.encoder, nil); speed = v(.speed, nil); frameRateCap = v(.frameRateCap, nil)
        audioCodec = v(.audioCodec, .automatic); audioBitrateKbps = v(.audioBitrateKbps, nil); keyframeSeconds = v(.keyframeSeconds, nil)
        preferHardware = v(.preferHardware, false); tryHardware = v(.tryHardware, true); qualityValue = v(.qualityValue, nil); targetVMAF = v(.targetVMAF, nil)
        tenBit = v(.tenBit, .automatic); profile = v(.profile, nil); filmGrain = v(.filmGrain, nil)
        allowLowerResolution = v(.allowLowerResolution, true); extraEncoderParams = v(.extraEncoderParams, "")
        container = v(.container, .automatic); audioTracks = v(.audioTracks, .all)
        keepSubtitles = v(.keepSubtitles, true); keepMetadata = v(.keepMetadata, true)
    }
}

public enum ContainerChoice: String, Codable, Sendable, CaseIterable, Identifiable {
    case automatic = "Automatic", mp4 = "MP4", mov = "QuickTime (MOV)", mkv = "Matroska (MKV)"
    public var id: String { rawValue }
}

public enum OutputContainer: String, Codable, Sendable {
    case mp4, mov, mkv
    public var fileExtension: String { rawValue }
    public var ffmpegFormat: String { self == .mkv ? "matroska" : rawValue }
    public var label: String { self == .mkv ? "MKV" : rawValue.uppercased() }
}

public enum TrackSelection: String, Codable, Sendable, CaseIterable, Identifiable {
    case all = "All Tracks", first = "Main Track Only"
    public var id: String { rawValue }
}

/// Per-video changes to the picture and sound. Never copied between videos by "Apply to All".
public struct EditSettings: Codable, Sendable, Hashable {
    /// Keep only this part of the video (seconds in the source).
    public var trimStart: Double? = nil
    public var trimEnd: Double? = nil
    /// Pixels removed from each edge, in the orientation the video is shown in.
    public var crop: CropInsets? = nil
    /// Extra clockwise rotation (0, 90, 180, 270), on top of the orientation the camera recorded.
    public var rotate: Int = 0
    public var flipHorizontal: Bool = false
    /// Even out the volume to a standard loudness (−16 LUFS, the level podcasts and streaming services use).
    public var normalizeLoudness: Bool = false
    /// Convert HDR to standard dynamic range, for screens and apps that show HDR washed out.
    public var toneMapToSDR: Bool = false
    public var denoise: DenoiseStrength = .off
    public init() {}

    public var isTrimmed: Bool { (trimStart ?? 0) > 0.001 || trimEnd != nil }
    public var hasPictureChanges: Bool { crop != nil || rotate % 360 != 0 || flipHorizontal || toneMapToSDR || denoise != .off }
    public var isEmpty: Bool { !isTrimmed && !hasPictureChanges && !normalizeLoudness }

    enum CodingKeys: String, CodingKey { case trimStart, trimEnd, crop, rotate, flipHorizontal, normalizeLoudness, toneMapToSDR, denoise }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? def }
        trimStart = v(.trimStart, nil); trimEnd = v(.trimEnd, nil); crop = v(.crop, nil); rotate = v(.rotate, 0)
        flipHorizontal = v(.flipHorizontal, false); normalizeLoudness = v(.normalizeLoudness, false)
        toneMapToSDR = v(.toneMapToSDR, false); denoise = v(.denoise, .off)
    }

    /// The part of a `duration`-long source that is kept.
    public func window(duration: Double) -> (start: Double, duration: Double) {
        let s = max(0, min(trimStart ?? 0, max(0, duration - 0.1)))
        let e = min(duration, max(s + 0.1, trimEnd ?? duration))
        return (s, e - s)
    }
}

public struct CropInsets: Codable, Sendable, Hashable {
    public var top: Int, bottom: Int, left: Int, right: Int
    public init(top: Int, bottom: Int, left: Int, right: Int) { self.top = top; self.bottom = bottom; self.left = left; self.right = right }
    public var isZero: Bool { top == 0 && bottom == 0 && left == 0 && right == 0 }
    /// Size left after cropping `size` (even numbers, at least 16 px).
    public func apply(to size: PixelSize) -> PixelSize {
        PixelSize(max(16, (size.width - left - right) / 2 * 2), max(16, (size.height - top - bottom) / 2 * 2))
    }
}

public enum DenoiseStrength: String, Codable, Sendable, CaseIterable, Identifiable {
    case off = "Off", light = "Light", medium = "Medium", strong = "Strong"
    public var id: String { rawValue }
    var filter: String? {
        switch self {
        case .off: return nil
        case .light: return "hqdn3d=1.5:1.5:3:3"
        case .medium: return "hqdn3d=3:2.5:5:4.5"
        case .strong: return "hqdn3d=5:4:8:7"
        }
    }
}

/// "Keep text readable": automatic follows text detection; on/off are explicit choices.
public enum TextGuardMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case automatic, on, off
    public var id: String { rawValue }
}

public struct CompressionSettings: Codable, Sendable, Hashable {
    public var resolution: OutputResolution = .original
    public var goal: SizeGoal = .quality(.balanced)
    public var audio: AudioQuality = .automatic
    public var priority: OutputPriority = .smallestFile
    public var depth: AnalysisDepth = .smart
    /// Measure VMAF of the finished file (sub-sampled). Required for the quality badge.
    public var measureQuality: Bool = true
    /// Only make files this Mac can play in Finder's Quick Look, QuickTime and Photos.
    /// On Macs without an AV1 hardware decoder (M1/M2) this means HEVC instead of AV1.
    public var previewableOnThisMac: Bool = true
    /// Protect the legibility of slides, captions and on-screen text.
    public var textGuard: TextGuardMode = .automatic
    /// Keep the original (and discard the result) unless compression saves at least
    /// this fraction of the file size. 0 = always keep the result if it is smaller.
    public var minimumSavings: Double = 0.10
    public var advanced = AdvancedSettings()
    /// Trim, crop, rotation and other per-video changes.
    public var edits = EditSettings()
    /// What the user set out to do ("smaller", "fit", "share"…), for the app's goal picker. The engine ignores it.
    public var intent: String? = nil
    public init() {}

    enum CodingKeys: String, CodingKey {
        case resolution, goal, audio, priority, depth, measureQuality, previewableOnThisMac, textGuard, minimumSavings, advanced, edits, intent
    }
    // Tolerant decoding: settings saved by older versions (or presets) lack newer keys.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        resolution = try c.decodeIfPresent(OutputResolution.self, forKey: .resolution) ?? .original
        goal = try c.decodeIfPresent(SizeGoal.self, forKey: .goal) ?? .quality(.balanced)
        audio = try c.decodeIfPresent(AudioQuality.self, forKey: .audio) ?? .automatic
        priority = try c.decodeIfPresent(OutputPriority.self, forKey: .priority) ?? .smallestFile
        depth = try c.decodeIfPresent(AnalysisDepth.self, forKey: .depth) ?? .smart
        measureQuality = try c.decodeIfPresent(Bool.self, forKey: .measureQuality) ?? true
        previewableOnThisMac = try c.decodeIfPresent(Bool.self, forKey: .previewableOnThisMac) ?? true
        textGuard = try c.decodeIfPresent(TextGuardMode.self, forKey: .textGuard) ?? .automatic
        minimumSavings = try c.decodeIfPresent(Double.self, forKey: .minimumSavings) ?? 0.10
        advanced = (try? c.decodeIfPresent(AdvancedSettings.self, forKey: .advanced)) ?? AdvancedSettings()
        edits = (try? c.decodeIfPresent(EditSettings.self, forKey: .edits)) ?? EditSettings()
        intent = try? c.decodeIfPresent(String.self, forKey: .intent)
    }

    /// The same settings without anything that belongs to one particular video (trim, crop…).
    public var withoutEdits: CompressionSettings { var s = self; s.edits = EditSettings(); return s }
}
