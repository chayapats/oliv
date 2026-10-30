import UIKit
import CoreText

/// A compact floating preview with the measured iOS 27 font and key gap.
/// The shorter cap reduces host-visible headroom without shrinking the glyph.
/// It stays inside the extension; the pressed key remains separate and visible.
final class KeyboardPopupView: UIView {
    struct Style {
        var capWidth: CGFloat = 58.333
        var capHeight: CGFloat = 35.667
        var keyGap: CGFloat = 3
        var capRadius: CGFloat = 14.5
        var font: UIFont = .systemFont(ofSize: 36)
        var fill: UIColor = .white
        var bottomFill: UIColor = .white
        var foreground: UIColor = .black
        var shadowRadius: CGFloat = 5
        var borderColor: UIColor = .clear
        var usesThaiMetrics = false
    }

    private let shape = CAShapeLayer()
    private let gradient = CAGradientLayer()
    private let label = KeyboardMarkLabel()

    init(text: String, keyFrame: CGRect, containment: CGRect, style: Style) {
        let available = containment.insetBy(dx: 0, dy: 2)
        let width = min(available.width, max(style.capWidth, keyFrame.width + 12))
        let height = min(available.height, style.capHeight)
        let x = min(max(available.minX, keyFrame.midX - width / 2), available.maxX - width)
        // Keep previews inside the extension's public primary-view boundary.
        // Standard layouts reserve headroom for the full first-row cap and
        // three-point gap; retain this guard for smaller/unmeasured bounds.
        let top = min(available.maxY - height,
                      max(available.minY, keyFrame.minY - style.keyGap - height))
        super.init(frame: CGRect(x: x, y: top, width: width, height: height))
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        backgroundColor = .clear
        layer.addSublayer(shape)
        addSubview(label)

        shape.frame = bounds
        shape.path = UIBezierPath(roundedRect: bounds, cornerRadius: style.capRadius).cgPath
        shape.fillColor = style.fill.cgColor
        // A single local shadow also shades the depressed key beneath the cap.
        // It needs no blur view, offscreen screenshot or per-frame work.
        shape.shadowColor = UIColor.black.cgColor
        shape.shadowOpacity = 0.12
        shape.shadowRadius = style.shadowRadius
        shape.shadowOffset = CGSize(width: 0, height: 2)
        shape.shadowPath = shape.path
        gradient.frame = bounds
        gradient.cornerRadius = style.capRadius
        gradient.cornerCurve = .circular
        gradient.borderWidth = 0.5
        gradient.borderColor = style.borderColor.cgColor
        gradient.colors = [style.fill.cgColor, style.bottomFill.cgColor]
        layer.insertSublayer(gradient, above: shape)

        label.frame = bounds
        label.isCompactPreview = true
        label.usesThaiKeycapMetrics = style.usesThaiMetrics
        label.referenceScale = style.font.pointSize / 24
        label.text = text
        label.font = KeyboardMarkLabel.keycapFont(for: text, size: style.font.pointSize)
        label.textColor = style.foreground
        label.textAlignment = .center
        label.numberOfLines = 1
        label.isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { nil }

    func applyColors(fill: UIColor, bottomFill: UIColor, foreground: UIColor, shadowRadius: CGFloat, borderColor: UIColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.fillColor = fill.cgColor
        gradient.colors = [fill.cgColor, bottomFill.cgColor]
        gradient.borderColor = borderColor.cgColor
        shape.shadowRadius = shadowRadius
        label.textColor = foreground
        CATransaction.commit()
    }
}

/// Optical alignment from actual native keycaps. Core Text supplies public
/// system glyphs; a hidden shaping anchor removes isolated Thai dotted circles.
/// Glyph outlines are cached per label/text/font, and their aspect ratio stays
/// intact when fitting the observed ink bounds. Inserted text is never changed.
final class KeyboardMarkLabel: UILabel {
    var isCompactPreview = false
    var usesThaiKeycapMetrics = false { didSet { setNeedsDisplay() } }
    var englishKeycapPage: KeyboardPage? { didSet { setNeedsDisplay() } }
    var referenceScale: CGFloat = 1 { didSet { setNeedsDisplay() } }
    var usesLandscapeMetrics = false {
        didSet {
            guard oldValue != usesLandscapeMetrics else { return }
            cachedText = nil
            setNeedsDisplay()
        }
    }
    private var cachedText: String?
    private var cachedFont: UIFont?
    private var cachedOutline: CGPath?
    private var controlMetric: InkMetric?
    private var landscapeControlMetric: InkMetric?
    private var effectiveControlMetric: InkMetric? { usesLandscapeMetrics ? (landscapeControlMetric ?? controlMetric) : controlMetric }

    func setPageControl(target: KeyboardPage?, source: KeyboardPage, language: KeyboardLanguage) {
        let metric: InkMetric?
        switch target {
        case .letters:
            metric = language == .thai ? .init(24.334, 8, -0.166, 1.167) : .init(33.666, 13.333, -0.166, -0.834)
        case .numbers where source == .letters:
            metric = .init(27.334, 13.333, 0.334, language == .thai ? -0.333 : -0.834)
        case .numbers: metric = .init(23.667, 11.333, -0.5, 0.166)
        case .symbols: metric = .init(23.667, 7.667, -0.833, -0.666)
        case nil: metric = nil
        }
        let landscapeMetric: InkMetric?
        switch target {
        case .letters:
            landscapeMetric = language == .thai ? .init(24.334, 8, -0.666, 0.667) : .init(33.667, 13.333, -0.333, -0.666)
        case .numbers where source == .letters:
            landscapeMetric = language == .thai ? .init(23.666, 11.333, -0.166, 0.166) : .init(23.667, 11.333, 0, 0.334)
        case .numbers: landscapeMetric = .init(23.667, 11.333, -0.166, -0.334)
        case .symbols: landscapeMetric = .init(23.666, 7.667, -0.5, -1.166)
        case nil: landscapeMetric = nil
        }
        guard metric != controlMetric || landscapeMetric != landscapeControlMetric else { return }
        controlMetric = metric
        landscapeControlMetric = landscapeMetric
        cachedText = nil
        setNeedsDisplay()
    }

    /// Measured native Thai uses the lighter public system face. Sara Am is
    /// kept at regular: its circle-free, anchored form matched the reference
    /// more closely than the light face. English retains its existing weight.
    static func keycapFont(for text: String, size: CGFloat) -> UIFont {
        let scalar = text.unicodeScalars.count == 1 ? text.unicodeScalars.first : nil
        let lightThai = scalar.map { (0x0E00...0x0E7F).contains($0.value) && $0.value != 0x0E33 } ?? false
        return .systemFont(ofSize: size, weight: lightThai ? .light : .regular)
    }

    static func isIsolatedThaiMark(_ text: String) -> Bool {
        guard let scalar = text.unicodeScalars.first, text.unicodeScalars.count == 1 else { return false }
        return scalar.value == 0x0E33 // Sara Am also receives a dotted circle in isolation.
            || ((0x0E00...0x0E7F).contains(scalar.value) && scalar.properties.generalCategory == .nonspacingMark)
    }

    static func hasThaiKeycapMetrics(_ text: String) -> Bool {
        text.unicodeScalars.count == 1 && text.unicodeScalars.first.map { measuredThaiInk[$0.value] != nil } == true
    }

    static func hasEnglishKeycapMetrics(_ text: String, page: KeyboardPage) -> Bool {
        guard text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first else { return false }
        return englishMetric(scalar.value, page: page) != nil
    }

    private static func englishMetrics(_ page: KeyboardPage) -> [UInt32: InkMetric] {
        switch page {
        case .letters: measuredEnglishLettersInk
        case .numbers: measuredEnglishNumbersInk
        case .symbols: measuredEnglishSymbolsInk
        }
    }

    private static func englishMetric(_ scalar: UInt32, page: KeyboardPage) -> InkMetric? {
        if page != .letters && scalar == 0x0E3F { return .init(11, 18.667, 0.167, -1.167) }
        return englishMetrics(page)[scalar]
            ?? (page == .symbols && scalar == 0x24 ? measuredEnglishNumbersInk[scalar] : nil)
    }

    override func drawText(in rect: CGRect) {
        guard let text, let scalar = text.unicodeScalars.first else {
            super.drawText(in: rect)
            return
        }
        let metric: InkMetric?
        if let effectiveControlMetric { metric = effectiveControlMetric }
        else if usesThaiKeycapMetrics || Self.isIsolatedThaiMark(text) {
            metric = usesLandscapeMetrics ? Self.landscapeThaiInk[scalar.value] : Self.measuredThaiInk[scalar.value]
        } else if let englishKeycapPage {
            if usesLandscapeMetrics {
                switch englishKeycapPage {
                case .letters: metric = Self.landscapeEnglishLettersInk[scalar.value]
                case .numbers: metric = Self.landscapeEnglishNumbersInk[scalar.value]
                case .symbols: metric = Self.landscapeEnglishSymbolsInk[scalar.value]
                }
            } else { metric = Self.englishMetric(scalar.value, page: englishKeycapPage) }
        }
        else { metric = nil }
        guard (metric != nil || Self.isIsolatedThaiMark(text) || isCompactPreview),
              let context = UIGraphicsGetCurrentContext(), let outline = glyphOutline(for: text) else {
            super.drawText(in: rect)
            return
        }
        let sourceBounds = outline.boundingBoxOfPath
        let factor = referenceScale
        var targetCenter: CGPoint
        let uniformScale: CGFloat
        if let metric {
            targetCenter = CGPoint(x: bounds.midX + metric.center.x * factor,
                                   y: bounds.midY + metric.center.y * factor)
            uniformScale = min(metric.size.width * factor / sourceBounds.width,
                               metric.size.height * factor / sourceBounds.height)
        } else {
            let below = ["ุ", "ู", "ฺ"].contains(text)
            uniformScale = 1
            targetCenter = CGPoint(x: bounds.midX,
                                   y: bounds.midY + (isCompactPreview ? 0 : (below ? 5 : -5) * factor))
        }
        if isCompactPreview {
            // Use actual ink, not the font's ascender/descender line box.
            // Preserve Thai mark placement unless it would touch the cap edge;
            // translating the glyph never changes its measured size.
            let halfHeight = sourceBounds.height * uniformScale / 2
            targetCenter.y = min(bounds.maxY - 2 - halfHeight,
                                 max(bounds.minY + 2 + halfHeight, targetCenter.y))
        }
        context.saveGState()
        context.setFillColor(textColor.cgColor)
        context.translateBy(x: targetCenter.x, y: targetCenter.y)
        context.scaleBy(x: uniformScale, y: -uniformScale)
        context.translateBy(x: -sourceBounds.midX, y: -sourceBounds.midY)
        context.addPath(outline)
        context.fillPath()
        context.restoreGState()
    }

    private func glyphOutline(for text: String) -> CGPath? {
        if cachedText == text, cachedFont == font { return cachedOutline }
        let anchored = Self.isIsolatedThaiMark(text)
        func makeOutline(kern: CGFloat = 0) -> CGMutablePath {
            let source = NSAttributedString(string: (anchored ? "ก" : "") + text,
                                            attributes: [.font: font as Any, .kern: kern])
            let line = CTLineCreateWithAttributedString(source)
            let outline = CGMutablePath()
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let count = CTRunGetGlyphCount(run)
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                var indices = [CFIndex](repeating: 0, count: count)
                CTRunGetGlyphs(run, CFRange(), &glyphs)
                CTRunGetPositions(run, CFRange(), &positions)
                CTRunGetStringIndices(run, CFRange(), &indices)
                let attributes = CTRunGetAttributes(run) as NSDictionary
                let runFont = attributes[kCTFontAttributeName] as! CTFont
                for index in 0..<count where !anchored || indices[index] > 0 {
                    if let path = CTFontCreatePathForGlyph(runFont, glyphs[index], nil) {
                        outline.addPath(path, transform: CGAffineTransform(translationX: positions[index].x,
                                                                          y: positions[index].y))
                    }
                }
            }
            return outline
        }
        var outline = makeOutline()
        if let controlMetric = effectiveControlMetric, text.count > 1, !outline.isEmpty {
            let natural = outline.boundingBoxOfPath
            let desiredWidth = natural.height * controlMetric.size.width / controlMetric.size.height
            let kern = (desiredWidth - natural.width) / CGFloat(text.count - 1)
            // Native multi-character page labels have their own tracking.
            // Match it by spacing glyphs; never stretch a glyph horizontally.
            if abs(kern) <= font.pointSize * 0.3 { outline = makeOutline(kern: kern) }
        }
        cachedText = text
        cachedFont = font
        let sourceBounds = outline.boundingBoxOfPath
        cachedOutline = outline.isEmpty || sourceBounds.width <= 0 || sourceBounds.height <= 0 ? nil : outline.copy()
        return cachedOutline
    }

    private struct InkMetric: Equatable {
        let size: CGSize
        let center: CGPoint
        init(_ width: CGFloat, _ height: CGFloat, _ x: CGFloat, _ y: CGFloat) {
            size = CGSize(width: width, height: height)
            center = CGPoint(x: x, y: y)
        }
    }

    // Native Thai, both letter/shift pages: iPhone 17 / iOS 27 / 402pt @3x.
    // Center offsets are relative to each actual key center, not a fixed grid.
    // Raster measurements have ±1px tolerance; uniform fit avoids distortion.
    private static let measuredThaiInk: [UInt32: InkMetric] = [
        0x0E45: .init(9.667, 17.666, -1.500, -0.166), // ๅ
        0x002F: .init(7.667, 17.333, -0.334, -1.000), // /
        0x005F: .init(12.000, 2.000, -0.167, 12.001), // _
        0x0E20: .init(12.666, 13.666, -1.500, -0.166), // ภ
        0x0E16: .init(10.667, 13.666, -1.000, -0.166), // ถ
        0x0E38: .init(5.666, 7.334, 0.000, 5.334), // ุ
        0x0E36: .init(15.334, 7.667, 0.500, -6.833), // ึ
        0x0E04: .init(12.000, 13.333, 0.167, -0.333), // ค
        0x0E15: .init(12.333, 13.333, -1.500, -0.333), // ต
        0x0E08: .init(10.667, 13.666, 0.166, -0.166), // จ
        0x0E02: .init(11.000, 13.000, -1.000, -0.166), // ข
        0x0E0A: .init(13.334, 13.667, -0.500, -0.500), // ช
        0x0E46: .init(10.000, 18.333, -1.001, 0.666), // ๆ
        0x0E44: .init(11.333, 20.000, -1.166, 0.833), // ไ
        0x0E33: .init(13.000, 18.333, -0.667, -0.666), // ำ
        0x0E1E: .init(13.333, 13.333, -1.166, 1.834), // พ
        0x0E30: .init(9.334, 12.000, -0.334, 1.500), // ะ
        0x0E31: .init(12.000, 6.000, -0.167, -3.833), // ั
        0x0E35: .init(14.667, 7.333, 0.166, -6.166), // ี
        0x0E23: .init(10.333, 13.333, 0.334, 0.834), // ร
        0x0E19: .init(12.000, 13.333, -0.334, 0.834), // น
        0x0E22: .init(11.000, 13.334, 0.333, 0.500), // ย
        0x0E1A: .init(12.334, 13.334, -1.000, 0.500), // บ
        0x0E25: .init(10.666, 13.667, -0.500, 0.666), // ล
        0x0E1F: .init(13.334, 18.333, -1.334, -0.833), // ฟ
        0x0E2B: .init(12.666, 13.333, -0.500, 1.667), // ห
        0x0E01: .init(10.667, 13.334, -1.166, 0.334), // ก
        0x0E14: .init(11.334, 13.334, -0.500, 0.334), // ด
        0x0E40: .init(4.666, 14.333, 0.666, 2.167), // เ
        0x0E49: .init(11.000, 8.000, 0.667, -4.999), // ้
        0x0E48: .init(2.000, 6.000, -0.500, -5.999), // ่
        0x0E32: .init(9.667, 13.667, -1.334, 1.500), // า
        0x0E2A: .init(11.667, 14.667, -0.167, 1.000), // ส
        0x0E27: .init(9.667, 13.667, -0.666, 0.500), // ว
        0x0E07: .init(8.333, 13.000, -1.334, 0.501), // ง
        0x0E03: .init(10.667, 13.334, -1.166, 0.334), // ฃ
        0x0E1C: .init(10.333, 13.334, -0.666, 1.500), // ผ
        0x0E1B: .init(12.333, 18.334, -0.666, -1.000), // ป
        0x0E41: .init(11.000, 13.334, -0.333, 1.500), // แ
        0x0E2D: .init(10.667, 13.334, 0.000, 1.500), // อ
        0x0E34: .init(14.333, 6.334, 0.334, -6.000), // ิ
        0x0E37: .init(14.667, 7.334, 0.166, -6.500), // ื
        0x0E17: .init(12.000, 13.000, -0.500, 0.333), // ท
        0x0E21: .init(11.667, 13.334, -1.167, 0.500), // ม
        0x0E43: .init(10.333, 19.333, -0.666, 0.834), // ใ
        0x0E1D: .init(10.334, 18.334, 0.000, -1.000), // ฝ
        0x002B: .init(11.000, 11.666, 0.499, -1.166), // +
        0x0E51: .init(12.000, 10.666, -0.500, 2.334), // ๑
        0x0E52: .init(14.666, 13.666, -0.500, 0.834), // ๒
        0x0E53: .init(13.333, 10.666, -0.834, 2.334), // ๓
        0x0E54: .init(12.333, 13.666, 0.500, 0.834), // ๔
        0x0E39: .init(10.000, 7.334, 0.167, 5.334), // ู
        0x0E3F: .init(11.000, 18.667, 0.000, -1.000), // ฿
        0x0E55: .init(12.667, 13.666, 0.166, 0.834), // ๕
        0x0E56: .init(12.334, 13.666, -0.834, 0.834), // ๖
        0x0E57: .init(17.333, 13.666, 1.166, 0.834), // ๗
        0x0E58: .init(12.667, 13.666, 0.166, 0.834), // ๘
        0x0E59: .init(13.667, 13.666, 0.334, 0.834), // ๙
        0x0E50: .init(11.333, 10.667, -1.000, 1.166), // ๐
        0x0022: .init(7.000, 5.667, -0.667, -5.334), // "
        0x0E0E: .init(12.667, 19.333, -0.166, 2.166), // ฎ
        0x0E11: .init(13.667, 13.334, -1.334, 0.500), // ฑ
        0x0E18: .init(10.333, 13.000, -0.167, 0.667), // ธ
        0x0E4D: .init(6.000, 6.333, 0.167, -5.334), // ํ
        0x0E4A: .init(12.000, 7.000, -0.500, -5.333), // ๊
        0x0E13: .init(17.333, 13.667, 0.166, 0.666), // ณ
        0x0E2F: .init(10.333, 13.666, -0.500, 2.000), // ฯ
        0x0E0D: .init(16.667, 19.000, -0.834, 2.333), // ญ
        0x0E10: .init(12.000, 19.000, 0.167, 2.333), // ฐ
        0x002C: .init(3.333, 6.333, -0.166, 10.666), // ,
        0x0E24: .init(10.666, 17.667, -1.334, 2.500), // ฤ
        0x0E06: .init(12.000, 14.000, -0.833, 0.334), // ฆ
        0x0E0F: .init(12.333, 19.000, -0.334, 1.834), // ฏ
        0x0E42: .init(10.334, 19.333, 0.000, 1.000), // โ
        0x0E0C: .init(16.333, 13.334, -0.500, -0.666), // ฌ
        0x0E47: .init(13.334, 10.333, 0.500, -4.833), // ็
        0x0E4B: .init(8.334, 6.667, 0.000, -5.333), // ๋
        0x0E29: .init(16.000, 13.333, 1.500, 1.667), // ษ
        0x0E28: .init(12.000, 14.667, -0.666, 1.000), // ศ
        0x0E0B: .init(13.666, 13.667, 0.000, 0.167), // ซ
        0x002E: .init(3.000, 3.000, 0.333, 9.166), // .
        0x0E05: .init(11.333, 13.334, -0.834, 0.334), // ฅ
        0x0028: .init(4.666, 19.667, 0.500, -0.666), // (
        0x0029: .init(5.000, 19.667, -1.333, -0.666), // )
        0x0E09: .init(11.333, 13.667, -0.834, 0.334), // ฉ
        0x0E2E: .init(11.000, 14.000, 0.499, 1.167), // ฮ
        0x0E3A: .init(3.666, 3.667, 0.000, 6.334), // ฺ
        0x0E4C: .init(9.334, 8.667, 0.500, -5.834), // ์
        0x003F: .init(9.333, 16.000, -0.166, -0.833), // ?
        0x0E12: .init(17.666, 14.000, -0.834, 0.500), // ฒ
        0x0E2C: .init(15.334, 16.667, 0.500, -0.166), // ฬ
        0x0E26: .init(12.667, 18.000, -0.834, 2.500), // ฦ
    ]

    // Same iPhone 17 / iOS 27 reference, separate English letter/number/symbol pages.
    private static let measuredEnglishLettersInk: [UInt32: InkMetric] = [
        0x0071: .init(11.000, 17.333, 0.166, 2.166), // q
        0x0077: .init(17.000, 13.000, -0.001, 0.000), // w
        0x0065: .init(10.666, 13.333, 0.334, 0.166), // e
        0x0072: .init(6.334, 13.000, 0.666, 0.000), // r
        0x0074: .init(6.666, 16.333, 0.334, -1.334), // t
        0x0079: .init(11.333, 17.667, -0.167, 2.334), // y
        0x0075: .init(10.333, 13.333, 0.167, 0.166), // u
        0x0069: .init(2.666, 17.333, 0.166, -2.166), // i
        0x006F: .init(11.000, 13.333, 0.166, 0.166), // o
        0x0070: .init(11.000, 17.333, -0.001, 2.166), // p
        0x0061: .init(10.000, 13.333, -0.666, 0.166), // a
        0x0073: .init(10.000, 13.333, 0.166, 0.166), // s
        0x0064: .init(11.000, 18.000, -0.499, -2.167), // d
        0x0066: .init(6.666, 17.667, 0.166, -2.334), // f
        0x0067: .init(11.000, 17.667, -0.499, 2.334), // g
        0x0068: .init(10.666, 17.667, 0.166, -2.334), // h
        0x006A: .init(5.000, 22.000, -1.499, 0.167), // j
        0x006B: .init(10.333, 17.667, 1.333, -2.334), // k
        0x006C: .init(2.333, 17.667, -0.500, -2.334), // l
        0x007A: .init(9.667, 13.000, 0.333, 0.000), // z
        0x0078: .init(11.333, 13.000, -0.333, 0.000), // x
        0x0063: .init(10.333, 13.333, 0.333, 0.166), // c
        0x0076: .init(11.333, 13.000, -0.333, 0.000), // v
        0x0062: .init(11.333, 18.000, 0.500, -2.167), // b
        0x006E: .init(10.667, 13.000, -0.333, 0.000), // n
        0x006D: .init(17.667, 13.000, 0.333, 0.000), // m
        0x0051: .init(12.667, 17.334, 0.000, -0.500), // Q
        0x0057: .init(18.667, 15.333, -0.167, -1.166), // W
        0x0045: .init(9.334, 15.333, 0.334, -1.166), // E
        0x0052: .init(11.000, 15.333, 0.334, -1.166), // R
        0x0054: .init(11.667, 15.333, 0.167, -1.166), // T
        0x0059: .init(12.333, 15.333, 0.000, -1.166), // Y
        0x0055: .init(11.667, 15.666, 0.167, -1.000), // U
        0x0049: .init(2.333, 15.333, 0.000, -1.166), // I
        0x004F: .init(12.666, 16.000, 0.334, -1.167), // O
        0x0050: .init(10.667, 15.333, 0.500, -1.166), // P
        0x0041: .init(13.000, 15.333, -0.499, -1.166), // A
        0x0053: .init(11.334, 16.000, 0.166, -1.167), // S
        0x0044: .init(12.000, 15.333, 0.001, -1.166), // D
        0x0046: .init(9.333, 15.333, 0.833, -1.166), // F
        0x0047: .init(12.333, 16.000, -0.500, -1.167), // G
        0x0048: .init(12.000, 15.333, 0.166, -1.166), // H
        0x004A: .init(9.000, 15.666, -1.166, -1.000), // J
        0x004B: .init(11.667, 15.333, 1.000, -1.166), // K
        0x004C: .init(9.334, 15.333, 0.334, -1.166), // L
        0x005A: .init(11.000, 15.333, 0.334, -1.166), // Z
        0x0058: .init(12.667, 15.333, -0.333, -1.166), // X
        0x0043: .init(12.000, 16.000, 0.166, -1.167), // C
        0x0056: .init(13.334, 15.333, -0.666, -1.166), // V
        0x0042: .init(11.333, 15.333, 0.833, -1.166), // B
        0x004E: .init(12.000, 15.333, -0.334, -1.166), // N
        0x004D: .init(14.333, 15.333, 0.000, -1.166), // M
    ]

    private static let measuredEnglishNumbersInk: [UInt32: InkMetric] = [
        0x0031: .init(6.000, 15.333, -0.334, -1.166), // 1
        0x0032: .init(10.000, 15.667, 0.166, -1.334), // 2
        0x0033: .init(10.666, 16.000, 0.334, -1.167), // 3
        0x0034: .init(11.334, 15.333, 0.166, -1.166), // 4
        0x0035: .init(11.000, 15.666, 0.501, -1.000), // 5
        0x0036: .init(11.000, 16.000, -0.001, -1.167), // 6
        0x0037: .init(10.000, 15.333, 0.001, -1.166), // 7
        0x0038: .init(11.000, 16.000, -0.334, -1.167), // 8
        0x0039: .init(11.000, 16.000, 0.501, -1.167), // 9
        0x0030: .init(11.000, 16.000, -0.001, -1.167), // 0
        0x002D: .init(7.333, 2.000, 0.000, -1.500), // -
        0x002F: .init(7.667, 17.333, 0.000, -1.166), // /
        0x003A: .init(3.334, 12.666, 0.334, 1.500), // :
        0x003B: .init(3.667, 13.666, -0.667, 3.000), // ;
        0x0028: .init(4.667, 19.666, 1.000, -1.000), // (
        0x0029: .init(5.000, 19.666, -1.001, -1.000), // )
        0x0024: .init(10.666, 18.667, 0.334, -1.166), // $
        0x0040: .init(17.000, 17.667, 0.501, -0.666), // @
        0x0022: .init(7.000, 5.666, -0.334, -6.000), // "
        0x002E: .init(3.000, 3.000, 0.501, 8.333), // .
        0x002C: .init(3.333, 6.334, -0.333, 10.000), // ,
        0x003F: .init(9.333, 16.000, -0.333, -1.167), // ?
        0x0021: .init(2.666, 15.666, 0.334, -1.000), // !
        0x0027: .init(3.333, 5.666, 0.000, -6.000), // '
        0x0026: .init(13.667, 16.000, 0.333, -1.167), // &
    ]

    private static let measuredEnglishSymbolsInk: [UInt32: InkMetric] = [
        0x005B: .init(5.333, 19.666, 1.000, -1.000), // [
        0x005D: .init(5.334, 19.666, -0.834, -1.000), // ]
        0x007B: .init(7.000, 19.666, 0.166, -1.000), // {
        0x007D: .init(7.000, 19.666, -0.001, -1.000), // }
        0x0023: .init(15.000, 18.000, 0.501, -1.500), // #
        0x0025: .init(15.333, 16.333, -0.167, -1.334), // %
        0x005E: .init(7.334, 6.333, 0.334, -5.666), // ^
        0x002A: .init(9.667, 10.333, 0.000, -1.334), // *
        0x002B: .init(11.000, 11.667, 0.501, -1.334), // +
        0x003D: .init(9.667, 6.000, 0.000, -1.500), // =
        0x005F: .init(12.000, 2.000, 0.334, 11.833), // _
        0x005C: .init(7.667, 17.333, 0.000, -1.166), // \
        0x007C: .init(2.000, 17.333, 0.001, -1.166), // |
        0x007E: .init(11.000, 4.334, -0.334, -1.000), // ~
        0x003C: .init(10.000, 12.666, 0.334, -1.500), // <
        0x003E: .init(10.000, 12.666, 0.166, -1.500), // >
        0x20AC: .init(10.667, 16.000, 0.000, -1.167), // €
        0x00A3: .init(10.333, 15.667, 0.000, -1.334), // £
        0x00A5: .init(12.000, 15.333, 0.001, -1.166), // ¥
        0x2022: .init(7.000, 7.333, -0.001, -1.166), // •
        0x002E: .init(3.000, 3.000, 0.501, 8.333), // .
        0x002C: .init(3.333, 6.334, -0.333, 10.000), // ,
        0x003F: .init(9.333, 16.000, -0.333, -1.167), // ?
        0x0021: .init(2.666, 15.666, 0.334, -1.000), // !
        0x0027: .init(3.333, 5.666, 0.000, -6.000), // '
    ]

    // Independently measured landscape glyphs, not scaled portrait fonts.
    private static let landscapeEnglishLettersInk: [UInt32: InkMetric] = [
        0x0071: .init(10.000, 15.333, -0.166, 1.666), // q
        0x0077: .init(15.000, 11.334, -0.500, 0.000), // w
        0x0065: .init(9.667, 12.000, -0.333, 0.000), // e
        0x0072: .init(5.667, 11.667, 0.834, -0.166), // r
        0x0074: .init(6.000, 14.333, 0.166, -1.166), // t
        0x0079: .init(10.000, 15.334, -0.166, 2.000), // y
        0x0075: .init(9.333, 11.667, -0.666, 0.166), // u
        0x0069: .init(2.334, 15.334, -0.666, -2.000), // i
        0x006F: .init(10.000, 12.000, 0.333, 0.000), // o
        0x0070: .init(9.667, 15.333, 0.667, 1.666), // p
        0x0061: .init(8.667, 12.000, -0.500, 0.000), // a
        0x0073: .init(8.667, 12.000, -0.500, 0.000), // s
        0x0064: .init(9.667, 16.000, -0.166, -2.000), // d
        0x0066: .init(6.000, 15.667, 0.501, -2.166), // f
        0x0067: .init(9.666, 16.000, -0.500, 2.000), // g
        0x0068: .init(9.333, 15.667, 0.167, -2.166), // h
        0x006A: .init(4.334, 19.334, -1.666, 0.000), // j
        0x006B: .init(9.000, 15.667, 0.833, -2.166), // k
        0x006C: .init(2.000, 15.667, 0.166, -2.166), // l
        0x007A: .init(8.333, 11.334, -0.333, 0.000), // z
        0x0078: .init(9.667, 11.334, 0.166, 0.000), // x
        0x0063: .init(9.333, 12.000, 0.167, 0.000), // c
        0x0076: .init(10.000, 11.334, 0.000, 0.000), // v
        0x0062: .init(9.666, 16.000, 0.334, -2.000), // b
        0x006E: .init(9.334, 11.667, -0.166, -0.166), // n
        0x006D: .init(15.333, 11.667, 0.334, -0.166), // m
        0x0051: .init(11.000, 15.333, 0.001, 0.666), // Q
        0x0057: .init(16.334, 13.334, -0.500, 0.000), // W
        0x0045: .init(8.333, 13.334, -0.333, 0.000), // E
        0x0052: .init(9.666, 13.334, 0.500, 0.000), // R
        0x0054: .init(10.000, 13.334, 0.166, 0.000), // T
        0x0059: .init(10.666, 13.334, -0.166, 0.000), // Y
        0x0055: .init(10.334, 13.667, -0.500, 0.166), // U
        0x0049: .init(2.000, 13.334, -0.499, 0.000), // I
        0x004F: .init(11.000, 14.000, 0.167, 0.000), // O
        0x0050: .init(9.333, 13.334, 0.500, 0.000), // P
        0x0041: .init(11.334, 13.334, -0.166, 0.000), // A
        0x0053: .init(10.000, 14.000, -0.499, 0.000), // S
        0x0044: .init(10.667, 13.334, 0.666, 0.000), // D
        0x0046: .init(8.333, 13.334, 0.667, 0.000), // F
        0x0047: .init(10.333, 14.000, -0.166, 0.000), // G
        0x0048: .init(10.666, 13.334, -0.166, 0.000), // H
        0x004A: .init(7.667, 13.667, -1.000, 0.166), // J
        0x004B: .init(10.333, 13.334, 0.834, 0.000), // K
        0x004C: .init(8.333, 13.334, 0.667, 0.000), // L
        0x005A: .init(9.666, 13.334, -0.666, 0.000), // Z
        0x0058: .init(11.000, 13.334, 0.167, 0.000), // X
        0x0043: .init(10.334, 14.000, 0.334, 0.000), // C
        0x0056: .init(11.667, 13.334, -0.166, 0.000), // V
        0x0042: .init(10.000, 13.334, 0.166, 0.000), // B
        0x004E: .init(10.334, 13.334, -0.666, 0.000), // N
        0x004D: .init(12.333, 13.334, 0.166, 0.000), // M
    ]

    private static let landscapeThaiInk: [UInt32: InkMetric] = [
        0x0E45: .init(6.666, 13.000, -0.666, 0.667), // ๅ
        0x002F: .init(5.000, 13.667, -0.499, 0.334), // /
        0x005F: .init(9.000, 1.333, 0.333, 10.166), // _
        0x0E20: .init(9.333, 10.000, -1.000, 0.833), // ภ
        0x0E16: .init(8.000, 10.000, -0.666, 0.833), // ถ
        0x0E38: .init(4.333, 5.333, 0.167, 4.834), // ุ
        0x0E36: .init(11.000, 5.333, -0.333, -4.166), // ึ
        0x0E04: .init(8.666, 9.667, -0.666, 0.666), // ค
        0x0E15: .init(9.000, 9.667, -0.834, 0.666), // ต
        0x0E08: .init(8.000, 10.000, -0.334, 0.833), // จ
        0x0E02: .init(7.667, 9.667, -0.666, 0.666), // ข
        0x0E0A: .init(9.667, 10.000, -0.500, 0.500), // ช
        0x0E46: .init(7.334, 13.333, -0.666, 0.834), // ๆ
        0x0E44: .init(8.333, 14.334, -0.500, 1.000), // ไ
        0x0E33: .init(9.333, 13.333, 0.166, -0.166), // ำ
        0x0E1E: .init(9.667, 9.667, -0.833, 1.666), // พ
        0x0E30: .init(6.666, 8.666, 0.334, 1.500), // ะ
        0x0E31: .init(8.667, 4.666, -0.333, -2.500), // ั
        0x0E35: .init(10.666, 5.333, -0.500, -4.166), // ี
        0x0E23: .init(7.333, 10.000, 0.000, 0.833), // ร
        0x0E19: .init(9.000, 10.000, -0.499, 0.833), // น
        0x0E22: .init(8.000, 9.667, 0.666, 0.666), // ย
        0x0E1A: .init(9.000, 9.667, -1.000, 0.666), // บ
        0x0E25: .init(7.667, 10.000, -0.500, 0.833), // ล
        0x0E1F: .init(9.666, 13.333, -0.166, -0.166), // ฟ
        0x0E2B: .init(9.334, 9.667, -0.666, 1.666), // ห
        0x0E01: .init(8.000, 9.667, -0.167, 0.666), // ก
        0x0E14: .init(8.000, 9.667, -0.999, 0.666), // ด
        0x0E40: .init(3.333, 10.667, 0.667, 2.166), // เ
        0x0E49: .init(8.000, 5.667, 0.334, -3.334), // ้
        0x0E48: .init(1.667, 4.334, -0.666, -4.000), // ่
        0x0E32: .init(7.000, 10.000, -0.499, 1.500), // า
        0x0E2A: .init(8.333, 10.667, -0.500, 1.166), // ส
        0x0E27: .init(6.667, 10.000, 0.000, 0.833), // ว
        0x0E07: .init(6.000, 9.667, -0.500, 0.666), // ง
        0x0E03: .init(8.000, 9.667, -0.999, 0.666), // ฃ
        0x0E1C: .init(7.667, 9.667, 0.167, 1.666), // ผ
        0x0E1B: .init(9.000, 13.333, -1.000, -0.166), // ป
        0x0E41: .init(7.667, 9.667, 0.167, 1.666), // แ
        0x0E2D: .init(7.667, 9.667, -0.833, 1.666), // อ
        0x0E34: .init(10.667, 4.667, -0.333, -3.834), // ิ
        0x0E37: .init(10.666, 5.333, -0.500, -4.166), // ื
        0x0E17: .init(9.000, 9.667, -1.166, 0.666), // ท
        0x0E21: .init(8.333, 10.000, -0.500, 0.833), // ม
        0x0E43: .init(7.334, 14.000, -0.666, 1.167), // ใ
        0x0E1D: .init(7.666, 13.333, 0.000, -0.166), // ฝ
        0x002B: .init(7.666, 8.334, -0.166, 0.000), // +
        0x0E51: .init(8.666, 7.667, 0.334, 2.666), // ๑
        0x0E52: .init(10.667, 10.000, -0.834, 1.500), // ๒
        0x0E53: .init(9.667, 7.667, -0.500, 2.666), // ๓
        0x0E54: .init(9.000, 10.000, 0.166, 1.500), // ๔
        0x0E39: .init(7.000, 5.333, 0.166, 4.834), // ู
        0x0E3F: .init(7.667, 13.000, 0.334, 0.000), // ฿
        0x0E55: .init(9.334, 10.000, 0.334, 1.500), // ๕
        0x0E56: .init(8.667, 10.000, -1.000, 1.500), // ๖
        0x0E57: .init(12.333, 10.000, 0.500, 1.500), // ๗
        0x0E58: .init(9.333, 10.000, 0.834, 1.500), // ๘
        0x0E59: .init(10.334, 10.000, -0.166, 1.500), // ๙
        0x0E50: .init(8.333, 8.000, -0.500, 1.167), // ๐
        0x0022: .init(6.000, 4.667, -0.334, -2.834), // "
        0x0E0E: .init(9.000, 14.000, -0.667, 1.833), // ฎ
        0x0E11: .init(10.000, 9.667, -0.999, 0.666), // ฑ
        0x0E18: .init(7.667, 9.667, 0.167, 0.666), // ธ
        0x0E4D: .init(4.667, 4.666, -0.333, -3.500), // ํ
        0x0E4A: .init(8.667, 5.000, 0.166, -3.667), // ๊
        0x0E13: .init(12.667, 10.000, -0.333, 0.833), // ณ
        0x0E2F: .init(7.667, 10.000, -0.500, 1.833), // ฯ
        0x0E0D: .init(11.666, 13.666, -0.166, 2.000), // ญ
        0x0E10: .init(9.000, 13.666, -0.667, 2.000), // ฐ
        0x002C: .init(2.667, 5.000, -0.333, 9.000), // ,
        0x0E24: .init(8.000, 13.000, -0.666, 2.333), // ฤ
        0x0E06: .init(8.667, 10.333, -1.000, 0.666), // ฆ
        0x0E0F: .init(9.000, 14.000, -0.667, 1.833), // ฏ
        0x0E42: .init(7.334, 14.000, -0.666, 1.167), // โ
        0x0E0C: .init(12.000, 9.666, -0.999, 0.000), // ฌ
        0x0E47: .init(9.667, 7.333, 0.167, -3.166), // ็
        0x0E4B: .init(6.000, 4.666, 0.167, -3.500), // ๋
        0x0E29: .init(11.667, 9.667, 0.167, 1.666), // ษ
        0x0E28: .init(8.667, 10.667, 0.000, 1.166), // ศ
        0x0E0B: .init(9.667, 10.000, 0.167, 0.500), // ซ
        0x002E: .init(2.334, 2.333, 0.000, 7.666), // .
        0x0E05: .init(8.334, 9.667, -1.166, 0.666), // ฅ
        0x0028: .init(3.333, 14.000, 0.000, 0.167), // (
        0x0029: .init(3.667, 14.000, -0.334, 0.167), // )
        0x0E09: .init(8.334, 10.000, -0.166, 0.833), // ฉ
        0x0E2E: .init(8.333, 10.333, -0.500, 1.334), // ฮ
        0x0E3A: .init(2.333, 2.667, 0.500, 5.166), // ฺ
        0x0E4C: .init(6.666, 6.333, -0.500, -3.666), // ์
        0x003F: .init(6.666, 11.333, 0.334, 0.166), // ?
        0x0E12: .init(13.000, 10.000, -0.834, 0.833), // ฒ
        0x0E2C: .init(11.000, 12.000, 0.166, 0.500), // ฬ
        0x0E26: .init(9.333, 13.000, -0.834, 2.333), // ฦ
    ]

    private static let landscapeEnglishNumbersInk: [UInt32: InkMetric] = [
        0x0031: .init(5.000, 13.334, -0.666, 0.000), // 1
        0x0032: .init(9.000, 13.667, -0.500, -0.166), // 2
        0x0033: .init(9.000, 14.000, -0.666, 0.000), // 3
        0x0034: .init(10.333, 13.334, 0.166, 0.000), // 4
        0x0035: .init(9.333, 13.667, 0.500, 0.166), // 5
        0x0036: .init(9.667, 14.000, -0.333, 0.000), // 6
        0x0037: .init(8.667, 13.334, -0.334, 0.000), // 7
        0x0038: .init(9.667, 14.000, -0.333, 0.000), // 8
        0x0039: .init(9.333, 14.000, 0.334, 0.000), // 9
        0x0030: .init(9.333, 14.000, 0.167, 0.000), // 0
        0x002D: .init(6.333, 1.667, -0.333, -0.166), // -
        0x002F: .init(6.667, 15.334, -0.334, 0.000), // /
        0x003A: .init(2.667, 11.333, -0.500, 2.334), // :
        0x003B: .init(3.000, 12.000, -0.167, 3.667), // ;
        0x0028: .init(4.333, 17.334, 1.000, 0.000), // (
        0x0029: .init(4.333, 17.334, -1.000, 0.000), // )
        0x0024: .init(9.667, 16.000, -0.166, 0.000), // $
        0x0026: .init(12.000, 14.000, -0.166, 0.000), // &
        0x0040: .init(15.000, 15.666, 0.167, 0.500), // @
        0x0022: .init(6.000, 4.667, 0.166, -4.334), // "
        0x002E: .init(2.666, 2.667, -0.500, 8.666), // .
        0x002C: .init(3.000, 5.667, -0.667, 10.166), // ,
        0x003F: .init(8.000, 14.000, -0.334, 0.000), // ?
        0x0021: .init(2.334, 13.667, 0.000, 0.166), // !
        0x0027: .init(2.667, 4.667, 0.166, -4.334), // '
        0x0E3F: .init(9.333, 16.000, -0.334, 0.000), // ฿
    ]

    private static let landscapeEnglishSymbolsInk: [UInt32: InkMetric] = [
        0x005B: .init(4.667, 17.334, 0.500, 0.000), // [
        0x005D: .init(4.666, 17.334, -1.000, 0.000), // ]
        0x007B: .init(6.000, 17.334, -0.499, 0.000), // {
        0x007D: .init(6.000, 17.334, 0.333, 0.000), // }
        0x0023: .init(13.667, 16.000, 0.000, -0.333), // #
        0x0025: .init(13.334, 14.333, -0.166, -0.166), // %
        0x005E: .init(6.667, 5.667, -0.666, -3.834), // ^
        0x002A: .init(8.334, 9.000, -0.666, -0.167), // *
        0x002B: .init(9.666, 10.000, 0.500, 0.000), // +
        0x003D: .init(8.333, 5.333, 0.000, -0.334), // =
        0x005F: .init(10.666, 2.000, -0.166, 11.667), // _
        0x005C: .init(6.667, 15.334, -0.334, 0.000), // \
        0x007C: .init(1.666, 15.334, -0.666, 0.000), // |
        0x007E: .init(9.667, 4.000, 0.166, 0.000), // ~
        0x003C: .init(8.334, 11.000, 0.334, -0.500), // <
        0x003E: .init(8.333, 11.000, 0.000, -0.500), // >
        0x20AC: .init(9.000, 14.000, -0.500, 0.000), // €
        0x00A3: .init(9.000, 13.667, -0.666, -0.166), // £
        0x00A5: .init(10.333, 13.334, 0.166, 0.000), // ¥
        0x2022: .init(6.333, 6.000, 0.000, 0.000), // •
        0x002E: .init(2.666, 2.667, -0.500, 8.666), // .
        0x002C: .init(3.000, 5.667, -0.667, 10.166), // ,
        0x003F: .init(8.000, 14.000, -0.334, 0.000), // ?
        0x0021: .init(2.334, 13.667, 0.000, 0.166), // !
        0x0027: .init(2.667, 4.667, 0.166, -4.334), // '
        0x0024: .init(9.667, 16.000, -0.166, 0.000), // $
    ]
}
