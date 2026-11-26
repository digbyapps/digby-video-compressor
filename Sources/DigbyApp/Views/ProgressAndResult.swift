import SwiftUI
import AVFoundation
import DigbyCore

struct ProgressCard: View {
    var progress: JobProgress
    var cancel: () -> Void

    var body: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                Text(progress.stage.rawValue).font(.display(19, weight: .medium)).tracking(em: -0.012, size: 19)
                Spacer()
                Text("\(Int((progress.fraction * 100).rounded(.down)))%").font(.display(30, weight: .light)).tracking(em: -0.03, size: 30).monospacedDigit()
            }
            ConvergenceProgress(fraction: progress.fraction)
            HStack(spacing: 14) {
                if let d = progress.detail { Text(d).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                if let s = progress.speed, s > 0 { Label(String(format: "%.1f× real time", s), systemImage: "speedometer").foregroundStyle(.secondary) }
                Group {
                    if let eta = progress.eta { Label("About \(Fmt.eta(eta)) left", systemImage: "clock").foregroundStyle(.secondary) }
                    else { Label("Estimating time…", systemImage: "clock").foregroundStyle(.tertiary) }
                }.fixedSize()
            }
            .font(.callout).monospacedDigit()
            HStack {
                Text("You can keep working — compression runs in the background.").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button(role: .cancel) { cancel() } label: { Text("Cancel") }.keyboardShortcut(".", modifiers: .command)
            }
        }
    }
}

struct ResultCard: View {
    var result: CompressionResult
    var compare: () -> Void
    var again: () -> Void
    var restore: (() -> Void)? = nil
    /// Move this compressed file to the Trash.
    var trash: (() -> Void)? = nil
    /// Make another version of the same video.
    var another: (() -> Void)? = nil
    @State private var playable: Bool?
    @State private var confirmTrash = false

    var body: some View {
        Card {
            HStack(spacing: 10) {
                ZStack {
                    ChevronMark().frame(width: 46, height: 24)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Compressed").font(.display(19, weight: .medium)).tracking(em: -0.012, size: 19)
                    Text(result.outputURL.lastPathComponent).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text("in \(Fmt.eta(result.elapsed))").font(.callout).foregroundStyle(.secondary)
            }

            Grid(horizontalSpacing: 18, verticalSpacing: 16) {
                GridRow {
                    StatTile(title: "Original", value: Fmt.bytes(result.originalBytes))
                    StatTile(title: "Compressed", value: Fmt.bytes(result.outputBytes), caption: targetCaption,
                             tint: result.metTarget == false ? .orange : .primary)
                    StatTile(title: "Saved", value: String(format: "%.1f%%", result.reduction * 100),
                             caption: Fmt.bytes(max(0, result.originalBytes - result.outputBytes)), tint: Brand.dawn)
                }
                GridRow {
                    StatTile(title: "Resolution", value: "\(result.outputSize.width) × \(result.outputSize.height)",
                             caption: result.reducedDetail ? result.sourceSize.map { "was \($0.width) × \($0.height)" } : nil)
                    StatTile(title: "Codec", value: result.codec.rawValue, caption: "\(result.tenBit ? "10-bit" : "8-bit") · \(result.audioSummary)")
                    if let q = result.quality {
                        StatTile(title: "Quality", value: q.rating.rawValue,
                                 caption: String(format: "VMAF %.1f · worst moments %.1f", q.vmaf, q.vmafP5), tint: q.rating.color)
                    } else {
                        StatTile(title: "Quality", value: "Not measured", caption: "Turn on “Measure VMAF” in Advanced", tint: .secondary)
                    }
                }
            }
            .padding(.vertical, 4)

            if let q = result.quality {
                Text(q.rating.explanation + (result.reducedDetail
                    ? " The rating compares the result with the original at the new size; it doesn’t count the detail given up by making the picture smaller."
                    : "")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            FlowLayout(spacing: 8, lineSpacing: 6) {
                if result.previewableOnThisMac {
                    Chip(text: "Plays in Quick Look on this Mac", systemImage: "eye", tint: Brand.good)
                } else {
                    Chip(text: "No Quick Look on this Mac", systemImage: "eye.slash", tint: Brand.warn)
                        .help("This Mac can’t decode AV1 in Apple’s players (that needs an M3 or later). VLC, IINA, browsers and YouTube play it.")
                }
                if let h = result.hardwareChoice {
                    Chip(text: String(format: "Media engine · %.0f× faster", max(1, h.speedup)), systemImage: "bolt.fill", tint: Brand.good)
                        .help(h.summary)
                }
                if let t = result.textCheck, t.isReliable {
                    Chip(text: String(format: "Text: %.0f%% reads the same", t.accuracy * 100), systemImage: "text.viewfinder",
                         tint: t.accuracy >= TextLegibility.requiredAccuracy ? Brand.good : Brand.warn)
                        .help(t.summary)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                if let k = result.kept { InfoRow(systemImage: "checkmark.circle", text: "Kept: " + k, tint: Brand.good) }
                if let from = result.trimmedFrom { InfoRow(systemImage: "timeline.selection", text: "Trimmed to \(Fmt.duration(result.duration)) of \(Fmt.duration(from)).") }
                ForEach(result.warnings, id: \.self) { InfoRow(systemImage: "exclamationmark.triangle.fill", text: $0, tint: Brand.warn) }
                ForEach(result.notes, id: \.self) { InfoRow(systemImage: "info.circle", text: $0) }
                InfoRow(systemImage: "cpu", text: result.settingsSummary)
                if !result.previewableOnThisMac {
                    InfoRow(systemImage: "eye.slash", text: "Finder’s spacebar preview and QuickTime won’t play this AV1 file on this Mac (that needs an M3 or later). VLC, IINA, browsers and YouTube play it. Choose “HEVC · Previews in Finder” under Format to get a file that does.", tint: Brand.warn)
                }
            }

            // One row when it fits, otherwise two rows (open/share, then keep/redo), otherwise wrapped.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { openButtons; Spacer(minLength: 10); keepButtons }
                VStack(alignment: .leading, spacing: 10) { HStack(spacing: 10) { openButtons }; HStack(spacing: 10) { keepButtons } }
                FlowLayout(spacing: 10, lineSpacing: 10) { openButtons; keepButtons }
            }
            .lineLimit(1)
            .controlSize(.large)
        }
        .task { playable = try? await AVURLAsset(url: result.outputURL).load(.isPlayable) }
    }

    @ViewBuilder var openButtons: some View {
                Button { play() } label: { Label("Play", systemImage: "play.fill") }.fixedSize()
                Button { NSWorkspace.shared.activateFileViewerSelecting([result.outputURL]) } label: { Label("Show in Finder", systemImage: "folder") }.fixedSize()
                ShareLink(item: result.outputURL) { Label("Share", systemImage: "square.and.arrow.up") }
                    .help("Send with AirDrop, Mail, Messages and more").fixedSize()
                Button { compare() } label: { Label("Compare with Original", systemImage: "rectangle.split.2x1") }.fixedSize()
    }

    @ViewBuilder var keepButtons: some View {
                if let restore { Button("Restore Original") { restore() }.help("Bring the original back from the Trash and move this compressed copy to the Trash") }
                if let trash {
                    Button("Move to Trash") { confirmTrash = true }
                        .help("Don’t keep this compressed file")
                        .confirmationDialog("Move “\(result.outputURL.lastPathComponent)” to the Trash?", isPresented: $confirmTrash) {
                            Button("Move to Trash", role: .destructive) { trash() }
                        } message: { Text("Your original isn’t affected. You can take the file back out of the Trash.") }
                }
                if let another { Button("Make Another Version") { another() }.help("Make this video again with different settings, e.g. a smaller size for email") }
                Button("Compress Again…") { again() }.buttonStyle(.link).fixedSize()
    }

    var targetCaption: String? {
        guard let t = result.targetBytes else { return nil }
        return result.outputBytes <= t ? "Target \(Fmt.bytes(t)) ✓" : "Target \(Fmt.bytes(t)) — over"
    }

    func play() {
        if playable == false, let vlc = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.videolan.vlc")
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.colliderli.iina") {
            NSWorkspace.shared.open([result.outputURL], withApplicationAt: vlc, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(result.outputURL)
        }
    }
}
