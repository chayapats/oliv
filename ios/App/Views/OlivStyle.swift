import SwiftUI

enum OlivTheme {
    static let background = adaptive(light: 0xF4F4EC, dark: 0x141A13)
    static let surface = adaptive(light: 0xFEFEF8, dark: 0x20271E)
    static let inset = adaptive(light: 0xECEEE1, dark: 0x2A3326)
    static let ink = adaptive(light: 0x243321, dark: 0xEEF2E6)
    static let secondary = adaptive(light: 0x65715D, dark: 0xB0BCA5)
    static let olive = adaptive(light: 0x4D6139, dark: 0xC2D89F)
    static let oliveContrast = adaptive(light: 0xFFFFF9, dark: 0x24331C)
    static let line = adaptive(light: 0xD7DCCE, dark: 0x3F4B38)
    static let warm = adaptive(light: 0xF0E9D6, dark: 0x3C3524)
    static let warning = adaptive(light: 0x79591F, dark: 0xE7C680)

    private static func adaptive(light: UInt, dark: UInt) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

struct OlivCard<Content: View>: View {
    var padding: CGFloat = 22
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OlivTheme.surface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(OlivTheme.line.opacity(0.65), lineWidth: 1)
            }
    }
}

struct OlivPrimaryButtonStyle: ButtonStyle {
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(compact ? .subheadline.weight(.semibold) : .headline)
            .foregroundStyle(OlivTheme.oliveContrast)
            .padding(.horizontal, compact ? 18 : 24)
            .padding(.vertical, compact ? 12 : 17)
            .frame(maxWidth: compact ? nil : .infinity)
            .background(OlivTheme.olive, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.45)
    }
}

struct OlivSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(OlivTheme.ink)
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .frame(minHeight: 44)
            .background(OlivTheme.inset, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.65 : 1) : 0.45)
    }
}

struct Eyebrow: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.bold))
            .tracking(2.0)
            .foregroundStyle(OlivTheme.secondary)
    }
}

struct SectionHeading: View {
    let title: String
    var caption: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(OlivTheme.ink)
            if let caption {
                Text(caption)
                    .font(.subheadline)
                    .foregroundStyle(OlivTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct OlivDivider: View {
    var body: some View { Rectangle().fill(OlivTheme.line).frame(height: 1) }
}

struct OlivFieldModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.body)
            .foregroundStyle(OlivTheme.ink)
            .padding(14)
            .background(OlivTheme.background, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(OlivTheme.line, lineWidth: 1)
            }
    }
}

extension View {
    func olivField() -> some View { modifier(OlivFieldModifier()) }

    func olivScreen() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(OlivTheme.background)
            .foregroundStyle(OlivTheme.ink)
            .toolbarBackground(OlivTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let description: String

    var body: some View {
        VStack(spacing: 17) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(OlivTheme.olive)
                .frame(width: 74, height: 74)
                .background(OlivTheme.inset, in: Circle())
                .accessibilityHidden(true)
            Text(title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(description)
                .font(.subheadline)
                .foregroundStyle(OlivTheme.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 25)
        .padding(.vertical, 45)
    }
}

struct AudioWaveform: View {
    let level: Double
    let elapsed: TimeInterval
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Canvas { context, size in
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
            let count = 43
            let gap: CGFloat = 4
            let width = max(2, (size.width - CGFloat(count - 1) * gap) / CGFloat(count))
            let normalizedLevel = min(1, max(0, level))
            for index in 0..<count {
                let centerDistance = abs(Double(index - count / 2)) / Double(count / 2)
                let envelope = 0.28 + 0.72 * (1 - centerDistance)
                let time = reduceMotion ? 0 : elapsed
                let variation = 0.35 + 0.65 * abs(sin(Double(index) * 1.37 + time * 4.2))
                let baseline = active ? 7.0 : 4.0 + 12.0 * envelope * variation
                let height = min(size.height, baseline + (active ? normalizedLevel * size.height * envelope * variation : 0))
                let rect = CGRect(x: CGFloat(index) * (width + gap), y: (size.height - height) / 2, width: width, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .color(active ? OlivTheme.olive : OlivTheme.olive.opacity(0.28)))
            }
        }
        .frame(height: 72)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(active ? "Microphone level" : "Voice waveform")
        .accessibilityValue(active ? "\(Int(level * 100)) percent" : "Ready")
    }
}

struct MetadataPill: View {
    let symbol: String
    let text: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(OlivTheme.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(OlivTheme.inset, in: Capsule())
    }
}
