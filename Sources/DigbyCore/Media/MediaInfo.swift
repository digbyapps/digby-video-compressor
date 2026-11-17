import Foundation

/// Everything the engine needs to know about a source file.
public struct MediaInfo: Sendable, Codable, Equatable {
    public var url: URL
    public var fileSize: Int64
    public var duration: Double            // seconds
    public var containerFormat: String
    public var overallBitrate: Int?        // bits/s
    public var video: VideoStreamInfo
    public var audio: [AudioStreamInfo]
    public var subtitles: [SubtitleStreamInfo] = []
    public var hasChapters: Bool
    /// Container-level tags as FFprobe reports them (creation_time, com.apple.quicktime.*, title…).
    public var tags: [String: String] = [:]

    public var subtitleCount: Int { subtitles.count }

    /// Trim: where the kept part starts in the source file (0 = from the start).
    public var clipStart: Double = 0
    /// Only part of the source is used (`duration` is then the kept length).
    public var isClipped = false

    /// FFmpeg input arguments for this source, honouring the trim. `t` is relative to the kept part.
    public func inputArgs(from t: Double = 0, duration d: Double? = nil) -> [String] {
        var a: [String] = []
        let start = clipStart + max(0, t)
        if start > 0.0005 { a += ["-ss", String(format: "%.3f", start)] }
        if let d { a += ["-t", String(format: "%.3f", max(0.05, d))] }
        else if isClipped { a += ["-t", String(format: "%.3f", max(0.05, duration - t))] }
        return a + ["-i", url.path]
    }
    /// Time in the source file of a time in the kept part.
    public func sourceTime(_ t: Double) -> Double { clipStart + t }

    /// This source limited to `window` (start and length in source seconds).
    public func clipped(start: Double, duration d: Double) -> MediaInfo {
        var m = self
        m.clipStart = clipStart + start
        m.duration = d
        m.isClipped = true
        return m
    }

    public init(url: URL, fileSize: Int64, duration: Double, containerFormat: String, overallBitrate: Int?,
                video: VideoStreamInfo, audio: [AudioStreamInfo], subtitles: [SubtitleStreamInfo] = [],
                hasChapters: Bool, tags: [String: String] = [:]) {
        self.url = url; self.fileSize = fileSize; self.duration = duration; self.containerFormat = containerFormat
        self.overallBitrate = overallBitrate; self.video = video; self.audio = audio; self.subtitles = subtitles
        self.hasChapters = hasChapters; self.tags = tags
    }

    /// A QuickTime movie (iPhone, camera, macOS screen recording) rather than an MP4/MKV/…
    public var isQuickTimeMovie: Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "mov" || ext == "qt" || tags["major_brand"]?.trimmingCharacters(in: .whitespaces) == "qt"
    }

    /// When the video was recorded, from the container's metadata (not the file's dates).
    public var recordedAt: String? {
        for k in ["com.apple.quicktime.creationdate", "creation_time", "date"] {
            if let v = tags[k]?.split(separator: ";").first.map(String.init), !v.isEmpty, !v.hasPrefix("1970"), !v.hasPrefix("1904") { return v }
        }
        return nil
    }
    /// ISO 6709 location ("+51.5074-000.1278+010.000/").
    public var location: String? {
        tags["com.apple.quicktime.location.ISO6709"] ?? tags["location"] ?? tags.first { $0.key.hasPrefix("location-") }?.value
    }

    /// Display dimensions after rotation and sample-aspect-ratio correction.
    public var displaySize: PixelSize { video.displaySize }
}

public struct PixelSize: Sendable, Codable, Hashable, CustomStringConvertible {
    public var width: Int
    public var height: Int
    public init(_ w: Int, _ h: Int) { width = w; height = h }
    public var pixels: Int { width * height }
    public var shortSide: Int { min(width, height) }
    public var longSide: Int { max(width, height) }
    public var isPortrait: Bool { height > width }
    public var description: String { "\(width) × \(height)" }
}

public enum DynamicRange: String, Sendable, Codable {
    case sdr, hdr10 = "HDR10 (PQ)", hlg = "HLG", dolbyVision = "Dolby Vision"
    public var isHDR: Bool { self != .sdr }
}

public struct VideoStreamInfo: Sendable, Codable, Equatable {
    public var index: Int
    public var codec: String               // ffprobe codec_name
    public var profile: String?
    public var codedSize: PixelSize
    public var sampleAspectRatio: Double   // 1.0 for square pixels
    public var rotation: Int               // degrees, as displayed (0/90/180/270)
    public var frameRate: Double           // average fps
    public var nominalFrameRate: Double    // r_frame_rate
    public var isVariableFrameRate: Bool
    public var frameCount: Int?
    public var pixelFormat: String
    public var bitDepth: Int
    public var chromaSubsampling: String   // "4:2:0", "4:2:2", "4:4:4"
    public var colorPrimaries: String?
    public var colorTransfer: String?
    public var colorSpace: String?
    public var colorRange: String?
    public var dynamicRange: DynamicRange
    public var isInterlaced: Bool
    public var bitrate: Int?               // bits/s (estimated if container doesn't say)

    public var displaySize: PixelSize {
        var w = Double(codedSize.width) * (sampleAspectRatio > 0 ? sampleAspectRatio : 1)
        var h = Double(codedSize.height)
        if rotation % 180 != 0 { swap(&w, &h) }
        return PixelSize(Int(w.rounded()), Int(h.rounded()))
    }
    public var aspectRatio: Double { Double(displaySize.width) / Double(max(1, displaySize.height)) }

    /// Frame size as FFmpeg's filters see it: coded pixels, already turned upright, before
    /// any non-square pixel correction. Crops are measured in these pixels.
    public var frameSize: PixelSize { rotation % 180 != 0 ? PixelSize(codedSize.height, codedSize.width) : codedSize }

    /// Display size of a part of the frame (`frame` in frame pixels).
    public func displaySize(ofFrame frame: PixelSize) -> PixelSize {
        let sar = sampleAspectRatio > 0 ? sampleAspectRatio : 1
        // SAR stretches the coded width; after a 90° turn that's the height on screen.
        return rotation % 180 != 0 ? PixelSize(frame.width, Int((Double(frame.height) * sar).rounded()))
                                   : PixelSize(Int((Double(frame.width) * sar).rounded()), frame.height)
    }

    /// Friendly codec name for the UI.
    public var codecDisplayName: String { CodecNames.video[codec] ?? codec.uppercased() }
}

public struct AudioStreamInfo: Sendable, Codable, Equatable {
    public var index: Int
    public var codec: String
    public var channels: Int
    public var channelLayout: String?
    public var sampleRate: Int
    public var bitrate: Int?               // bits/s
    public var language: String?
    public var title: String? = nil
    public var isDefault: Bool = false
    public var isLossless: Bool { ["flac", "alac", "truehd", "mlp"].contains(codec) || codec.hasPrefix("pcm_") }
    public var codecDisplayName: String { CodecNames.audio[codec] ?? codec.uppercased() }
}

public struct SubtitleStreamInfo: Sendable, Codable, Equatable {
    public var index: Int
    public var codec: String
    public var language: String?
    public var title: String?
    public var isDefault: Bool
    public var isForced: Bool
    public init(index: Int, codec: String, language: String? = nil, title: String? = nil, isDefault: Bool = false, isForced: Bool = false) {
        self.index = index; self.codec = codec; self.language = language; self.title = title; self.isDefault = isDefault; self.isForced = isForced
    }
    /// Text subtitles can be converted to any container's text format; bitmap ones (DVD, Blu-ray) can't go into MP4/MOV.
    public var isText: Bool { ["subrip", "srt", "ass", "ssa", "mov_text", "webvtt", "text", "ttml", "eia_608"].contains(codec) }
    public var label: String {
        let lang = language.flatMap { $0 == "und" ? nil : Locale.current.localizedString(forLanguageCode: $0) }
        return [lang, title].compactMap { $0 }.joined(separator: " · ").ifEmpty("Subtitles")
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

enum CodecNames {
    static let video = ["h264": "H.264", "hevc": "HEVC", "av1": "AV1", "vp9": "VP9", "vp8": "VP8", "prores": "ProRes",
                        "mpeg4": "MPEG-4", "mpeg2video": "MPEG-2", "dnxhd": "DNxHD", "mjpeg": "Motion JPEG", "ffv1": "FFV1"]
    static let audio = ["aac": "AAC", "opus": "Opus", "mp3": "MP3", "ac3": "Dolby Digital", "eac3": "Dolby Digital Plus",
                        "flac": "FLAC", "alac": "Apple Lossless", "vorbis": "Vorbis", "pcm_s16le": "PCM", "pcm_s24le": "PCM"]
}
