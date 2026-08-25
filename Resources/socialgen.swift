import AppKit

// GitHub's social preview (Open Graph) card: 1280x640, shown whenever the repo
// is linked anywhere. Generated rather than hand-made so it stays in step with
// the app icon and the tagline.
//
//   swift Resources/socialgen.swift && open Resources/social-preview.png
//
// Upload via Settings -> General -> Social preview. There is no API for it.

let W = 1280.0, H = 640.0
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8,
                    bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setAllowsAntialiasing(true)
ctx.interpolationQuality = .high

// Background: the amber of the icon's spirit, deepened so white text carries.
// Paint the base flat first — a gradient does not fill beyond its endpoints
// unless told to, which otherwise leaves a hard diagonal edge across the card.
ctx.setFillColor(CGColor(red: 0.09, green: 0.07, blue: 0.055, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

let grad = CGGradient(colorsSpace: cs,
                      colors: [CGColor(red: 0.16, green: 0.11, blue: 0.08, alpha: 1),
                               CGColor(red: 0.06, green: 0.05, blue: 0.04, alpha: 1)] as CFArray,
                      locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: H), end: CGPoint(x: W, y: 0),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

// A warm wash behind the icon, so the card is not a flat rectangle.
let glow = CGGradient(colorsSpace: cs,
                      colors: [CGColor(red: 0.78, green: 0.50, blue: 0.15, alpha: 0.22),
                               CGColor(red: 0.78, green: 0.50, blue: 0.15, alpha: 0.0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 210, y: 430), startRadius: 0,
                       endCenter: CGPoint(x: 210, y: 430), endRadius: 560,
                       options: [.drawsBeforeStartLocation])

let gfx = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = gfx

// The app icon, so the card and the Dock agree.
let iconURL = URL(fileURLWithPath: "Resources/AppIcon.icns")
if let icon = NSImage(contentsOf: iconURL) {
    icon.draw(in: NSRect(x: 96, y: H - 96 - 224, width: 224, height: 224))
}

func text(_ s: String, _ font: NSFont, _ color: NSColor, x: Double, y: Double) {
    (s as NSString).draw(at: NSPoint(x: x, y: y),
                         withAttributes: [.font: font, .foregroundColor: color])
}

let x = 360.0
text("Decanter", .systemFont(ofSize: 96, weight: .bold), .white, x: x, y: H - 96 - 108)
text("Run Windows games on your Apple Silicon Mac",
     .systemFont(ofSize: 38, weight: .medium),
     NSColor(calibratedRed: 0.95, green: 0.80, blue: 0.55, alpha: 1), x: x, y: H - 96 - 172)
text("A maintained alternative to Whisky. Isolated prefixes, pinned runtimes,",
     .systemFont(ofSize: 27, weight: .regular),
     NSColor(white: 1, alpha: 0.62), x: x, y: H - 96 - 232)
text("and a graphics backend chosen from evidence instead of guesswork.",
     .systemFont(ofSize: 27, weight: .regular),
     NSColor(white: 1, alpha: 0.62), x: x, y: H - 96 - 272)

// Footer chips: what it actually is, at a glance.
var chipX = x
for chip in ["Swift + SwiftUI", "CLI + native app", "No dependencies", "GPL-3.0"] {
    let font = NSFont.systemFont(ofSize: 22, weight: .medium)
    let w = (chip as NSString).size(withAttributes: [.font: font]).width + 34
    let r = NSRect(x: chipX, y: 96, width: w, height: 44)
    NSColor(white: 1, alpha: 0.10).setFill()
    NSBezierPath(roundedRect: r, xRadius: 22, yRadius: 22).fill()
    text(chip, font, NSColor(white: 1, alpha: 0.85), x: chipX + 17, y: 107)
    chipX += w + 14
}

NSGraphicsContext.restoreGraphicsState()

let out = URL(fileURLWithPath: "Resources/social-preview.png")
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("wrote \(out.path)  (\(Int(W))x\(Int(H)))")
