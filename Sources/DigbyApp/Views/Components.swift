import SwiftUI
import AppKit
import DigbyCore

/// Digby palette, taken from the website's tokens (sites/compressor): altitude navy → sky blue
/// with a warm dawn highlight used only for moments of arrival. Every colour adapts to dark mode.
enum Brand {
    /// Accent (buttons, selection, progress). Site `--accent`: #3A6AAE / #8FB6E8.
    static let accent = dynamic(light: 0x3A6AAE, dark: 0x8FB6E8)
    /// Dawn: arrival only (the convergence point, the "saved" figure). Site `--dawn-deep`: #C9774A / #F0B28C.
    static let dawn = dynamic(light: 0xC9774A, dark: 0xF0B28C)
    /// Fixed sky tones, the icon's gradient (site `--altitude`, `--sky`, `--haze`, `--dawn`).
    static let altitude = hex(0x0E1F3D)
    static let sky = hex(0x4D7DB8)
    static let haze = hex(0xBFD3EA)
    static let dawnFixed = hex(0xF2C2A0)
    /// Surfaces: the window canvas, cards on it, hairlines, muted text (site `--haze`, `--haze-card`, `--haze-line`, `--muted`).
    static let canvas = dynamic(light: 0xF4F6FA, dark: 0x0B1220)
    static let card = dynamic(light: 0xFFFFFF, dark: 0x111B30)
    static let line = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0.749, green: 0.827, blue: 0.918, alpha: 0.12)
                                                          : NSColor(srgbRed: 0.055, green: 0.122, blue: 0.239, alpha: 0.10)
    })
    static let muted = dynamic(light: 0x53627A, dark: 0x8F9DB3)
    /// Button fill: the accent with a touch of depth, like the site's solid buttons.
    static let gradient = LinearGradient(colors: [dynamic(light: 0x4274B8, dark: 0x9CC0EE), dynamic(light: 0x2F5E9E, dark: 0x7FA8DE)],
                                         startPoint: .top, endPoint: .bottom)
    /// Text on an accent fill.
    static let onAccent = dynamic(light: 0xFFFFFF, dark: 0x07112A)
    /// The app icon's colours: deep navy down to a dawn glow.
    static let skyGradient = LinearGradient(stops: [.init(color: hex(0x081430), location: 0), .init(color: hex(0x1D3E72), location: 0.48),
                                                    .init(color: hex(0x4F7FBE), location: 0.8), .init(color: hex(0xE7B898), location: 1)],
                                            startPoint: .top, endPoint: .bottom)
    static let good = dynamic(light: 0x2F7D5B, dark: 0x6FC79E)
    static let warn = dynamic(light: 0xC2770E, dark: 0xF2B45C)

    /// Corner radii (site: cards 18–26 px, controls 12–14 px, pills fully round).
    static let cardRadius: CGFloat = 16
    static let controlRadius: CGFloat = 10

    static func hex(_ v: UInt32) -> Color {
        Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { a in
            let v = a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        })
    }
}

/// Type that echoes the site (Hanken Grotesk display in light weights with tight tracking,
/// small uppercase eyebrows with wide tracking), set in SF.
extension Font {
    /// Large display text (site h1/h2: weight 200–300, letter-spacing ≈ −0.03em).
    static func display(_ size: CGFloat, weight: Font.Weight = .light) -> Font { .system(size: size, weight: weight) }
}

extension View {
    /// Tracking proportional to size, like CSS `em` letter-spacing.
    func tracking(em: CGFloat, size: CGFloat) -> some View { kerning(em * size) }
}

/// The Compressor's brand motif, from its icon: two chevrons pressing in from above and below
/// onto one bright line. `drift` lets them breathe; `settled` closes them in (a file dragged over).
struct CompressMotif: View {
    var settled: Bool = false
    var drift: Bool = false
    var color: Color = .white
    var lineColor: Color = Brand.dawnFixed

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !drift)) { tl in
            let t = drift ? tl.date.timeIntervalSinceReferenceDate : 0
            Canvas { ctx, size in
                let w = size.width, h = size.height, mid = h / 2
                // proportions from the icon: chevrons 388 wide, 132 deep, 84 thick; tips 96 from the line
                let unit = min(h / 760, w / 560)
                let halfW = 194 * unit, depth = 132 * unit, lw = max(2, 72 * unit)
                let breathe = t == 0 ? 0 : (sin(t * 1.1) + 1) / 2 * 14 * unit
                let gap = (settled ? 52 : 96) * unit - breathe
                for dir in [-1.0, 1.0] {                      // -1: from above, pointing down; 1: from below, pointing up
                    let tipY = mid + dir * gap
                    var c = Path()
                    c.move(to: CGPoint(x: w / 2 - halfW, y: tipY + dir * depth))
                    c.addLine(to: CGPoint(x: w / 2, y: tipY))
                    c.addLine(to: CGPoint(x: w / 2 + halfW, y: tipY + dir * depth))
                    ctx.stroke(c, with: .color(color.opacity(0.95)), style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
                }
                let barW = 424 * unit, barH = max(2, 30 * unit)
                let bar = Path(roundedRect: CGRect(x: w / 2 - barW / 2, y: mid - barH / 2, width: barW, height: barH), cornerRadius: barH / 2)
                ctx.drawLayer { g in g.addFilter(.blur(radius: 10 * unit + 4)); g.fill(bar, with: .color(lineColor.opacity(0.85))) }
                ctx.fill(bar, with: .color(lineColor))
            }
        }
        .animation(.easeInOut(duration: 0.4), value: settled)
        .accessibilityHidden(true)
    }
}

/// The app icon's mark: two chevrons pressing inward onto one bright dawn line.
struct ChevronMark: View {
    var color: Color = Brand.accent
    var lineColor: Color = Brand.dawn

    var body: some View {
        Canvas { ctx, size in
            let h = size.height, w = min(size.width, h * 1.6), x0 = (size.width - w) / 2
            let lw = h * 0.16, rise = h * 0.2
            for top in [true, false] {
                let yEdge = top ? lw / 2 : h - lw / 2, yTip = top ? yEdge + rise : yEdge - rise
                var p = Path()
                p.move(to: CGPoint(x: x0 + lw / 2, y: yEdge))
                p.addLine(to: CGPoint(x: x0 + w / 2, y: yTip))
                p.addLine(to: CGPoint(x: x0 + w - lw / 2, y: yEdge))
                ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
            }
            let bh = h * 0.08
            ctx.fill(Path(roundedRect: CGRect(x: x0 + w * 0.06, y: h / 2 - bh / 2, width: w * 0.88, height: bh), cornerRadius: bh / 2),
                     with: .color(lineColor))
        }
        .accessibilityHidden(true)
    }
}

/// Progress: a quiet track, an accent fill, and a dawn point where it has got to.
struct ConvergenceProgress: View {
    var fraction: Double
    var body: some View {
        GeometryReader { g in
            let f = max(0, min(1, fraction))
            ZStack(alignment: .leading) {
                Capsule().fill(Brand.accent.opacity(0.12)).frame(height: 6)
                Capsule().fill(Brand.gradient).frame(width: max(6, g.size.width * f), height: 6)
                Circle().fill(Brand.dawn).frame(width: 9, height: 9).offset(x: max(0, g.size.width * f - 9))
            }
            .frame(maxHeight: .infinity)
            .animation(.linear(duration: 0.25), value: fraction)
        }
        .frame(height: 22)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int(fraction * 100)) percent")
    }
}

/// Rounded, softly outlined container used for every section of the detail pane.
struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.card, in: RoundedRectangle(cornerRadius: Brand.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Brand.cardRadius, style: .continuous).strokeBorder(Brand.line, lineWidth: 1))
            .shadow(color: Brand.altitude.opacity(0.05), radius: 10, y: 3)
    }
}

struct SectionLabel: View {
    var title: String
    var systemImage: String
    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(em: 0.12, size: 10.5)
            .textCase(.uppercase)
            .foregroundStyle(Brand.muted).lineLimit(1)
            .labelStyle(.titleAndIcon)
    }
}

struct Chip: View {
    var text: String
    var systemImage: String? = nil
    var tint: Color = .secondary
    var body: some View {
        HStack(spacing: 4) {
            if let s = systemImage { Image(systemName: s).imageScale(.small) }
            Text(text)
        }
        .font(.system(size: 11.5, weight: .medium))
        .padding(.horizontal, 8).padding(.vertical, 3.5)
        .foregroundStyle(tint == .secondary ? Brand.muted : tint)
        .background(Capsule().fill((tint == .secondary ? Brand.muted : tint).opacity(0.11)))
    }
}

/// Big number + caption, used in the result summary.
struct StatTile: View {
    var title: String
    var value: String
    var caption: String? = nil
    var tint: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10.5, weight: .semibold)).textCase(.uppercase).foregroundStyle(Brand.muted).tracking(em: 0.12, size: 10.5)
            Text(value).font(.display(26, weight: .light)).tracking(em: -0.02, size: 26).monospacedDigit().foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.6)
            if let caption { Text(caption).font(.caption).foregroundStyle(Brand.muted).lineLimit(2) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Selectable capsule for presets (target sizes, quality levels).
struct PillButton: View {
    var title: String
    var systemImage: String? = nil
    var selected: Bool
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let s = systemImage { Image(systemName: s).imageScale(.small) }
                Text(title)
            }
                .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                .padding(.horizontal, 13).padding(.vertical, 6)
                .foregroundStyle(selected ? Brand.onAccent : Color.primary)
                .background(Capsule().fill(selected ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(Brand.muted.opacity(hover ? 0.16 : 0.09))))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: selected)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// The primary call to action.
struct ProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 22).padding(.vertical, 10)
            .foregroundStyle(enabled ? Brand.onAccent : Color.secondary)
            .background(Capsule().fill(enabled ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.gray.opacity(0.25))))
            .overlay(Capsule().strokeBorder(.white.opacity(enabled ? 0.18 : 0), lineWidth: 0.5).blendMode(.plusLighter))
            .contentShape(Capsule())
            .shadow(color: Brand.accent.opacity(enabled ? 0.3 : 0), radius: configuration.isPressed ? 2 : 8, y: configuration.isPressed ? 1 : 3)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct InfoRow: View {
    var systemImage: String
    var text: String
    var tint: Color = .secondary
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint).frame(width: 16)
            Text(text).font(.callout).foregroundStyle(Brand.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension QualityRating {
    var color: Color {
        switch self {
        case .excellent: return Brand.good
        case .veryGood: return Color(red: 0.35, green: 0.68, blue: 0.30)
        case .good: return .yellow
        case .fair: return .orange
        case .poor: return .red
        }
    }
}

extension Image {
    init(cgImage: CGImage) { self.init(decorative: cgImage, scale: 1) }
}

/// The empty-state and About panel: the icon's colours with the chevron motif.
struct SkyBand: View {
    var drift: Bool = false
    var settled: Bool = false
    var body: some View {
        ZStack {
            Brand.skyGradient
            RadialGradient(colors: [Brand.dawnFixed.opacity(0.45), .clear], center: UnitPoint(x: 0.8, y: 1), startRadius: 0, endRadius: 200)
            HStack {                                       // text sits bottom-left, so the motif goes right
                Spacer(minLength: 0)
                CompressMotif(settled: settled, drift: drift).frame(width: 200)
            }
            .padding(.vertical, 18).padding(.trailing, 28)
        }
        .accessibilityHidden(true)
    }
}

/// The Digby wordmark lockup (brand/README.md): "Digby" heavy with −0.05em tracking, a thin
/// vertical rule, then the product name in a regular weight, slightly dimmed.
struct DigbyLockup: View {
    var size: CGFloat = 25
    var color: Color = .white
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("Digby").font(.system(size: size, weight: .heavy)).tracking(em: -0.05, size: size)
            Rectangle().fill(color.opacity(0.32)).frame(width: 1, height: size * 0.72)
                .alignmentGuide(.firstTextBaseline) { $0.height + size * 0.02 }
                .padding(.leading, size * 0.6).padding(.trailing, size * 0.56)
            Text("Video Compressor").font(.system(size: size * 0.68, weight: .regular)).tracking(em: 0.005, size: size * 0.68)
                .foregroundStyle(color.opacity(0.78))
        }
        .foregroundStyle(color)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Digby Video Compressor")
    }
}
