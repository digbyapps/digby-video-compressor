import Foundation

/// A short, lossless excerpt of the source used for trial encodes: several
/// evenly spaced scenes, already deinterlaced/scaled exactly like the final
/// encode, concatenated into one FFV1 file. Decoding it is cheap, so every
/// trial encode costs only the encoder's own time.
public struct SampleSet: Sendable {
    public var url: URL
    public var duration: Double
    public var size: PixelSize
    public var fps: Double
    /// True when the "sample" is the entire video (short sources).
    public var isWholeVideo: Bool
}

public struct SampleBuilder: Sendable {
    let tools: ToolPaths
    public init(tools: ToolPaths) { self.tools = tools }

    /// - Parameters:
    ///   - totalSeconds: approximate sample length (more = more representative, slower)
    public func build(media: MediaInfo, filters: String?, outputSize: PixelSize, fps: Double,
                      totalSeconds: Double = 20, workspace: TempWorkspace,
                      label: String = "samples") async throws -> SampleSet {
        let out = workspace.file("\(label).mkv")
        let chain = [filters, "format=yuv420p10le"].compactMap { $0 }.joined(separator: ",")
        let common = ["-c:v", "ffv1", "-level", "3", "-slices", "16", "-g", "1", "-threads", "0", "-an", "-sn", "-dn", out.path]

        if media.duration <= totalSeconds * 1.5 {
            // short video: just use all of it
            try await FFmpegRun(tools: tools).run(media.inputArgs() + ["-map", "0:v:0", "-vf", chain] + common, duration: media.duration)
            return SampleSet(url: out, duration: media.duration, size: outputSize, fps: fps, isWholeVideo: true)
        }
        // Segments of at least ~2.5 s: each starts with a keyframe, and frames just after a
        // keyframe look better than typical ones, so very short segments flatter the trial.
        let count = max(2, min(min(10, max(4, Int(media.duration / 60) + 4)), Int(totalSeconds / 2.5)))
        let seg = max(1.5, totalSeconds / Double(count))
        let usable = media.duration - seg
        let starts = (0..<count).map { usable * (0.03 + 0.94 * Double($0) / Double(count - 1)) }
        var args: [String] = []
        for s in starts { args += media.inputArgs(from: s, duration: seg) }
        var graph = ""
        for i in 0..<count { graph += "[\(i):v:0]\(chain),setpts=PTS-STARTPTS[v\(i)];" }
        graph += (0..<count).map { "[v\($0)]" }.joined() + "concat=n=\(count):v=1:a=0[out]"
        try await FFmpegRun(tools: tools).run(args + ["-filter_complex", graph, "-map", "[out]"] + common, duration: seg * Double(count))
        return SampleSet(url: out, duration: seg * Double(count), size: outputSize, fps: fps, isWholeVideo: false)
    }
}
