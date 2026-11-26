import Foundation
import DigbyCore

/// A note Digby Video Downloader leaves just before it opens a finished download here:
/// "compress this file now, like this". It lives in this app's private Application Support
/// folder, which web pages can't write to, so only a local app the user runs can ask for an
/// automatic start or for the original to go to the Trash. Opening a video any other way
/// (Finder, drag and drop) works exactly as before: added, not started.
struct HandoffTicket: Codable {
    /// Path of the downloaded video.
    var file: String
    /// How small to make it: a QualityLevel raw value (0 Maximum Quality … 4 Maximum Compression),
    /// or a target size in bytes. Neither = this app's own current settings.
    var quality: Int?
    var targetBytes: Int64?
    /// Move the big download to the Trash once the smaller copy is made and checked.
    var replaceOriginal: Bool
    var created: Date

    var goal: SizeGoal? {
        if let b = targetBytes, b > 0 { return .targetSize(bytes: b) }
        if let q = quality, let l = QualityLevel(rawValue: q) { return .quality(l) }
        return nil
    }

    /// Notes older than this are ignored (and deleted): the hand-off opens the file straight away.
    static let maxAge: TimeInterval = 10 * 60

    static var folder: URL {
        let base = ProcessInfo.processInfo.environment["DIGBY_HANDOFF_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Digby Video Compressor").appendingPathComponent("Handoff")
        return base
    }

    /// The note for this file, if there is a fresh one. Every note read is deleted, so each is used once.
    static func take(for url: URL, now: Date = Date()) -> HandoffTicket? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return nil }
        let wanted = url.standardizedFileURL.path
        var found: HandoffTicket?
        for n in names where n.pathExtension == "json" {
            guard let d = try? Data(contentsOf: n), let t = try? JSONDecoder.handoff.decode(HandoffTicket.self, from: d) else {
                try? fm.removeItem(at: n); continue
            }
            let age = now.timeIntervalSince(t.created)
            if age > maxAge || age < -60 { try? fm.removeItem(at: n); continue }
            if found == nil, URL(fileURLWithPath: t.file).standardizedFileURL.path == wanted {
                found = t
                try? fm.removeItem(at: n)
            }
        }
        return found
    }
}

extension JSONDecoder {
    static var handoff: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

/// What happened to a video Digby Video Downloader sent, written back for its Downloaded list
/// (into `Handoff/Results`, one note per video, replaced as it goes from compressing to done).
/// Only videos sent by the Downloader get one.
struct HandoffResult: Codable {
    enum State: String, Codable { case compressing, done, skipped, failed, cancelled }
    var file: String                // the download, as the Downloader knows it
    var state: State
    var setting: String             // "Balanced", "Fit 25 MB", "Compressor's settings"
    var output: String?             // the smaller file
    var originalBytes: Int64?
    var outputBytes: Int64?
    var format: String?             // "HEVC · 1920×1080"
    var quality: String?            // "Excellent"
    var vmaf: Double?
    var originalTrashed: Bool = false
    var note: String?               // why it was skipped or failed, or what was kept
    var date: Date = Date()

    static var folder: URL { HandoffTicket.folder.appendingPathComponent("Results", isDirectory: true) }

    /// A stable name per download, so later states replace earlier ones.
    static func name(for file: String) -> String {
        var h: UInt64 = 5381
        for b in file.utf8 { h = (h &* 33) &+ UInt64(b) }
        return String(h, radix: 16) + ".json"
    }

    func write() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        guard let d = try? enc.encode(self) else { return }
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try? d.write(to: Self.folder.appendingPathComponent(Self.name(for: file)), options: .atomic)
    }

    static func setting(for goal: SizeGoal?) -> String {
        switch goal {
        case .quality(let l)?: return l.label
        case .targetSize(let b)?: return "Fit \(max(1, b / 1_000_000)) MB"
        case nil: return "Compressor’s settings"
        }
    }
}
