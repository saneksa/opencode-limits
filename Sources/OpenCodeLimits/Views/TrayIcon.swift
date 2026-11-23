import AppKit
import OpenCodeLimitsCore

/// Draws the menu-bar status item in code: an outer progress ring for the
/// selected meter and an optional inner countdown ring for the rolling window.
/// Rendered at 2x for crispness on Retina.
enum TrayIcon {
    /// Convenience overload used by code that only has a meter to display.
    static func image(for meter: UsageMeter?) -> NSImage {
        image(for: meter, countdown: nil, now: Date(), showCountdown: false)
    }

    static func image(
        for meter: UsageMeter?,
        countdown: UsageMeter?,
        now: Date,
        showCountdown: Bool
    ) -> NSImage {
        let pointSize: CGFloat = 22
        let scale: CGFloat = 2
        let pixelSize = Int(pointSize * scale)
        let size = NSSize(width: pointSize, height: pointSize)

        let percent: Int? = meter.map { min(max($0.percent, 0), 100) }
        let ringColor: NSColor
        if let meter, meter.isRateLimited {
            ringColor = .systemRed
        } else if let meter, meter.isCritical {
            // Follows the configurable warnThreshold instead of a hardcoded 85.
            ringColor = .systemRed
        } else if let p = percent, p >= 60 {
            ringColor = .systemOrange
        } else if percent != nil {
            ringColor = .systemGreen
        } else {
            ringColor = .systemGray
        }

        // The inner ring is driven by the rolling meter regardless of which
        // meter was selected for the outer ring.
        let innerFraction: CGFloat? = {
            guard showCountdown, let countdown else { return nil }
            guard let fraction = countdown.rollingWindowFraction(now: now) else { return nil }
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

        // Outer ring: faint track plus selected-meter progress.
        strokeArc(
            in: context, center: center, radius: 8.6, lineWidth: 2.2,
            color: NSColor.disabledControlTextColor.withAlphaComponent(0.30),
            fraction: 1
        )
        strokeArc(
            in: context, center: center, radius: 8.6, lineWidth: 2.2,
            color: ringColor,
            fraction: CGFloat(percent ?? 0) / 100
        )

        // Inner ring: decreasing remaining-time arc with its own grey track.
        if let innerFraction {
            strokeArc(
                in: context, center: center, radius: 6.0, lineWidth: 1.3,
                color: NSColor.systemGray.withAlphaComponent(0.25),
                fraction: 1
            )
            strokeArc(
                in: context, center: center, radius: 6.0, lineWidth: 1.3,
                color: NSColor.systemTeal.withAlphaComponent(0.9),
                fraction: innerFraction
            )
        }

        // Centered digits (or an en dash while loading), drawn last so neither
        // ring overlaps the label. AppKit text drawing uses adaptive label color.
        let label = percent.map(String.init) ?? "–"
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        // "100" must fit inside the inner countdown ring's clear aperture,
        // otherwise the digits would cover the teal arc.
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
            .foregroundColor: NSColor.labelColor,
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
