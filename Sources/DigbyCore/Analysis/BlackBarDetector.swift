import Foundation

/// Finds black bars (letterboxing / pillarboxing) that are present throughout a video,
/// with FFmpeg's `cropdetect` on a few short stretches. Returns nil when there are none.
public struct BlackBarDetector: Sendable {
    let tools: ToolPaths
    public init(tools: ToolPaths) { self.tools = tools }

    public func detect(_ media: MediaInfo) async -> CropInsets? {
        guard media.duration > 1 else { return nil }
        let size = media.video.frameSize      // cropdetect works in the decoded frame's pixels
        let points = media.duration < 12 ? [media.duration * 0.5] : [0.2, 0.45, 0.7].map { media.duration * $0 }
        var crops: [(w: Int, h: Int, x: Int, y: Int)] = []
        for t in points {
            let r = try? await ProcessRunner.run(tools.ffmpeg, [
                "-v", "info", "-nostdin", "-ss", String(format: "%.3f", t), "-t", "2", "-i", media.url.path, "-map", "0:v:0",
                "-vf", "cropdetect=limit=0.09:round=2:reset=0", "-f", "null", "-",
            ], options: { var o = ProcessRunner.Options(); o.allowFailure = true; o.collectStdout = false; return o }())
            guard let log = r?.stderr,
                  let line = log.split(separator: "\n").last(where: { $0.contains("crop=") }),
                  let spec = line.split(separator: " ").last(where: { $0.hasPrefix("crop=") }) else { return nil }
            let n = spec.dropFirst(5).split(separator: ":").compactMap { Int($0) }
            guard n.count == 4, n[0] > 0, n[1] > 0 else { return nil }
            crops.append((n[0], n[1], n[2], n[3]))
        }
        // The bars must be there everywhere we looked: keep the largest picture seen.
        guard let w = crops.map(\.w).max(), let h = crops.map(\.h).max(),
              let x = crops.map(\.x).min(), let y = crops.map(\.y).min() else { return nil }
        let insets = CropInsets(top: y, bottom: max(0, size.height - h - y), left: x, right: max(0, size.width - w - x))
        // Ignore slivers (encoder padding, soft edges): at least 2 % of the picture on one side pair.
        let vertical = insets.top + insets.bottom, horizontal = insets.left + insets.right
        guard Double(vertical) >= Double(size.height) * 0.04 || Double(horizontal) >= Double(size.width) * 0.04 else { return nil }
        // Keep the picture large: never more than 45 % removed in one direction.
        guard Double(vertical) < Double(size.height) * 0.45, Double(horizontal) < Double(size.width) * 0.45 else { return nil }
        return CropInsets(top: insets.top / 2 * 2, bottom: insets.bottom / 2 * 2, left: insets.left / 2 * 2, right: insets.right / 2 * 2)
    }
}
