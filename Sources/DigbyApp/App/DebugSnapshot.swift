import AppKit
import SwiftUI
import DigbyCore

/// Developer aid: `DIGBY_SNAPSHOT=/path/prefix` makes the app render its own main
/// window to PNG files (no Screen Recording permission needed, since it draws
/// its own views). `DIGBY_OPEN=/path/video` adds a video at launch.
/// `DIGBY_SNAPSHOT_DELAYS=3,20` sets the capture times in seconds. `DIGBY_APPEARANCE=dark|light` forces an appearance.
/// `DIGBY_LAYOUT_RENDER=1` is for layout review next to a running copy of the app: it never reads or clears the
/// saved queue, never sweeps temp files, and quits with exit(). `DIGBY_WINDOW_SIZE=900x600` sizes the window
/// before a `DIGBY_SNAPSHOT`; `DIGBY_RENDER_WIDTH=640` sets the width of a `DIGBY_RENDER_DETAIL` render.
enum DebugSnapshot {
    static var layoutOnly: Bool { ProcessInfo.processInfo.environment["DIGBY_LAYOUT_RENDER"] != nil }

    @MainActor static func startForLayout(_ model: AppModel) async {
        model.resumeOffer = []      // a non-nil offer stops saveQueue() from clearing the real app's Queue.json
        do { model.engineState = .ready(try await CompressionEngine.make()) } catch { model.engineState = .failed(error.localizedDescription) }
    }

    @MainActor static func quit() { if layoutOnly { exit(0) } else { NSApp.terminate(nil) } }

    @MainActor static func scheduleIfRequested(model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        if let a = env["DIGBY_APPEARANCE"] { NSApp.appearance = NSAppearance(named: a == "dark" ? .darkAqua : .aqua) }
        if env["DIGBY_SHOW_ABOUT"] != nil { AboutWindow.show() }
        if let open = env["DIGBY_OPEN"] { model.add(urls: open.split(separator: ",").map { URL(fileURLWithPath: String($0)) }) }
        if env["DIGBY_AUTOCOMPRESS"] != nil {
            // wait for analysis, then press "Compress" through the model, like the button does
            Task { @MainActor in
                while model.selected?.source == nil { try? await Task.sleep(nanoseconds: 300_000_000) }
                if let item = model.selected, let adds = env["DIGBY_ADD_VERSIONS"] {
                    for q in adds.split(separator: ",").compactMap({ QuickAdd(rawValue: String($0)) }) {
                        for s in item.quickAdd(q, engine: model.engine).settings { model.addVersion(to: item, settings: s, purpose: q.purpose) }
                    }
                }
                model.compressSelected()
            }
        }
        if let out = env["DIGBY_RENDER_DETAIL"] { renderDetail(model: model, to: out, after: Double(env["DIGBY_SNAPSHOT_DELAYS"] ?? "10") ?? 10) }
        guard let prefix = env["DIGBY_SNAPSHOT"] else { return }
        if let size = env["DIGBY_WINDOW_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if let win = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) {
                    win.setFrame(NSRect(x: 60, y: 60, width: size[0], height: size[1]), display: true)
                }
            }
        }
        let delays = (env["DIGBY_SNAPSHOT_DELAYS"] ?? "4").split(separator: ",").compactMap { Double($0) }
        for (i, d) in delays.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) {
                guard let win = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                      let view = win.contentView?.superview ?? win.contentView else { return }
                // Render the layer tree (captures layer-backed SwiftUI content that cacheDisplay misses).
                let scale = win.backingScaleFactor
                let size = view.bounds.size
                if let layer = view.layer,
                   let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                       bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) {
                    ctx.setFillColor(NSColor.windowBackgroundColor.cgColor); ctx.fill(CGRect(origin: .zero, size: CGSize(width: size.width * scale, height: size.height * scale)))
                    ctx.scaleBy(x: scale, y: scale)
                    if !view.isFlipped { } 
                    layer.render(in: ctx)
                    if let img = ctx.makeImage() {
                        let rep = NSBitmapImageRep(cgImage: img)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(prefix)-\(i).png"))
                    }
                }
                if env["DIGBY_SNAPSHOT_COMPRESS"] != nil, i == 0 { model.compressSelected() }
                if i == delays.count - 1 && env["DIGBY_SNAPSHOT_QUIT"] != nil { quit() }
            }
        }
    }

    /// Offscreen SwiftUI render of the selected item's detail pane (layout review).
    @MainActor static func renderDetail(model: AppModel, to path: String, after delay: Double) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
            // if a job is running, wait for it to finish so the result card is rendered
            while model.selected?.isActive == true { try? await Task.sleep(nanoseconds: 500_000_000) }
            let width = Double(ProcessInfo.processInfo.environment["DIGBY_RENDER_WIDTH"] ?? "") ?? 940
            guard let item = model.selected else {
                if ProcessInfo.processInfo.environment["DIGBY_RENDER_VIEW"]?.contains("empty") == true {
                    write(DropZoneView(isTargeted: false) {}.environment(model).padding(36).frame(width: width, height: Double(ProcessInfo.processInfo.environment["DIGBY_RENDER_HEIGHT"] ?? "") ?? 640),
                          to: path)
                }
                quit(); return
            }
            // DIGBY_ADD_VERSIONS=webSet,email: apply ready-made versions first
            if let adds = ProcessInfo.processInfo.environment["DIGBY_ADD_VERSIONS"], ProcessInfo.processInfo.environment["DIGBY_AUTOCOMPRESS"] == nil {
                for q in adds.split(separator: ",").compactMap({ QuickAdd(rawValue: String($0)) }) {
                    for s in item.quickAdd(q, engine: model.engine).settings { model.addVersion(to: item, settings: s, purpose: q.purpose) }
                }
                if let sel = ProcessInfo.processInfo.environment["DIGBY_SELECT_VERSION"], let i = Int(sel), i < item.versions.count {
                    item.selectedVersionID = item.versions[i].id
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            // DIGBY_RENDER_VIEW=expanded (More options open) | editor (Trim, Crop & Adjust) | dark
            let what = ProcessInfo.processInfo.environment["DIGBY_RENDER_VIEW"] ?? ""
            if what.contains("expanded") { model.prefs.showAdvanced = true }
            if what.contains("crop"), let bars = item.source?.blackBars { item.settings.edits.crop = bars; item.settings.edits.trimStart = 2; item.settings.edits.trimEnd = 7 }
            let scheme: ColorScheme = what.contains("dark") ? .dark : .light
            if what.contains("dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
            let content: AnyView
            if what.contains("editor"), let engine = model.engine, let src = item.source {
                content = AnyView(EditorView(item: item, engine: engine, source: src).environment(model))
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            } else {
                content = AnyView(ItemDetailContent(item: item, compare: .constant(nil)).environment(model).frame(width: width))
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            write(content.environment(\.colorScheme, scheme), to: path)
            quit()
        }
    }

    @MainActor static func write(_ content: some View, to path: String) {
        let view = content.tint(Brand.accent).background(Brand.canvas)
        let r = ImageRenderer(content: view); r.scale = 2
        if let img = r.cgImage {
            try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
}
