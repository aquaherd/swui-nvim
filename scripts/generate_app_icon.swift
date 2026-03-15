import AppKit

struct IconSpec {
    let filename: String
    let pixelSize: CGFloat
}

let outputDirectory: URL
if CommandLine.arguments.count > 1 {
    outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
} else {
    outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
}

let specs: [IconSpec] = [
    .init(filename: "icon_16x16.png", pixelSize: 16),
    .init(filename: "icon_16x16@2x.png", pixelSize: 32),
    .init(filename: "icon_32x32.png", pixelSize: 32),
    .init(filename: "icon_32x32@2x.png", pixelSize: 64),
    .init(filename: "icon_128x128.png", pixelSize: 128),
    .init(filename: "icon_128x128@2x.png", pixelSize: 256),
    .init(filename: "icon_256x256.png", pixelSize: 256),
    .init(filename: "icon_256x256@2x.png", pixelSize: 512),
    .init(filename: "icon_512x512.png", pixelSize: 512),
    .init(filename: "icon_512x512@2x.png", pixelSize: 1024),
]

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func point(_ x: CGFloat, _ y: CGFloat, in rect: CGRect) -> CGPoint {
    CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
}

func polygon(_ points: [CGPoint]) -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: points[0])
    for point in points.dropFirst() {
        path.line(to: point)
    }
    path.close()
    return path
}

func linearGradient(from start: NSColor, to end: NSColor, angle: CGFloat) -> NSGradient {
    NSGradient(starting: start, ending: end) ?? NSGradient(colors: [start, end])!
}

func drawIcon(in size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    guard let context = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)

    let canvas = CGRect(x: 0, y: 0, width: size, height: size)
    let inset = size * 0.06
    let iconRect = canvas.insetBy(dx: inset, dy: inset)
    let cornerRadius = iconRect.width * 0.23

    let outerShadow = NSShadow()
    outerShadow.shadowColor = NSColor.black.withAlphaComponent(0.26)
    outerShadow.shadowBlurRadius = size * 0.05
    outerShadow.shadowOffset = NSSize(width: 0, height: -size * 0.015)
    outerShadow.set()

    let basePath = NSBezierPath(roundedRect: iconRect, xRadius: cornerRadius, yRadius: cornerRadius)
    basePath.addClip()

    linearGradient(
        from: NSColor(calibratedRed: 0.09, green: 0.11, blue: 0.13, alpha: 1),
        to: NSColor(calibratedRed: 0.03, green: 0.04, blue: 0.05, alpha: 1),
        angle: -90
    ).draw(in: basePath, angle: -90)

    let glowRect = iconRect.insetBy(dx: size * 0.015, dy: size * 0.015)
    let glowPath = NSBezierPath(roundedRect: glowRect, xRadius: cornerRadius * 0.92, yRadius: cornerRadius * 0.92)
    NSColor(calibratedWhite: 1, alpha: 0.06).setStroke()
    glowPath.lineWidth = max(1, size * 0.008)
    glowPath.stroke()

    let safeRect = iconRect.insetBy(dx: iconRect.width * 0.14, dy: iconRect.height * 0.14)

    let leftFacet = polygon([
        point(0.08, 0.88, in: safeRect),
        point(0.34, 0.70, in: safeRect),
        point(0.34, 0.10, in: safeRect),
        point(0.08, 0.28, in: safeRect),
    ])
    linearGradient(
        from: NSColor(calibratedRed: 0.48, green: 0.84, blue: 0.47, alpha: 1),
        to: NSColor(calibratedRed: 0.17, green: 0.67, blue: 0.36, alpha: 1),
        angle: -90
    ).draw(in: leftFacet, angle: -90)

    let rightFacet = polygon([
        point(0.38, 0.10, in: safeRect),
        point(0.38, 0.70, in: safeRect),
        point(0.92, 0.88, in: safeRect),
        point(0.92, 0.28, in: safeRect),
    ])
    linearGradient(
        from: NSColor(calibratedRed: 0.40, green: 0.73, blue: 0.96, alpha: 1),
        to: NSColor(calibratedRed: 0.16, green: 0.43, blue: 0.83, alpha: 1),
        angle: -90
    ).draw(in: rightFacet, angle: -90)

    let centerRibbon = polygon([
        point(0.34, 0.70, in: safeRect),
        point(0.50, 0.58, in: safeRect),
        point(0.66, 0.70, in: safeRect),
        point(0.66, 0.18, in: safeRect),
        point(0.50, 0.30, in: safeRect),
        point(0.34, 0.18, in: safeRect),
    ])
    linearGradient(
        from: NSColor(calibratedWhite: 0.96, alpha: 1),
        to: NSColor(calibratedWhite: 0.74, alpha: 1),
        angle: -90
    ).draw(in: centerRibbon, angle: -90)

    let innerCut = polygon([
        point(0.42, 0.62, in: safeRect),
        point(0.50, 0.56, in: safeRect),
        point(0.58, 0.62, in: safeRect),
        point(0.58, 0.34, in: safeRect),
        point(0.50, 0.40, in: safeRect),
        point(0.42, 0.34, in: safeRect),
    ])
    NSColor(calibratedRed: 0.06, green: 0.08, blue: 0.10, alpha: 1).setFill()
    innerCut.fill()

    let vignetteGradient = NSGradient(colors: [
        NSColor(calibratedWhite: 1, alpha: 0.0),
        NSColor(calibratedWhite: 0, alpha: 0.18),
    ])!
    vignetteGradient.draw(in: basePath, relativeCenterPosition: NSPoint(x: 0, y: -0.2))

    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, to destination: URL) throws {
    guard
        let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let data = bitmap.representation(using: .png, properties: [:])
    else {
        throw NSError(domain: "GenerateAppIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to encode PNG at \(destination.path)"])
    }

    try data.write(to: destination)
}

for spec in specs {
    let image = drawIcon(in: spec.pixelSize)
    try writePNG(image, to: outputDirectory.appendingPathComponent(spec.filename))
}

print("Generated \(specs.count) icon files in \(outputDirectory.path)")