import AppKit
import CoreGraphics

// A decanter: broad rounded body, narrow neck, amber spirit inside, with the
// liquid line sitting low so the silhouette still reads at 16pt.
func draw(size: CGFloat) -> Data {
    let s = size
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: Int(s), height: Int(s), bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // macOS icons sit inset inside their canvas with a superellipse-ish corner.
    let inset = s * 0.055
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.2237                     // Big Sur-ish continuous corner
    let plate = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Deep slate ground so the amber reads as light in a glass.
    ctx.saveGState()
    ctx.addPath(plate); ctx.clip()
    let bg = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 0.16, green: 0.17, blue: 0.20, alpha: 1),
        CGColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1)] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])

    // Warm glow behind the vessel.
    let glow = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 0.85, green: 0.55, blue: 0.18, alpha: 0.30),
        CGColor(red: 0.85, green: 0.55, blue: 0.18, alpha: 0.0)] as CFArray,
        locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: s * 0.5, y: s * 0.34), startRadius: 0,
                           endCenter: CGPoint(x: s * 0.5, y: s * 0.34), endRadius: s * 0.42,
                           options: [])

    // --- decanter silhouette -------------------------------------------
    let cx = s * 0.5
    let bodyBottom = s * 0.175
    let bodyTop    = s * 0.545
    let neckTop    = s * 0.815
    let bodyHalf   = s * 0.255
    let neckHalf   = s * 0.072

    let vessel = CGMutablePath()
    vessel.move(to: CGPoint(x: cx - neckHalf, y: neckTop))
    vessel.addLine(to: CGPoint(x: cx - neckHalf, y: bodyTop + s * 0.035))
    // shoulder flaring out to the body
    vessel.addCurve(to: CGPoint(x: cx - bodyHalf, y: bodyBottom + s * 0.115),
                    control1: CGPoint(x: cx - neckHalf, y: bodyTop - s * 0.055),
                    control2: CGPoint(x: cx - bodyHalf, y: bodyTop - s * 0.045))
    // rounded base
    vessel.addCurve(to: CGPoint(x: cx + bodyHalf, y: bodyBottom + s * 0.115),
                    control1: CGPoint(x: cx - bodyHalf * 0.98, y: bodyBottom - s * 0.045),
                    control2: CGPoint(x: cx + bodyHalf * 0.98, y: bodyBottom - s * 0.045))
    vessel.addCurve(to: CGPoint(x: cx + neckHalf, y: bodyTop + s * 0.035),
                    control1: CGPoint(x: cx + bodyHalf, y: bodyTop - s * 0.045),
                    control2: CGPoint(x: cx + neckHalf, y: bodyTop - s * 0.055))
    vessel.addLine(to: CGPoint(x: cx + neckHalf, y: neckTop))
    vessel.closeSubpath()

    // glass
    ctx.saveGState()
    ctx.addPath(vessel); ctx.clip()
    let glass = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.20),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.05)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(glass, start: CGPoint(x: cx - bodyHalf, y: neckTop),
                           end: CGPoint(x: cx + bodyHalf, y: bodyBottom), options: [])

    // amber spirit, filling the lower body
    let level = s * 0.455
    ctx.saveGState()
    ctx.clip(to: CGRect(x: 0, y: 0, width: s, height: level))
    let spirit = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 0.93, green: 0.64, blue: 0.22, alpha: 1),
        CGColor(red: 0.72, green: 0.38, blue: 0.08, alpha: 1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(spirit, start: CGPoint(x: 0, y: level), end: CGPoint(x: 0, y: bodyBottom), options: [])
    ctx.restoreGState()

    // meniscus
    ctx.setStrokeColor(CGColor(red: 1, green: 0.85, blue: 0.55, alpha: 0.85))
    ctx.setLineWidth(max(1, s * 0.012))
    ctx.move(to: CGPoint(x: cx - bodyHalf, y: level)); ctx.addLine(to: CGPoint(x: cx + bodyHalf, y: level))
    ctx.strokePath()

    // specular highlight down the left of the glass
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.22))
    let hi = CGPath(roundedRect: CGRect(x: cx - bodyHalf * 0.62, y: bodyBottom + s * 0.075,
                                        width: s * 0.045, height: s * 0.30),
                    cornerWidth: s * 0.025, cornerHeight: s * 0.025, transform: nil)
    ctx.addPath(hi); ctx.fillPath()
    ctx.restoreGState()

    // rim of the glass
    ctx.addPath(vessel)
    ctx.setStrokeColor(CGColor(red: 1, green: 0.92, blue: 0.80, alpha: 0.55))
    ctx.setLineWidth(max(1, s * 0.016))
    ctx.strokePath()

    // stopper
    let stopper = CGPath(roundedRect: CGRect(x: cx - s * 0.105, y: neckTop,
                                             width: s * 0.21, height: s * 0.072),
                         cornerWidth: s * 0.03, cornerHeight: s * 0.03, transform: nil)
    ctx.addPath(stopper)
    ctx.setFillColor(CGColor(red: 0.95, green: 0.70, blue: 0.32, alpha: 1))
    ctx.fillPath()

    ctx.restoreGState()

    // hairline edge so it doesn't melt into a dark Dock
    ctx.addPath(plate)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.09))
    ctx.setLineWidth(max(1, s * 0.006))
    ctx.strokePath()

    let img = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: img)
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(filePath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32),
                   ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256),
                   ("icon_256x256", 256), ("icon_256x256@2x", 512),
                   ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    try! draw(size: CGFloat(px)).write(to: out.appending(path: "\(name).png"))
}
print("rendered 10 sizes")
