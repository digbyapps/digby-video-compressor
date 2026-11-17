import SwiftUI

/// The empty state: a strip of sky with drifting streaks, and one clear action.
struct DropZoneView: View {
    @Environment(AppModel.self) private var model
    var isTargeted: Bool
    var browse: () -> Void
    @State private var hover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 26) {
            ZStack(alignment: .bottomLeading) {
                SkyBand(drift: !reduceMotion, settled: isTargeted)
                if isTargeted { Brand.dawnFixed.opacity(0.14).blendMode(.plusLighter) }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Video compressor for macOS")
                        .font(.system(size: 10.5, weight: .semibold)).textCase(.uppercase).tracking(em: 0.18, size: 10.5)
                        .foregroundStyle(.white.opacity(0.72))
                    Text("Less weight. Same picture.")
                        .font(.display(26, weight: .light)).tracking(em: -0.02, size: 26)
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 24).padding(.bottom, 20)
                .shadow(color: Brand.altitude.opacity(0.35), radius: 10, y: 2)
            }
            .frame(maxWidth: 560).frame(height: 190)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
            .shadow(color: Brand.altitude.opacity(0.28), radius: 20, y: 10)
            .scaleEffect(isTargeted ? 1.015 : 1)
            .animation(.easeInOut(duration: 0.4), value: isTargeted)

            VStack(spacing: 8) {
                Text(isTargeted ? "Drop to add" : "Drop videos or folders")
                    .font(.display(30, weight: .light))
                    .tracking(em: -0.028, size: 30)
                Text("Folders are searched with all their subfolders. Digby’s own outputs are skipped.")
                    .foregroundStyle(Brand.muted)
            }
            HStack(spacing: 12) {
                Button("Choose Videos…", action: browse)
                    .buttonStyle(ProminentButtonStyle())
                    .keyboardShortcut("o")
                PresetMenu(targets: nil, label: "Settings for new videos")
            }
            HStack(spacing: 22) {
                Feature(symbol: "wand.and.stars", text: "Analyses each video")
                Feature(symbol: "target", text: "Hits your file size")
                Feature(symbol: "text.viewfinder", text: "Keeps text readable")
                Feature(symbol: "eye", text: "Measures real quality")
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(isTargeted ? Brand.accent : Brand.muted.opacity(hover ? 0.4 : 0.22),
                              style: StrokeStyle(lineWidth: isTargeted ? 2.5 : 1, dash: isTargeted ? [] : [8, 7]))
                .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(isTargeted ? Brand.accent.opacity(0.05) : .clear))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: browse)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: isTargeted)
    }

    struct Feature: View {
        var symbol: String
        var text: String
        var body: some View {
            Label { Text(text).foregroundStyle(Brand.muted) } icon: { Image(systemName: symbol).foregroundStyle(Brand.accent) }.font(.callout)
        }
    }
}
