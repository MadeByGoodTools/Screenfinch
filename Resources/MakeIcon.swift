import AppKit

// Run with an output directory to regenerate the Finder icon and the menu-bar PDF.
guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: swift MakeIcon.swift <output directory>\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let files = FileManager.default
try files.createDirectory(at: output, withIntermediateDirectories: true)

// Both sizes use the same short triangular bill, rounded breast and notched tail.
// The feet meet the top edge of the monitor at y = 0 in the bird's coordinates.
func drawFinch(in context: CGContext, template: Bool) {
    context.saveGState()
    defer { context.restoreGState() }
    let outline = CGMutablePath()
    outline.move(to: CGPoint(x: 0.05, y: 3.8))
    outline.addQuadCurve(to: CGPoint(x: 3.55, y: 4.05), control: CGPoint(x: 1.8, y: 3.68))
    outline.addCurve(to: CGPoint(x: 7.12, y: 6.22), control1: CGPoint(x: 4.75, y: 4.83), control2: CGPoint(x: 5.98, y: 5.71))
    outline.addCurve(to: CGPoint(x: 9.84, y: 8.58), control1: CGPoint(x: 7.57, y: 7.88), control2: CGPoint(x: 8.63, y: 8.66))
    outline.addQuadCurve(to: CGPoint(x: 12.00, y: 7.05), control: CGPoint(x: 11.47, y: 8.65))
    outline.addLine(to: CGPoint(x: 14.00, y: 6.66))
    outline.addLine(to: CGPoint(x: 12.05, y: 5.55))
    outline.addCurve(to: CGPoint(x: 9.65, y: 2.18), control1: CGPoint(x: 11.84, y: 4.15), control2: CGPoint(x: 11.08, y: 2.78))
    outline.addQuadCurve(to: CGPoint(x: 5.05, y: 1.93), control: CGPoint(x: 7.48, y: 1.22))
    outline.addLine(to: CGPoint(x: 0.72, y: 0.92))
    outline.addLine(to: CGPoint(x: 1.79, y: 2.31))
    outline.closeSubpath()

    let wingBar = CGMutablePath()
    wingBar.move(to: CGPoint(x: 3.89, y: 2.95))
    wingBar.addQuadCurve(to: CGPoint(x: 8.23, y: 5.00), control: CGPoint(x: 6.25, y: 3.57))
    wingBar.addQuadCurve(to: CGPoint(x: 3.89, y: 2.95), control: CGPoint(x: 7.21, y: 3.03))
    wingBar.closeSubpath()
    let eye = CGRect(x: 10.18, y: 6.75, width: 0.99, height: 0.99)

    context.setLineCap(.round)
    context.setLineWidth(template ? 1.04 : 0.43)
    let ink = template ? NSColor.black : color(0.14, 0.17, 0.24)
    context.setStrokeColor(ink.cgColor)
    for (ankle, foot) in [(6.95, 6.23), (8.96, 8.40)] {
        context.move(to: CGPoint(x: ankle, y: 2.15))
        context.addLine(to: CGPoint(x: foot, y: 0.07))
        if !template { context.addLine(to: CGPoint(x: foot + 0.83, y: 0.03)) }
    }
    context.strokePath()

    context.addPath(outline)
    if template {
        context.setFillColor(NSColor.black.cgColor)
        context.addPath(wingBar)
        context.addEllipse(in: eye)
        context.drawPath(using: .eoFill)
    } else {
        context.setFillColor(color(1.0, 0.77, 0.22).cgColor)
        context.fillPath()
        let wing = CGMutablePath()
        wing.move(to: CGPoint(x: 1.28, y: 2.45))
        wing.addCurve(to: CGPoint(x: 8.26, y: 5.66), control1: CGPoint(x: 4.81, y: 4.30), control2: CGPoint(x: 5.63, y: 6.02))
        wing.addCurve(to: CGPoint(x: 1.28, y: 2.45), control1: CGPoint(x: 8.04, y: 3.68), control2: CGPoint(x: 6.15, y: 2.31))
        wing.closeSubpath()
        context.addPath(wing); context.setFillColor(ink.cgColor); context.fillPath()
        context.addPath(wingBar); context.setFillColor(color(1, 0.94, 0.75).cgColor); context.fillPath()
        context.move(to: CGPoint(x: 11.95, y: 7.06))
        context.addLine(to: CGPoint(x: 14.00, y: 6.66))
        context.addLine(to: CGPoint(x: 12.05, y: 5.55))
        context.closePath(); context.setFillColor(color(0.87, 0.44, 0.12).cgColor); context.fillPath()
        context.setFillColor(ink.cgColor); context.fillEllipse(in: eye)
    }
}

var statusBounds = CGRect(x: 0, y: 0, width: 21, height: 19)
let menuURL = output.appendingPathComponent("ScreenfinchStatusTemplate.pdf")
let pdf = CGContext(menuURL as CFURL, mediaBox: &statusBounds, nil)!
pdf.beginPDFPage(nil)
pdf.setFillColor(NSColor.black.cgColor)
pdf.addPath(CGPath(roundedRect: CGRect(x: 0.8, y: 3.35, width: 17.7, height: 8.55), cornerWidth: 1.65, cornerHeight: 1.65, transform: nil))
pdf.addPath(CGPath(roundedRect: CGRect(x: 2.1, y: 4.85, width: 15.1, height: 5.75), cornerWidth: 0.48, cornerHeight: 0.48, transform: nil))
pdf.drawPath(using: .eoFill)
pdf.fill(CGRect(x: 8.85, y: 1.5, width: 1.7, height: 2.2))
pdf.addPath(CGPath(roundedRect: CGRect(x: 6.05, y: 0.55, width: 7.3, height: 1.4), cornerWidth: 0.7, cornerHeight: 0.7, transform: nil))
pdf.fillPath()
pdf.translateBy(x: 8.00, y: 11.48)
pdf.scaleBy(x: 0.82, y: 0.82)
drawFinch(in: pdf, template: true)
pdf.endPDFPage(); pdf.closePDF()

let raster = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: raster)!
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}
func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), xRadius: radius, yRadius: radius)
}
let base = rounded(92, 92, 840, 840, 190)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = color(0.01, 0.05, 0.16, 0.34)
shadow.shadowBlurRadius = 28; shadow.shadowOffset = NSSize(width: 0, height: -16); shadow.set()
color(0.09, 0.21, 0.39).setFill(); base.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(colors: [color(0.12, 0.47, 0.77), color(0.10, 0.25, 0.54), color(0.08, 0.12, 0.32)])!.draw(in: base, angle: -70)
NSGraphicsContext.saveGraphicsState()
let face = rounded(213, 325, 599, 382, 43)
let glow = NSShadow(); glow.shadowColor = color(0.01, 0.05, 0.19, 0.5); glow.shadowBlurRadius = 21; glow.shadowOffset = NSSize(width: 0, height: -9); glow.set()
color(0.88, 0.94, 1).setFill(); face.fill()
NSGraphicsContext.restoreGraphicsState()
let glass = rounded(239, 355, 547, 325, 23)
NSGradient(colors: [color(0.2, 0.82, 0.92), color(0.17, 0.53, 0.86), color(0.27, 0.31, 0.71)])!.draw(in: glass, angle: -55)
NSGraphicsContext.saveGraphicsState()
glass.addClip()
let waves = NSBezierPath()
waves.move(to: NSPoint(x: 200, y: 355)); waves.line(to: NSPoint(x: 200, y: 540))
waves.curve(to: NSPoint(x: 845, y: 555), controlPoint1: NSPoint(x: 425, y: 339), controlPoint2: NSPoint(x: 560, y: 695))
waves.line(to: NSPoint(x: 845, y: 340)); waves.close()
NSGradient(starting: color(0.21, 0.29, 0.78), ending: color(0.56, 0.39, 0.88))!.draw(in: waves, angle: -38)
NSGraphicsContext.restoreGraphicsState()
color(0.78, 0.86, 0.96).setFill(); rounded(483, 280, 59, 60, 9).fill()
color(0.91, 0.95, 1).setFill(); rounded(402, 265, 220, 25, 12).fill()
let appContext = NSGraphicsContext.current!.cgContext
appContext.saveGState()
appContext.translateBy(x: 528, y: 706)
appContext.scaleBy(x: 18, y: 18)
drawFinch(in: appContext, template: false)
appContext.restoreGState()

let temporary = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
let iconset = temporary.appendingPathComponent("Screenfinch.iconset", isDirectory: true)
try files.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? files.removeItem(at: temporary) }
let master = raster.cgImage!
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let scaled = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        scaled.interpolationQuality = .high
        scaled.draw(master, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        let image = NSBitmapImageRep(cgImage: scaled.makeImage()!)
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try image.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let pack = Process()
pack.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
pack.arguments = ["-c", "icns", iconset.path, "-o", output.appendingPathComponent("Screenfinch.icns").path]
try pack.run()
pack.waitUntilExit()
if pack.terminationStatus != 0 {
    throw NSError(domain: "Screenfinch.IconGenerator", code: Int(pack.terminationStatus),
                  userInfo: [NSLocalizedDescriptionKey: "iconutil could not package the app icon."])
}
