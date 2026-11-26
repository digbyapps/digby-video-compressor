import Foundation

/// What happened to each job in the session before the app was last closed (quit, force quit,
/// crash or restart), shown once on reopening.
public enum LastSessionOutcome: String, Codable, Sendable { case finished, stopped, failed, cancelled }

public struct LastSessionItem: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var outcome: LastSessionOutcome
    /// The plain reason (failed), or what it was doing (stopped).
    public var reason: String?
    /// Stopped or failed jobs whose file is still there can be started again.
    public var canResume: Bool
    public init(id: String, name: String, outcome: LastSessionOutcome, reason: String? = nil, canResume: Bool = false) {
        self.id = id; self.name = name; self.outcome = outcome; self.reason = reason; self.canResume = canResume
    }
}

public struct LastSessionReport: Sendable, Equatable {
    public var items: [LastSessionItem]
    public var noun: String          // "video", "download"
    public init(items: [LastSessionItem], noun: String) { self.items = items; self.noun = noun }

    public func count(_ o: LastSessionOutcome) -> Int { items.filter { $0.outcome == o }.count }
    /// Shown only when something was left undone.
    public var worthShowing: Bool { count(.stopped) + count(.failed) > 0 }
    public var resumable: [LastSessionItem] { items.filter { $0.outcome == .stopped && $0.canResume } }

    func plural(_ n: Int) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    /// "Digby closed before 2 videos were done." / "1 download didn’t finish last time."
    public var headline: String {
        let s = count(.stopped)
        if s > 0 { return "Digby closed before \(plural(s)) \(s == 1 ? "was" : "were") done." }
        let f = count(.failed)
        return "\(plural(f)) didn’t finish last time."
    }
    /// "3 finished · 2 stopped · 1 failed" (empty kinds left out).
    public var tally: String {
        [(LastSessionOutcome.finished, "finished"), (.stopped, "stopped"), (.failed, "failed"), (.cancelled, "cancelled")]
            .compactMap { count($0.0) > 0 ? "\(count($0.0)) \($0.1)" : nil }
            .joined(separator: " · ")
    }
}

/// Leftovers of a run that was killed before it could tidy up.
public enum Leftovers {
    /// Hidden half-written outputs (".name.digby-partial-ab12cd.mp4").
    public static func isPartial(_ name: String) -> Bool { name.hasPrefix(".") && name.contains(".digby-partial-") }

    /// Deletes half-written outputs in `folder` untouched for `age` seconds (a live encode writes every second,
    /// so one still running elsewhere, such as the command-line tool, is left alone). Returns how many went.
    @discardableResult
    public static func sweepPartials(in folder: URL, olderThan age: TimeInterval = 120, now: Date = Date()) -> Int {
        let fm = FileManager.default
        var n = 0
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where isPartial(name) {
            let url = folder.appendingPathComponent(name)
            let mod = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
            if now.timeIntervalSince(mod) >= age, (try? fm.removeItem(at: url)) != nil { n += 1 }
        }
        return n
    }

    /// Stops copies of `executable` that lost their parent (the app was force quit or crashed while they ran,
    /// so they were adopted by launchd). Only exact path matches are touched.
    @discardableResult
    public static func stopOrphans(of executable: String) -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,ppid=,comm="]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return 0 }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let pids = orphanPIDs(psOutput: out, executable: executable)
        for pid in pids { kill(pid, SIGKILL) }
        return pids.count
    }

    /// Parses `ps -axo pid=,ppid=,comm=` for processes running `executable` whose parent is launchd.
    public static func orphanPIDs(psOutput: String, executable: String) -> [pid_t] {
        psOutput.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = pid_t(parts[0]), parts[1] == "1",
                  parts[2].trimmingCharacters(in: .whitespaces) == executable else { return nil }
            return pid
        }
    }
}
