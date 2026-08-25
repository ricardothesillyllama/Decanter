import AppKit

// Background for the disk-image window: an arrow from where the app sits to
// where it should be dropped. Generated so it stays in step with the icon.
let W = 620.0, H = 400.0
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: Int(W * 2), height: Int(H * 2), bitsPerComponent: 8,
                    bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.scaleBy(x: 2, y: 2)                       // @2x so it is crisp on Retina
ctx.setAllowsAntialiasing(true)

ctx.setFillColor(CGColor(red: 0.98, green: 0.97, blue: 0.95, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
let glow = CGGradient(colorsSpace: cs,
                      colors: [CGColor(red: 0.85, green: 0.62, blue: 0.25, alpha: 0.16),
                               CGColor(red: 0.85, green: 0.62, blue: 0.25, alpha: 0.0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: W / 2, y: 300), startRadius: 0,
                       endCenter: CGPoint(x: W / 2, y: 300), endRadius: 380,
                       options: [.drawsBeforeStartLocation])

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

func text(_ s: String, _ f: NSFont, _ c: NSColor, x: Double, y: Double, centred: Bool = false) {
    let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: c]
    let w = (s as NSString).size(withAttributes: attrs).width
    (s as NSString).draw(at: NSPoint(x: centred ? x - w / 2 : x, y: y), withAttributes: attrs)
}

text("Decanter", .systemFont(ofSize: 26, weight: .semibold),
     NSColor(white: 0.12, alpha: 1), x: W / 2, y: H - 74, centred: true)
text("Drag it into Applications to install",
     .systemFont(ofSize: 14, weight: .regular),
     NSColor(white: 0.42, alpha: 1), x: W / 2, y: H - 100, centred: true)

// Arrow between the two icon positions the DMG window places below.
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 258, y: 196))
arrow.line(to: NSPoint(x: 362, y: 196))
arrow.lineWidth = 3
NSColor(calibratedRed: 0.72, green: 0.48, blue: 0.16, alpha: 0.75).setStroke()
arrow.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 372, y: 196))
head.line(to: NSPoint(x: 356, y: 205))
head.line(to: NSPoint(x: 356, y: 187))
head.close()
NSColor(calibratedRed: 0.72, green: 0.48, blue: 0.16, alpha: 0.75).setFill()
head.fill()

text("Not signed by Apple — first launch needs System Settings ▸ Privacy & Security.",
     .systemFont(ofSize: 11, weight: .regular),
     NSColor(white: 0.55, alpha: 1), x: W / 2, y: 34, centred: true)

NSGraphicsContext.restoreGraphicsState()
let out = URL(fileURLWithPath: "Resources/dmg-background.png")
try! NSBitmapImageRep(cgImage: ctx.makeImage()!)
    .representation(using: .png, properties: [:])!.write(to: out)
print("wrote \(out.path)")
