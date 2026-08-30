import AppKit

// Background for the disk-image window.
//
// The rule that shapes this: **nothing may be drawn in the band the icons
// occupy.** Finder scales a background picture to whatever size the window
// actually is, and the icon positions saved in .DS_Store are absolute points
// that do not scale with it. The two only agree at the one window size the
// image was laid out for — and a disk image opened as a tab in an existing
// Finder window is never that size. The first version had an arrow drawn
// between the two icon positions and the words "Drag it into Applications"
// across the middle; in a wide tab the art stretched, the icons stayed put,
// and the Applications alias landed on top of the word "Drag".
//
// So the art is anchored where it cannot collide. Working in fractions of the
// height, measured from the top, because that is how a scaled image behaves:
// the icons sit between 157 and 275 points from the top, always, which across
// the window heights Finder actually produces (400 when the saved bounds are
// honoured, up to ~800 in a tab) covers the fraction range 0.20 to 0.69. Above
// and below that is safe at every size; the middle is safe at exactly one.
let W = 620.0, H = 400.0
let titleTop = 0.080          // fraction of height, from the top
let blurbTop = 0.155          // still clear of 0.20 at the tallest window
let noteTop  = 0.900          // clear of 0.69 at every window
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: Int(W * 2), height: Int(H * 2), bitsPerComponent: 8,
                    bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.scaleBy(x: 2, y: 2)                       // @2x so it is crisp on Retina
ctx.setAllowsAntialiasing(true)

ctx.setFillColor(CGColor(red: 0.98, green: 0.97, blue: 0.95, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
// Centred on the window rather than on the old arrow, so it reads as a ground
// rather than as a highlight pointing at something.
let glow = CGGradient(colorsSpace: cs,
                      colors: [CGColor(red: 0.85, green: 0.62, blue: 0.25, alpha: 0.14),
                               CGColor(red: 0.85, green: 0.62, blue: 0.25, alpha: 0.0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: W / 2, y: H / 2), startRadius: 0,
                       endCenter: CGPoint(x: W / 2, y: H / 2), endRadius: 420,
                       options: [.drawsBeforeStartLocation])

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

/// `fromTop` is a fraction of the height, because that is the coordinate the
/// collision rule above is written in. Converted here once.
func text(_ s: String, _ f: NSFont, _ c: NSColor, fromTop: Double) {
    let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: c]
    let size = (s as NSString).size(withAttributes: attrs)
    (s as NSString).draw(at: NSPoint(x: W / 2 - size.width / 2,
                                     y: H - (fromTop * H) - size.height),
                         withAttributes: attrs)
}

text("Decanter", .systemFont(ofSize: 26, weight: .semibold),
     NSColor(white: 0.12, alpha: 1), fromTop: titleTop)
text("Drag it into Applications to install",
     .systemFont(ofSize: 14, weight: .regular),
     NSColor(white: 0.42, alpha: 1), fromTop: blurbTop)
text("Not signed by Apple — first launch needs System Settings ▸ Privacy & Security.",
     .systemFont(ofSize: 11, weight: .regular),
     NSColor(white: 0.55, alpha: 1), fromTop: noteTop)

NSGraphicsContext.restoreGraphicsState()
let out = URL(fileURLWithPath: "Resources/dmg-background.png")
try! NSBitmapImageRep(cgImage: ctx.makeImage()!)
    .representation(using: .png, properties: [:])!.write(to: out)
print("wrote \(out.path)")
