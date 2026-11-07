import AppKit

/// Renders a custom Retina vector template icon for the macOS Menu Bar (Tray)
/// matching VolumeGuard's minimalist logo: a speaker cone on the left, acoustic
/// waves in the center, and the right-half protective shield silhouette on the right.
enum MenuBarIconRenderer {
    static func makeIcon(volume: Float, isMuted: Bool, isEnabled: Bool) -> NSImage {
        let size = NSSize(width: 20, height: 16)
        let img = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setAllowsAntialiasing(true)
            ctx.setShouldAntialias(true)

            let primaryColor = NSColor.black
            let dimmedColor = NSColor.black.withAlphaComponent(0.32)

            // 1. Speaker Cone (Left side: x 1.2 -> 8.2, y 3.0 -> 13.0)
            let speakerPath = NSBezierPath()
            // Rear box of speaker
            speakerPath.move(to: NSPoint(x: 2.2, y: 5.8))
            speakerPath.line(to: NSPoint(x: 4.5, y: 5.8))
            // Lower cone flare
            speakerPath.line(to: NSPoint(x: 7.6, y: 3.1))
            speakerPath.curve(
                to: NSPoint(x: 8.3, y: 3.5),
                controlPoint1: NSPoint(x: 7.9, y: 2.9),
                controlPoint2: NSPoint(x: 8.3, y: 3.1)
            )
            // Vertical front face of cone
            speakerPath.line(to: NSPoint(x: 8.3, y: 12.5))
            speakerPath.curve(
                to: NSPoint(x: 7.6, y: 12.9),
                controlPoint1: NSPoint(x: 8.3, y: 12.9),
                controlPoint2: NSPoint(x: 7.9, y: 13.1)
            )
            // Upper cone flare
            speakerPath.line(to: NSPoint(x: 4.5, y: 10.2))
            speakerPath.line(to: NSPoint(x: 2.2, y: 10.2))
            speakerPath.curve(
                to: NSPoint(x: 1.3, y: 9.3),
                controlPoint1: NSPoint(x: 1.6, y: 10.2),
                controlPoint2: NSPoint(x: 1.3, y: 9.8)
            )
            speakerPath.line(to: NSPoint(x: 1.3, y: 6.7))
            speakerPath.curve(
                to: NSPoint(x: 2.2, y: 5.8),
                controlPoint1: NSPoint(x: 1.3, y: 6.2),
                controlPoint2: NSPoint(x: 1.6, y: 5.8)
            )
            speakerPath.close()
            primaryColor.setFill()
            speakerPath.fill()

            // 2. Acoustic Waves (Center: radiating from (8.2, 8.0))
            let waveCenter = NSPoint(x: 8.2, y: 8.0)
            let effectivelyMuted = !isEnabled || isMuted || volume <= 0.001

            // Inner wave arc
            let innerWave = NSBezierPath()
            innerWave.appendArc(
                withCenter: waveCenter,
                radius: 2.9,
                startAngle: -38,
                endAngle: 38,
                clockwise: false
            )
            innerWave.lineWidth = 1.45
            innerWave.lineCapStyle = .round
            if effectivelyMuted {
                dimmedColor.setStroke()
            } else {
                primaryColor.setStroke()
            }
            innerWave.stroke()

            // Outer wave arc
            let outerWave = NSBezierPath()
            outerWave.appendArc(
                withCenter: waveCenter,
                radius: 5.3,
                startAngle: -40,
                endAngle: 40,
                clockwise: false
            )
            outerWave.lineWidth = 1.45
            outerWave.lineCapStyle = .round
            if effectivelyMuted || volume < 0.45 {
                dimmedColor.setStroke()
            } else {
                primaryColor.setStroke()
            }
            outerWave.stroke()

            // 3. Right-Half Protective Shield Silhouette (x 10.0 -> 18.2, y 1.3 -> 14.7)
            let shieldPath = NSBezierPath()
            shieldPath.move(to: NSPoint(x: 10.2, y: 14.6))
            // Top shield crest curving down-right to outer corner
            shieldPath.curve(
                to: NSPoint(x: 18.0, y: 12.8),
                controlPoint1: NSPoint(x: 12.6, y: 13.6),
                controlPoint2: NSPoint(x: 15.4, y: 13.0)
            )
            // Upper-right vertical wall of shield
            shieldPath.line(to: NSPoint(x: 18.0, y: 8.2))
            // Lower-right curve tapering to bottom shield tip
            shieldPath.curve(
                to: NSPoint(x: 10.2, y: 1.4),
                controlPoint1: NSPoint(x: 18.0, y: 4.6),
                controlPoint2: NSPoint(x: 14.5, y: 2.4)
            )
            shieldPath.lineWidth = 1.65
            shieldPath.lineCapStyle = .round
            shieldPath.lineJoinStyle = .round
            primaryColor.setStroke()
            shieldPath.stroke()

            // 4. Mute Slash when muted or disabled
            if effectivelyMuted {
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: 2.0, y: 13.8))
                slash.line(to: NSPoint(x: 15.5, y: 2.2))
                slash.lineWidth = 1.6
                slash.lineCapStyle = .round
                primaryColor.setStroke()
                slash.stroke()
            }

            return true
        }
        img.isTemplate = true
        return img
    }
}
