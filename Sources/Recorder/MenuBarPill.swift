import AppKit

struct MenuBarPill: Equatable {
    enum Sign: Equatable {
        case dot
        case pause
    }

    static let height: CGFloat = 18
    static let fontSize: CGFloat = 11.5
    static let dot: CGFloat = 7
    static let gap: CGFloat = 6
    static let leading: CGFloat = (height - dot) / 2
    static let trailing: CGFloat = 9
    static let pauseBar = CGSize(width: 2.4, height: 7.5)
    static let pauseBarGap: CGFloat = 2.2

    static let live = NSColor(srgbRed: 0xB3 / 255, green: 0x1D / 255, blue: 0x3D / 255, alpha: 1)
    static let onLive = NSColor.white
    static let paused = NSColor(srgbRed: 0xE1 / 255, green: 0xB9 / 255, blue: 0x32 / 255, alpha: 1)
    static let onPaused = NSColor(srgbRed: 0x17 / 255, green: 0x21 / 255, blue: 0x2B / 255, alpha: 1)

    static var font: NSFont { NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold) }

    let sign: Sign
    let clock: String

    init?(state: RecorderState, elapsed: TimeInterval) {
        switch state {
        case .recording: sign = .dot
        case .paused: sign = .pause
        case .idle, .preparing, .finishing: return nil
        }
        clock = Self.clock(elapsed)
    }

    static func clock(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var accessibilityLabel: String { "\(sign == .dot ? "Recording" : "Paused"), \(clock)" }

    var width: CGFloat {
        let text = (clock as NSString).size(withAttributes: [.font: Self.font]).width
        return (Self.leading + Self.dot + Self.gap + text + Self.trailing).rounded(.up)
    }

    private var fill: NSColor { sign == .dot ? Self.live : Self.paused }
    private var ink: NSColor { sign == .dot ? Self.onLive : Self.onPaused }

    func image(scale: CGFloat) -> NSImage {
        let size = NSSize(width: width, height: Self.height)
        let image = NSImage(size: size)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: Int((size.width * scale).rounded(.up)), height: Int((size.height * scale).rounded(.up)),
                bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return image }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let rendered = context.makeImage() else { return image }
        let bitmap = NSBitmapImageRep(cgImage: rendered)
        bitmap.size = size
        image.addRepresentation(bitmap)
        image.isTemplate = false
        return image
    }

    private func draw(in bounds: CGRect) {
        let radius = bounds.height / 2
        let capsule = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        fill.setFill()
        capsule.fill()
        let centre = CGPoint(x: radius, y: radius)
        switch sign {
        case .dot:
            Self.onLive.setFill()
            NSBezierPath(ovalIn: CGRect(x: centre.x - Self.dot / 2, y: centre.y - Self.dot / 2, width: Self.dot, height: Self.dot)).fill()
        case .pause:
            ink.setFill()
            let bar = Self.pauseBar
            let span = bar.width * 2 + Self.pauseBarGap
            for index in 0..<2 {
                let x = centre.x - span / 2 + CGFloat(index) * (bar.width + Self.pauseBarGap)
                let rect = CGRect(x: x, y: centre.y - bar.height / 2, width: bar.width, height: bar.height)
                NSBezierPath(roundedRect: rect, xRadius: bar.width / 2, yRadius: bar.width / 2).fill()
            }
        }
        NSGraphicsContext.saveGraphicsState()
        capsule.addClip()
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: ink]
        let text = clock as NSString
        let height = text.size(withAttributes: attributes).height
        text.draw(at: CGPoint(x: Self.leading + Self.dot + Self.gap, y: (bounds.height - height) / 2), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }
}
