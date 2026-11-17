import SwiftUI
import DigbyCore

/// The six goals as large, labelled tiles. Arrow keys move between them (they're a radio group).
struct GoalPicker: View {
    var selected: Goal
    var choose: (Goal) -> Void
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(Goal.allCases) { g in
                Button { choose(g) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: g.symbol).font(.system(size: 15, weight: .medium)).frame(width: 20)
                        Text(g.title).font(.system(size: 13, weight: g == selected ? .semibold : .regular)).lineLimit(1).minimumScaleFactor(0.85)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .foregroundStyle(g == selected ? Color(nsColor: .windowBackgroundColor) : Color.primary)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(g == selected ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(Color.secondary.opacity(0.09))))
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(g.blurb)
                .accessibilityLabel(g.title)
                .accessibilityHint(g.blurb)
                .accessibilityAddTraits(g == selected ? [.isSelected] : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Goal")
    }
}

/// One control for the trade-off: five stops from "Smallest" to "Best", with the estimated size under each.
struct QualitySlider: View {
    @Environment(AppModel.self) private var model
    @Bindable var item: QueueItem
    var level: QualityLevel
    var media: MediaInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Smaller file").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(level.label).font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("Better picture").font(.caption).foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { level.sliderPosition }, set: { item.settings.goal = .quality(QualityLevel(sliderPosition: $0)) }),
                   in: 0...4, step: 1)
                .tint(Brand.accent)
                .accessibilityLabel("Smaller file or better picture")
                .accessibilityValue("\(level.label). \(level.blurb)")
            HStack(alignment: .top, spacing: 0) {
                ForEach(QualityLevel.allCases.reversed()) { l in
                    VStack(spacing: 2) {
                        Text(l.shortLabel).font(.system(size: 11, weight: l == level ? .semibold : .regular))
                        EstimateLabel(estimate: item.estimate(for: item.settings.with { $0.goal = .quality(l) }, engine: model.engine),
                                      original: media.fileSize, compact: true)
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { item.settings.goal = .quality(l) }
                    .accessibilityHidden(true)
                }
            }
            Text(level.blurb).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Trim · Crop · Rotate · Sound: what's set, and a button to change it.
struct EditsRow: View {
    @Bindable var item: QueueItem
    var openEditor: () -> Void

    var body: some View {
        let e = item.settings.edits
        HStack(spacing: 8) {
            Button { openEditor() } label: { Label("Trim, Crop & Adjust…", systemImage: "crop") }
                .help("Keep only part of the video, remove black bars, rotate, even out the volume")
                .keyboardShortcut("e", modifiers: .command)
            if let d = item.source?.media.duration, e.isTrimmed {
                let w = e.window(duration: d)
                Chip(text: "\(Fmt.duration(w.start))–\(Fmt.duration(w.start + w.duration))", systemImage: "timeline.selection", tint: Brand.accent)
            }
            if e.crop != nil { Chip(text: "Cropped", systemImage: "crop", tint: Brand.accent) }
            if e.rotate % 360 != 0 { Chip(text: "Rotated \(e.rotate)°", systemImage: "rotate.right", tint: Brand.accent) }
            if e.flipHorizontal { Chip(text: "Flipped", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right", tint: Brand.accent) }
            if e.normalizeLoudness { Chip(text: "Volume evened out", systemImage: "speaker.wave.2", tint: Brand.accent) }
            if e.toneMapToSDR { Chip(text: "HDR → SDR", systemImage: "sun.max", tint: Brand.accent) }
            if e.denoise != .off { Chip(text: "Noise reduced", systemImage: "camera.filters", tint: Brand.accent) }
            Spacer()
            if let bars = item.source?.blackBars, e.crop == nil {
                Button("Remove Black Bars") { item.settings.edits.crop = bars }
                    .controlSize(.small)
                    .help("Black bars were found around the picture (\(bars.top + bars.bottom > 0 ? "top and bottom" : "left and right")). Removing them saves space.")
            }
        }
    }
}

/// What comes along besides the picture, and the switches for it.
struct TracksRow: View {
    @Bindable var item: QueueItem
    var plan: EncodePlan?

    var body: some View {
        let m = item.source?.media
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Tracks & information", systemImage: "list.bullet.rectangle")
            HStack(alignment: .top, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("File format").font(.caption).foregroundStyle(.secondary)
                    Picker("File format", selection: $item.settings.advanced.container) {
                        ForEach(ContainerChoice.allCases) { c in
                            Text(c == .automatic ? "Automatic (\(plan?.streams.container.label ?? "MP4"))" : c.rawValue).tag(c)
                        }
                    }.labelsHidden().fixedSize()
                }
                if (m?.audio.count ?? 0) > 1 {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Audio tracks (\(m!.audio.count))").font(.caption).foregroundStyle(.secondary)
                        Picker("Audio tracks", selection: $item.settings.advanced.audioTracks) {
                            ForEach(TrackSelection.allCases) { Text($0.rawValue).tag($0) }
                        }.labelsHidden().fixedSize()
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(m.map { $0.subtitles.isEmpty ? "Keep subtitles" : "Keep subtitles (\($0.subtitles.count))" } ?? "Keep subtitles",
                           isOn: $item.settings.advanced.keepSubtitles)
                    Toggle("Keep date, place & camera", isOn: $item.settings.advanced.keepMetadata)
                        .help("When and where it was recorded, and the camera or phone. Turn off to remove them before sharing.")
                }
                .toggleStyle(.checkbox)
            }
            if let p = plan, let m {
                if let k = p.streams.keptSummary(m) { InfoRow(systemImage: "checkmark.circle", text: "Kept: " + k, tint: Brand.good) }
                ForEach(p.streams.dropped, id: \.self) { InfoRow(systemImage: "exclamationmark.triangle", text: $0, tint: Brand.warn) }
                if p.streams.container == .mov && item.settings.advanced.container == .automatic {
                    InfoRow(systemImage: "info.circle", text: "Saved as .mov, like the original, so Photos and Finder keep when and where it was recorded.")
                }
            }
        }
    }
}

extension ContentKind {
    /// Outcome-oriented names ("Slides & screen recordings" rather than "Screen Recording").
    var friendlyName: String {
        switch self {
        case .talkingHeadAnimation: return "Animation & talking heads"
        case .screenRecording: return "Slides & screen recordings"
        case .liveAction: return "Camera footage"
        case .general: return "Mixed"
        }
    }
}

extension AnalysisDepth {
    var friendlyName: String {
        switch self {
        case .quick: return "Fast"
        case .smart: return "Recommended"
        case .bestPossible: return "Smallest possible"
        }
    }
}
