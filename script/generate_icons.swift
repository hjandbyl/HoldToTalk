import AppKit
import Foundation

let rootURL = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
let resourcesURL = rootURL.appendingPathComponent("Sources/HoldToTalk/Resources", isDirectory: true)
let iconsetURL = resourcesURL.appendingPathComponent("AppIcon.iconset", isDirectory: true)

try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: alpha
        )
    }
}

private func withShadow(_ color: NSColor, blur: CGFloat, offset: NSSize, draw: () -> Void) {
    let shadow = NSShadow()
    shadow.shadowColor = color
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = offset
    shadow.set()
    draw()
    NSShadow().set()
}

private func withClip(_ path: NSBezierPath, draw: () -> Void) {
    NSGraphicsContext.current?.saveGraphicsState()
    path.addClip()
    draw()
    NSGraphicsContext.current?.restoreGraphicsState()
}

private func image(size: Int, draw: @escaping (NSRect) -> Void) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
        NSGraphicsContext.current?.imageInterpolation = .high
        NSColor.clear.setFill()
        rect.fill()
        draw(rect)
        return true
    }
}

private func writePNG(_ image: NSImage, to url: URL) throws {
    guard
        let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let data = bitmap.representation(using: .png, properties: [:])
    else {
        throw NSError(domain: "IconGeneration", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not render \(url.lastPathComponent)"])
    }

    try data.write(to: url, options: .atomic)
}

private func drawAppIcon(in rect: NSRect) {
    let s = rect.width / 1024

    func scaled(_ value: CGFloat) -> CGFloat { value * s }
    func r(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
        NSRect(x: scaled(x), y: scaled(y), width: scaled(width), height: scaled(height))
    }

    let enclosure = NSBezierPath(
        roundedRect: r(72, 72, 880, 880),
        xRadius: scaled(214),
        yRadius: scaled(214)
    )

    withShadow(NSColor.black.withAlphaComponent(0.24), blur: scaled(34), offset: NSSize(width: 0, height: scaled(18))) {
        NSColor.black.withAlphaComponent(0.12).setFill()
        enclosure.fill()
    }

    NSGradient(colorsAndLocations:
        (NSColor(hex: 0xf7fbfa), 0.0),
        (NSColor(hex: 0xe3ece9), 0.48),
        (NSColor(hex: 0xbfd2ce), 1.0)
    )?.draw(in: enclosure, angle: 90)

    NSColor.white.withAlphaComponent(0.62).setStroke()
    enclosure.lineWidth = scaled(3)
    enclosure.stroke()

    let innerGlow = NSBezierPath(roundedRect: r(118, 114, 788, 788), xRadius: scaled(178), yRadius: scaled(178))
    NSColor(hex: 0xffffff, alpha: 0.22).setStroke()
    innerGlow.lineWidth = scaled(8)
    innerGlow.stroke()

    let base = NSBezierPath(roundedRect: r(206, 442, 612, 292), xRadius: scaled(108), yRadius: scaled(108))
    withShadow(NSColor.black.withAlphaComponent(0.32), blur: scaled(30), offset: NSSize(width: 0, height: scaled(22))) {
        NSGradient(colors: [NSColor(hex: 0x4b5358), NSColor(hex: 0x171b1f)])?.draw(in: base, angle: -90)
    }

    let keyTop = NSBezierPath(roundedRect: r(238, 382, 548, 304), xRadius: scaled(92), yRadius: scaled(92))
    NSGradient(colorsAndLocations:
        (NSColor(hex: 0x495258), 0.0),
        (NSColor(hex: 0x2a3034), 0.52),
        (NSColor(hex: 0x191d20), 1.0)
    )?.draw(in: keyTop, angle: 90)

    NSColor.white.withAlphaComponent(0.16).setStroke()
    keyTop.lineWidth = scaled(3)
    keyTop.stroke()

    let lowerLip = NSBezierPath(roundedRect: r(274, 636, 476, 32), xRadius: scaled(16), yRadius: scaled(16))
    NSGradient(colors: [NSColor(hex: 0x131719), NSColor(hex: 0x0b0d0e)])?.draw(in: lowerLip, angle: -90)

    let highlight = NSBezierPath(roundedRect: r(316, 462, 392, 38), xRadius: scaled(19), yRadius: scaled(19))
    NSColor(hex: 0x58d4ca, alpha: 0.86).setFill()
    highlight.fill()

    let highlightGlow = NSBezierPath(roundedRect: r(296, 450, 432, 64), xRadius: scaled(32), yRadius: scaled(32))
    NSColor(hex: 0x58d4ca, alpha: 0.14).setFill()
    highlightGlow.fill()

    let micCapsule = NSBezierPath(roundedRect: r(422, 236, 180, 270), xRadius: scaled(90), yRadius: scaled(90))
    withShadow(NSColor.black.withAlphaComponent(0.22), blur: scaled(18), offset: NSSize(width: 0, height: scaled(10))) {
        NSGradient(colors: [NSColor(hex: 0xffffff), NSColor(hex: 0xdcebea)])?.draw(in: micCapsule, angle: 90)
    }

    NSColor(hex: 0x1d2428, alpha: 0.28).setStroke()
    micCapsule.lineWidth = scaled(4)
    micCapsule.stroke()

    let stem = NSBezierPath()
    stem.move(to: NSPoint(x: scaled(512), y: scaled(504)))
    stem.line(to: NSPoint(x: scaled(512), y: scaled(594)))
    stem.lineCapStyle = .round
    NSColor(hex: 0xf4fbfa).setStroke()
    stem.lineWidth = scaled(40)
    stem.stroke()

    let baseLine = NSBezierPath()
    baseLine.move(to: NSPoint(x: scaled(444), y: scaled(616)))
    baseLine.line(to: NSPoint(x: scaled(580), y: scaled(616)))
    baseLine.lineCapStyle = .round
    NSColor(hex: 0xf4fbfa).setStroke()
    baseLine.lineWidth = scaled(38)
    baseLine.stroke()

    for x in [302, 358, 414] {
        let notch = NSBezierPath(roundedRect: r(CGFloat(x), 562, 36, 36), xRadius: scaled(10), yRadius: scaled(10))
        NSColor.white.withAlphaComponent(0.64).setFill()
        notch.fill()
    }
}

private func drawMenuBarIcon(kind: String, in rect: NSRect) {
    let s = rect.width / 36
    func scaled(_ value: CGFloat) -> CGFloat { value * s }
    func r(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
        NSRect(x: scaled(x), y: scaled(y), width: scaled(width), height: scaled(height))
    }

    NSColor.black.setFill()
    NSColor.black.setStroke()

    let capsule = NSBezierPath(roundedRect: r(13, 4, 10, 16), xRadius: scaled(5), yRadius: scaled(5))
    capsule.fill()

    let yoke = NSBezierPath()
    yoke.move(to: NSPoint(x: scaled(9), y: scaled(13)))
    yoke.curve(
        to: NSPoint(x: scaled(27), y: scaled(13)),
        controlPoint1: NSPoint(x: scaled(9), y: scaled(23)),
        controlPoint2: NSPoint(x: scaled(27), y: scaled(23))
    )
    yoke.lineCapStyle = .round
    yoke.lineWidth = scaled(3)
    yoke.stroke()

    let stem = NSBezierPath()
    stem.move(to: NSPoint(x: scaled(18), y: scaled(22)))
    stem.line(to: NSPoint(x: scaled(18), y: scaled(27)))
    stem.lineCapStyle = .round
    stem.lineWidth = scaled(3)
    stem.stroke()

    let key = NSBezierPath(roundedRect: r(8, 27, 20, 6), xRadius: scaled(2.4), yRadius: scaled(2.4))
    key.fill()

    if kind == "Recording" {
        NSBezierPath(ovalIn: r(25, 5, 6, 6)).fill()
    } else if kind == "Transcribing" {
        for (x, height) in [(5.0, 6.0), (28.0, 6.0)] {
            let bar = NSBezierPath(roundedRect: r(CGFloat(x), 13, 3, CGFloat(height)), xRadius: scaled(1.5), yRadius: scaled(1.5))
            bar.fill()
        }
    }
}

let masterIcon = image(size: 1024, draw: drawAppIcon)
try writePNG(masterIcon, to: resourcesURL.appendingPathComponent("AppIcon.png"))

let iconSizes: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (filename, size) in iconSizes {
    try writePNG(image(size: size, draw: drawAppIcon), to: iconsetURL.appendingPathComponent(filename))
}

for kind in ["Idle", "Recording", "Transcribing"] {
    try writePNG(
        image(size: 36) { drawMenuBarIcon(kind: kind, in: $0) },
        to: resourcesURL.appendingPathComponent("MenuBarIcon\(kind)Template.png")
    )
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = [
    "-c",
    "icns",
    iconsetURL.path,
    "-o",
    resourcesURL.appendingPathComponent("AppIcon.icns").path
]
try iconutil.run()
iconutil.waitUntilExit()
if iconutil.terminationStatus != 0 {
    throw NSError(
        domain: "IconGeneration",
        code: Int(iconutil.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: "iconutil failed to generate AppIcon.icns"]
    )
}
