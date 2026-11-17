import Foundation

/// Everything in the output besides the picture: container, audio tracks, subtitles,
/// chapters and the recording's information (date, place, camera).
public struct StreamPlan: Sendable, Equatable {
    public var container: OutputContainer
    /// Every audio track to write (the first is the main one); empty = no sound.
    public var audio: [AudioPlan]
    public var subtitles: [SubtitlePlan]
    public var keepChapters: Bool
    public var keepMetadata: Bool
    /// What was left out and why, in plain English.
    public var dropped: [String]

    public var audioKbps: Int { audio.reduce(0) { $0 + $1.bitrateKbps } }
    public var hasAudio: Bool { audio.contains { $0.codec != .none } }

    /// One line for the UI: "2 audio tracks · subtitles (English) · chapters · date & place".
    public func keptSummary(_ media: MediaInfo) -> String? {
        var parts: [String] = []
        let a = audio.filter { $0.codec != .none }.count
        if a > 1 { parts.append("\(a) audio tracks") }
        if !subtitles.isEmpty {
            let names = subtitles.map(\.label).filter { $0 != "Subtitles" }
            parts.append(names.isEmpty ? (subtitles.count == 1 ? "subtitles" : "\(subtitles.count) subtitle tracks")
                                       : "subtitles (\(names.prefix(3).joined(separator: ", ")))")
        }
        if keepChapters && media.hasChapters { parts.append("chapters") }
        if keepMetadata {
            var info: [String] = []
            if media.recordedAt != nil { info.append("date") }
            if media.location != nil && container == .mov { info.append("place") }
            if !info.isEmpty { parts.append(info.joined(separator: " & ") + " recorded") }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

public struct SubtitlePlan: Sendable, Equatable {
    public var streamIndex: Int
    /// FFmpeg subtitle encoder, or "copy".
    public var codec: String
    public var label: String
    public var isDefault: Bool
    public var isForced: Bool
}

public enum StreamPlanner {
    /// Container for an output, from the setting, the source and the codecs.
    public static func container(_ choice: ContainerChoice, media: MediaInfo, videoCodec: VideoCodec, opusAudio: Bool) -> OutputContainer {
        switch choice {
        case .mp4: return .mp4
        case .mov: return (videoCodec == .hevc || videoCodec == .h264) && !opusAudio ? .mov : .mp4
        case .mkv: return .mkv
        case .automatic:
            // QuickTime movies stay QuickTime movies, so Photos, Finder and Maps keep the
            // recording's date, place and camera (MP4 can only carry the date for them).
            if media.isQuickTimeMovie && (videoCodec == .hevc || videoCodec == .h264) && !opusAudio { return .mov }
            return .mp4
        }
    }

    public static func subtitles(media: MediaInfo, keep: Bool, container: OutputContainer) -> (plans: [SubtitlePlan], dropped: [String]) {
        guard keep else {
            return ([], media.subtitles.isEmpty ? [] : ["Subtitles left out (you chose not to keep them)."])
        }
        var plans: [SubtitlePlan] = [], dropped: [String] = []
        var pictureSubs = 0
        for s in media.subtitles {
            let codec: String
            switch container {
            case .mkv: codec = s.codec == "mov_text" ? "srt" : (s.codec == "eia_608" ? "srt" : "copy")
            case .mp4, .mov:
                guard s.isText else { pictureSubs += 1; continue }
                codec = "mov_text"
            }
            plans.append(SubtitlePlan(streamIndex: s.index, codec: codec, label: s.label, isDefault: s.isDefault, isForced: s.isForced))
        }
        if pictureSubs > 0 {
            dropped.append("\(pictureSubs) DVD/Blu-ray subtitle track\(pictureSubs == 1 ? " is a picture format that" : "s are a picture format that") \(container.label) can’t hold, so \(pictureSubs == 1 ? "it was" : "they were") left out. Choose MKV under Advanced → File format to keep \(pictureSubs == 1 ? "it" : "them").")
        }
        return (plans, dropped)
    }

    /// FFmpeg arguments for container metadata: keep it (with the recording date and, in MOV,
    /// the place and camera written where Apple's apps read them), or strip it.
    public static func metadataArguments(media: MediaInfo, keep: Bool, container: OutputContainer) -> [String] {
        guard keep else { return ["-map_metadata", "-1", "-metadata", "creation_time=" + iso(Date())] }
        var a = ["-map_metadata", "0"]
        if let r = media.recordedAt, let d = parseDate(r) {
            // A trimmed video starts later than the original recording.
            a += ["-metadata", "creation_time=" + iso(d.addingTimeInterval(media.clipStart))]
        }
        if container == .mov {
            if let l = media.location { a += ["-metadata", "location=\(l)"] }
            if let m = media.tags["com.apple.quicktime.make"] ?? media.tags["make"] { a += ["-metadata", "make=\(m)"] }
            if let m = media.tags["com.apple.quicktime.model"] ?? media.tags["model"] { a += ["-metadata", "model=\(m)"] }
        }
        return a
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        for opts: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime],
                                                   [.withFullDate, .withTime, .withColonSeparatorInTime, .withTimeZone, .withDashSeparatorInDate]] {
            f.formatOptions = opts
            if let d = f.date(from: s) { return d }
        }
        // "2024-06-01T11:20:30+0100" (no colon in the offset) and "2024-06-01 11:20:30"
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZ", "yyyy-MM-dd HH:mm:ss"] {
            df.dateFormat = fmt
            if fmt == "yyyy-MM-dd HH:mm:ss" { df.timeZone = TimeZone(identifier: "UTC") }
            if let d = df.date(from: s) { return d }
        }
        return nil
    }
    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }
}
