import AppKit
import Foundation

let arguments = CommandLine.arguments.dropFirst()
let rootURL = URL(fileURLWithPath: arguments.first(where: { !$0.hasPrefix("--") }) ?? FileManager.default.currentDirectoryPath)
let appIconOnly = arguments.contains("--app-icon-only")
let assetsURL = rootURL.appendingPathComponent("HoldToTalk/Assets.xcassets", isDirectory: true)
let appIconURL = assetsURL.appendingPathComponent("AppIcon.appiconset", isDirectory: true)

try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: appIconURL, withIntermediateDirectories: true)

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

private func colorAssetHex(named name: String) throws -> UInt32 {
    let url = assetsURL
        .appendingPathComponent("\(name).colorset", isDirectory: true)
        .appendingPathComponent("Contents.json")

    guard
        let data = try? Data(contentsOf: url),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let colors = json["colors"] as? [[String: Any]],
        let color = colors.first?["color"] as? [String: Any],
        let components = color["components"] as? [String: String],
        let red = Double(components["red"] ?? ""),
        let green = Double(components["green"] ?? ""),
        let blue = Double(components["blue"] ?? "")
    else {
        throw NSError(
            domain: "IconGeneration",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Could not read color asset \(name)"]
        )
    }

    let r = UInt32((red * 255).rounded()).clamped(to: 0...255)
    let g = UInt32((green * 255).rounded()).clamped(to: 0...255)
    let b = UInt32((blue * 255).rounded()).clamped(to: 0...255)
    return (r << 16) | (g << 8) | b
}

extension Comparable {
    fileprivate func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}

let recordingAccentHex = try colorAssetHex(named: "RecordingAccent")
let recordingAccentHighlightHex = try colorAssetHex(named: "RecordingAccentHighlight")

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

    withShadow(NSColor.black.withAlphaComponent(0.32), blur: scaled(40), offset: NSSize(width: 0, height: scaled(22))) {
        NSColor.black.withAlphaComponent(0.18).setFill()
        enclosure.fill()
    }

    NSGradient(colorsAndLocations:
        (NSColor(hex: 0x2a2226), 0.0),
        (NSColor(hex: 0x181317), 0.56),
        (NSColor(hex: 0x100c10), 1.0)
    )?.draw(in: enclosure, angle: 90)

    NSColor.white.withAlphaComponent(0.12).setStroke()
    enclosure.lineWidth = scaled(2)
    enclosure.stroke()

    let innerRim = NSBezierPath(roundedRect: r(116, 112, 792, 792), xRadius: scaled(184), yRadius: scaled(184))
    NSColor.white.withAlphaComponent(0.045).setStroke()
    innerRim.lineWidth = scaled(6)
    innerRim.stroke()

    let waveBars: [(CGFloat, CGFloat, CGFloat)] = [
        (386, 478, 250),
        (512, 478, 334),
        (638, 478, 250)
    ]

    for (x, centerY, height) in waveBars {
        let bar = NSBezierPath(
            roundedRect: r(x - 29, centerY - height / 2, 58, height),
            xRadius: scaled(29),
            yRadius: scaled(29)
        )

        withShadow(NSColor.black.withAlphaComponent(0.24), blur: scaled(18), offset: NSSize(width: 0, height: scaled(12))) {
            NSGradient(colorsAndLocations:
                (NSColor(hex: 0xffffff), 0.0),
                (NSColor(hex: 0xf0f5ff), 0.50),
                (NSColor(hex: 0xd9e2f0), 1.0)
            )?.draw(in: bar, angle: 90)
        }

        NSColor.white.withAlphaComponent(0.18).setStroke()
        bar.lineWidth = scaled(2)
        bar.stroke()
    }

    let holdGlow = NSBezierPath(roundedRect: r(388, 666, 248, 62), xRadius: scaled(31), yRadius: scaled(31))
    NSColor(hex: recordingAccentHex, alpha: 0.12).setFill()
    holdGlow.fill()

    let holdLine = NSBezierPath(roundedRect: r(428, 684, 168, 22), xRadius: scaled(11), yRadius: scaled(11))
    withShadow(NSColor(hex: recordingAccentHex, alpha: 0.28), blur: scaled(15), offset: NSSize(width: 0, height: scaled(6))) {
        NSGradient(colors: [
            NSColor(hex: recordingAccentHighlightHex),
            NSColor(hex: recordingAccentHex)
        ])?.draw(in: holdLine, angle: 0)
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
    try writePNG(image(size: size, draw: drawAppIcon), to: appIconURL.appendingPathComponent(filename))
}

if !appIconOnly {
    for kind in ["Idle", "Recording", "Transcribing"] {
        let imagesetURL = assetsURL.appendingPathComponent("MenuBarIcon\(kind)Template.imageset", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesetURL, withIntermediateDirectories: true)
        try writePNG(
            image(size: 36) { drawMenuBarIcon(kind: kind, in: $0) },
            to: imagesetURL.appendingPathComponent("MenuBarIcon\(kind)Template.png")
        )
    }
}
