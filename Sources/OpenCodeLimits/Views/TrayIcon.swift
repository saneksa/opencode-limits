import AppKit
import OpenCodeLimitsCore

/// Draws the menu-bar status item in code: a single green ring showing the time
/// left until the 5-hour rolling window resets, with the selected meter's
/// percentage in the middle. Rendered at 2x for crispness on Retina.
enum TrayIcon {
    /// Convenience overload used by code that only has a meter to display.
    static func image(for meter: UsageMeter?) -> NSImage {
        image(for: meter, countdown: nil, now: Date())
    }

    static func image(
        for meter: UsageMeter?,
        countdown: UsageMeter?,
        now: Date
    ) -> NSImage {
        let pointSize: CGFloat = 22
        let scale: CGFloat = 2
        let pixelSize = Int(pointSize * scale)
        let size = NSSize(width: pointSize, height: pointSize)

        let percent: Int? = meter.map { min(max($0.percent, 0), 100) }

        // The ring is green for the reset countdown; a blocked selected meter
        // turns it red so the user can still see the rate limit at a glance.
        let ringColor: NSColor = (meter?.isRateLimited == true) ? .systemRed : .systemGreen

        // One decreasing arc: 1 = full 5 hours left, 0 = reset is due now.
        // The rolling meter drives it regardless of the selected meter.
        let countdownFraction: CGFloat? = {
            guard let countdown, let fraction = countdown.rollingWindowFraction(now: now) else { return nil }
            return CGFloat(min(max(fraction, 0), 1))
        }()

        guard let context = CGContext(
            data: nil,
            width: pixelSize,
            height: pixelSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return NSImage(size: size)
        }

        context.scaleBy(x: scale, y: scale)
        let center = CGPoint(x: pointSize / 2, y: pointSize / 2)

        // Faint grey track is always visible, even without a known reset time.
        strokeArc(
            in: context, center: center, radius: 8.6, lineWidth: 2.2,
            color: NSColor.disabledControlTextColor.withAlphaComponent(0.30),
            fraction: 1
        )
        if let fraction = countdownFraction {
            strokeArc(
                in: context, center: center, radius: 8.6, lineWidth: 2.2,
                color: ringColor,
                fraction: fraction
            )
        }

        // Centred digits (or an en dash while loading), drawn on top of the ring.
        // AppKit text drawing uses a fixed white fill for legibility on the
        // green/red arc; the neutral state uses grey.
        let label = percent.map(String.init) ?? "–"
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let fontSize: CGFloat
        switch label.count {
        case 1: fontSize = 8.0
        case 2: fontSize = 7.2
        case 3: fontSize = 5.8
        default: fontSize = 6.2
        }
        let font = NSFont.boldSystemFont(ofSize: fontSize)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: meter == nil ? NSColor.systemGray : NSColor.white,
        ]
        let text = NSAttributedString(string: label, attributes: attributes)
        let textSize = text.size()
        let origin = NSPoint(
            x: center.x - textSize.width / 2,
            y: center.y - textSize.height / 2
        )
        text.draw(at: origin)
        NSGraphicsContext.restoreGraphicsState()

        guard let imageRef = context.makeImage() else { return NSImage(size: size) }
        let image = NSImage(size: size)
        image.addRepresentation(NSBitmapImageRep(cgImage: imageRef))
        image.isTemplate = false
        return image
    }

    /// Draws a clockwise arc starting at 12 o'clock. A fraction of 1 is a full
    /// circle; a fraction of 0 draws nothing.
    private static func strokeArc(
        in context: CGContext,
        center: CGPoint,
        radius: CGFloat,
        lineWidth: CGFloat,
        color: NSColor,
        fraction: CGFloat
    ) {
        guard fraction > 0 else { return }
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setStrokeColor(color.cgColor)
        let start = CGFloat.pi / 2
        let end = start - min(fraction, 1) * 2 * .pi
        context.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
        context.strokePath()
    }
}
