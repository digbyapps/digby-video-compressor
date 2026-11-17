import SwiftUI
import DigbyCore

/// Trim, crop, rotate and adjust one video. Frames come from FFmpeg, so it works for every
/// format Digby opens (including AV1 and MKV on Macs whose own players can't show them).
struct EditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Bindable var item: QueueItem
    let engine: CompressionEngine
    let source: SourceItem

    @State private var playhead: Double = 0
    @State private var frame: CGImage?
    @State private var strip: [CGImage] = []
    @State private var loadTask: Task<Void, Never>?

    var media: MediaInfo { source.media }
    var edits: EditSettings { item.settings.edits }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Trim, Crop & Adjust").font(.title2.weight(.semibold))
                Spacer()
                Text(item.name).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            preview
            trimControls
            Divider()
            HStack(alignment: .top, spacing: 30) {
                cropControls
                orientationControls
                adjustControls
            }
            Divider()
            HStack {
                Button("Reset All") { item.settings.edits = EditSettings() }
                    .disabled(edits.isEmpty)
                Spacer()
                Text(resultLine).foregroundStyle(.secondary).monospacedDigit()
                Button("Done") { dismiss() }.buttonStyle(ProminentButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 880)
        .task { load(at: edits.isTrimmed ? edits.window(duration: media.duration).start : media.duration * 0.15); await loadStrip() }
    }

    // MARK: preview

    var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(.black)
            if let f = frame {
                GeometryReader { geo in
                    let size = media.displaySize
                    let turned = (edits.rotate / 90) % 2 != 0
                    let box = turned ? CGSize(width: geo.size.height, height: geo.size.width) : geo.size
                    let scale = min(box.width / CGFloat(size.width), box.height / CGFloat(size.height))
                    let w = CGFloat(size.width) * scale, h = CGFloat(size.height) * scale
                    ZStack {
                        Image(cgImage: f).resizable().frame(width: w, height: h)
                        if let c = edits.crop { CropShade(insets: c, size: media.video.frameSize).frame(width: w, height: h) }
                    }
                    .scaleEffect(x: edits.flipHorizontal ? -1 : 1, y: 1)
                    .rotationEffect(.degrees(Double(edits.rotate)))
                    .frame(width: geo.size.width, height: geo.size.height)
                }
                .padding(8)
            } else {
                ProgressView().controlSize(.small)
            }
            if !isInsideTrim {
                Text("Not kept (outside the trim)").font(.callout.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule()).frame(maxHeight: .infinity, alignment: .top).padding(.top, 12)
            }
        }
        .frame(height: 330)
        .accessibilityElement()
        .accessibilityLabel("Frame at \(Fmt.duration(playhead))\(isInsideTrim ? "" : ", outside the trim")")
    }

    var isInsideTrim: Bool {
        let w = edits.window(duration: media.duration)
        return playhead >= w.start - 0.01 && playhead <= w.start + w.duration + 0.01
    }

    // MARK: trim

    var trimControls: some View {
        let w = edits.window(duration: media.duration)
        return VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .leading) {
                HStack(spacing: 2) {
                    ForEach(strip.indices, id: \.self) { i in
                        Image(cgImage: strip[i]).resizable().aspectRatio(contentMode: .fill).frame(maxWidth: .infinity).frame(height: 44).clipped()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                GeometryReader { geo in
                    let x0 = geo.size.width * w.start / max(0.1, media.duration)
                    let x1 = geo.size.width * (w.start + w.duration) / max(0.1, media.duration)
                    Rectangle().fill(.black.opacity(0.55)).frame(width: max(0, x0))
                    Rectangle().fill(.black.opacity(0.55)).frame(width: max(0, geo.size.width - x1)).offset(x: x1)
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Brand.accent, lineWidth: 3).frame(width: max(4, x1 - x0)).offset(x: x0)
                    Rectangle().fill(.white).frame(width: 2).offset(x: geo.size.width * playhead / max(0.1, media.duration) - 1)
                }
                .allowsHitTesting(false)
            }
            .frame(height: 44)
            .accessibilityHidden(true)
            Slider(value: Binding(get: { playhead }, set: { playhead = $0; load(at: $0) }), in: 0...max(0.1, media.duration))
                .accessibilityLabel("Position")
                .accessibilityValue(Fmt.duration(playhead))
            HStack(spacing: 10) {
                Button { item.settings.edits.trimStart = playhead < 0.05 ? nil : min(playhead, (edits.trimEnd ?? media.duration) - 0.5) } label: {
                    Label("Start Here", systemImage: "arrow.right.to.line")
                }.keyboardShortcut("i", modifiers: [])
                Button { item.settings.edits.trimEnd = playhead > media.duration - 0.05 ? nil : max(playhead, (edits.trimStart ?? 0) + 0.5) } label: {
                    Label("End Here", systemImage: "arrow.left.to.line")
                }.keyboardShortcut("o", modifiers: [])
                if edits.isTrimmed { Button("Keep Everything") { item.settings.edits.trimStart = nil; item.settings.edits.trimEnd = nil } }
                Spacer()
                Text(edits.isTrimmed ? "Keeping \(Fmt.duration(w.start))–\(Fmt.duration(w.start + w.duration)) (\(Fmt.duration(w.duration)) of \(Fmt.duration(media.duration)))"
                                     : "Keeping all \(Fmt.duration(media.duration))")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            .controlSize(.regular)
            Text("Move to a moment, then press I (start) or O (end).").font(.caption).foregroundStyle(.tertiary)
        }
    }

    // MARK: crop / orientation / adjustments

    var cropControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Crop", systemImage: "crop")
            if let bars = source.blackBars {
                Toggle("Remove black bars", isOn: Binding(get: { edits.crop == bars }, set: { item.settings.edits.crop = $0 ? bars : nil }))
                    .toggleStyle(.checkbox)
                    .help("Found \(bars.top + bars.bottom > 0 ? "\(bars.top + bars.bottom) px top and bottom" : "\(bars.left + bars.right) px left and right")")
            } else {
                Text("No black bars found.").font(.caption).foregroundStyle(.secondary)
            }
            let c = edits.crop ?? CropInsets(top: 0, bottom: 0, left: 0, right: 0)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow { insetStepper("Top", c.top, max: media.video.frameSize.height / 3) { $0.top = $1 }
                          insetStepper("Bottom", c.bottom, max: media.video.frameSize.height / 3) { $0.bottom = $1 } }
                GridRow { insetStepper("Left", c.left, max: media.video.frameSize.width / 3) { $0.left = $1 }
                          insetStepper("Right", c.right, max: media.video.frameSize.width / 3) { $0.right = $1 } }
            }
            .font(.callout)
        }
    }

    func insetStepper(_ label: String, _ value: Int, max: Int, set: @escaping (inout CropInsets, Int) -> Void) -> some View {
        Stepper(value: Binding(get: { value }, set: { v in
            var c = edits.crop ?? CropInsets(top: 0, bottom: 0, left: 0, right: 0)
            set(&c, Swift.max(0, Swift.min(max, v / 2 * 2)))
            item.settings.edits.crop = c.isZero ? nil : c
        }), in: 0...max, step: 8) {
            Text("\(label) \(value) px").monospacedDigit().frame(width: 92, alignment: .leading)
        }
        .accessibilityLabel("Crop \(label.lowercased())")
        .accessibilityValue("\(value) pixels")
    }

    var orientationControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Orientation", systemImage: "rotate.right")
            HStack {
                Button { item.settings.edits.rotate = (edits.rotate + 270) % 360 } label: { Image(systemName: "rotate.left") }
                    .accessibilityLabel("Rotate left").help("Rotate 90° anticlockwise")
                Button { item.settings.edits.rotate = (edits.rotate + 90) % 360 } label: { Image(systemName: "rotate.right") }
                    .accessibilityLabel("Rotate right").help("Rotate 90° clockwise")
                Text(edits.rotate == 0 ? "As recorded" : "\(edits.rotate)°").foregroundStyle(.secondary).monospacedDigit()
            }
            Toggle("Mirror (flip left–right)", isOn: $item.settings.edits.flipHorizontal).toggleStyle(.checkbox)
        }
    }

    var adjustControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Adjust", systemImage: "slider.horizontal.3")
            if !media.audio.isEmpty {
                Toggle("Even out the volume", isOn: $item.settings.edits.normalizeLoudness).toggleStyle(.checkbox)
                    .help("Makes quiet or loud recordings play at a standard level (−16 LUFS, as podcasts and streaming services use), without squashing the dynamics.")
            }
            if media.video.dynamicRange.isHDR {
                Toggle("Convert HDR to standard (SDR)", isOn: $item.settings.edits.toneMapToSDR).toggleStyle(.checkbox)
                    .help("For screens and apps that show HDR video washed out or too dark.")
            }
            Picker("Reduce noise", selection: $item.settings.edits.denoise) {
                ForEach(DenoiseStrength.allCases) { Text($0.rawValue).tag($0) }
            }
            .fixedSize()
            .help("Smooths grain from low light or old cameras. Grainy video compresses much smaller with it, at the cost of fine texture.")
        }
    }

    var resultLine: String {
        var size = media.displaySize
        if let c = edits.crop { size = media.video.displaySize(ofFrame: c.apply(to: media.video.frameSize)) }
        if (edits.rotate / 90) % 2 != 0 { size = PixelSize(size.height, size.width) }
        let w = edits.window(duration: media.duration)
        return "Result: \(size.width) × \(size.height) · \(Fmt.duration(w.duration))"
    }

    // MARK: frames

    func load(at t: Double) {
        playhead = t
        loadTask?.cancel()
        loadTask = Task {
            try? await Task.sleep(nanoseconds: 120_000_000)      // follow the slider without decoding every step
            guard !Task.isCancelled else { return }
            if let img = try? await FrameGrabber(tools: engine.tools).frame(media.url, at: t, maxDimension: 1100), !Task.isCancelled {
                frame = img
            }
        }
    }

    func loadStrip() async {
        let n = 10
        var out: [CGImage] = []
        for i in 0..<n {
            let t = media.duration * (Double(i) + 0.5) / Double(n)
            if let img = try? await FrameGrabber(tools: engine.tools).frame(media.url, at: t, maxDimension: 200) { out.append(img); strip = out }
        }
    }
}

/// Darkens what a crop removes.
struct CropShade: View {
    var insets: CropInsets
    var size: PixelSize
    var body: some View {
        GeometryReader { geo in
            let sx = geo.size.width / CGFloat(size.width), sy = geo.size.height / CGFloat(size.height)
            let r = CGRect(x: CGFloat(insets.left) * sx, y: CGFloat(insets.top) * sy,
                           width: geo.size.width - CGFloat(insets.left + insets.right) * sx,
                           height: geo.size.height - CGFloat(insets.top + insets.bottom) * sy)
            Path { p in p.addRect(CGRect(origin: .zero, size: geo.size)); p.addRect(r) }
                .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
            Rectangle().strokeBorder(Brand.accent, lineWidth: 2).frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
        }
        .allowsHitTesting(false)
    }
}
