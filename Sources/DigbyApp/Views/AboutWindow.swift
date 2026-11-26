import SwiftUI
import AppKit
import DigbyCore

/// The About window: the website's sky, the Digby wordmark lockup, and the credits.
enum AboutWindow {
    @MainActor private static var window: NSWindow?

    @MainActor static func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 430), styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: AboutView())
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
    }
}

struct AboutView: View {
    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development build" }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                AppIconMark(size: 96)
                DigbyLockup(size: 24, color: .primary)
            }
            .padding(.top, 40)
            VStack(spacing: 6) {
                Text("Less weight. Same picture.").font(.display(22, weight: .light)).tracking(em: -0.025, size: 22)
                Text("Version \(version)").font(.callout).foregroundStyle(Brand.muted).monospacedDigit().padding(.top, 2)
                Text("Encoding by FFmpeg with SVT-AV1, x265, x264, Opus and VMAF.").font(.caption).foregroundStyle(Brand.muted)
                    .multilineTextAlignment(.center).padding(.horizontal, 30).padding(.top, 10)
                HStack(spacing: 12) {
                    Button("Third-Party Notices") {
                        if let u = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "txt", subdirectory: "Licenses") { NSWorkspace.shared.open(u) }
                    }
                    Button("Engine Log") { if let u = Log.logFileURL { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
                }
                .controlSize(.small).padding(.top, 12)
                Text("© 2026 Digby").font(.caption2).foregroundStyle(.tertiary).padding(.top, 10)
            }
            .padding(.vertical, 22)
            Spacer(minLength: 0)
        }
        .frame(width: 420).frame(minHeight: 430, maxHeight: .infinity, alignment: .top)
        .background(Brand.canvas)
        .tint(Brand.accent)
        .ignoresSafeArea()
    }
}
