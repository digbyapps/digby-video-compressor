import SwiftUI

/// The empty state: quiet and centred, with one clear action.
struct DropZoneView: View {
    @Environment(AppModel.self) private var model
    var isTargeted: Bool
    var browse: () -> Void
    @State private var hover = false

    var body: some View {
        // Minimal by design: the app icon, one headline, one action. (`SkyBand` and `CompressMotif` are kept in
        // Components.swift, unused, and can be put back here.)
        VStack(spacing: 22) {
            AppIconMark(size: 76)
                .scaleEffect(isTargeted ? 1.05 : 1)
                .animation(.easeInOut(duration: 0.3), value: isTargeted)
            VStack(spacing: 8) {
                Text(isTargeted ? "Drop to add" : "Drop videos or folders")
                    .font(.display(30, weight: .light))
                    .tracking(em: -0.028, size: 30)
                Text("Folders are searched with all their subfolders. Digby’s own outputs are skipped.")
                    .foregroundStyle(Brand.muted).multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                Button("Choose Videos…", action: browse)
                    .buttonStyle(ProminentButtonStyle())
                    .keyboardShortcut("o")
                PresetMenu(targets: nil, label: "Settings for new videos")
            }
            Text("Analyses each video · Hits your file size · Keeps text readable · Measures real quality")
                .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                .padding(.top, 6)
        }
        .padding(.horizontal, 24)
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
}
