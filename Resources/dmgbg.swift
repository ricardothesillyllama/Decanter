import AppKit

// Background for the disk-image window, and it is nearly nothing on purpose.
//
// The window had a title, an instruction, an arrow drawn between the two icon
// positions, and a note. Every one of those except the note was either
// redundant or a liability. Finder scales a background picture to whatever
// size the window actually is, while the icon positions saved in .DS_Store are
// absolute points that do not scale — so anything drawn in relation to the
// icons separates from them the moment the window is not the size the art was
// laid out for, which is every time somebody opens the image as a tab in an
// existing Finder window. The arrow pointed at nothing and "Drag it into
// Applications" ended up underneath the Applications alias.
//
// The redundancy is the more interesting half. The window's own title bar
// already says Decanter. An app icon beside an Applications alias is the most
// recognised convention on the platform and has needed no caption since 2001.
// Repairing the layout of three things that say what the window already says
// was work spent on the wrong problem.
//
// What is left is the one fact a first-time user cannot get anywhere else: the
// app is not signed by Apple, so the first launch needs a trip to System
// Settings. It sits at the bottom, far outside the band the icons can occupy
// at any window size, where nothing can push it anywhere.
let W = 620.0, H = 340.0
let noteFromTop = 0.90
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: Int(W * 2), height: Int(H * 2), bitsPerComponent: 8,
                    bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.scaleBy(x: 2, y: 2)                       // @2x so it is crisp on Retina
ctx.setAllowsAntialiasing(true)

ctx.setFillColor(CGColor(red: 0.98, green: 0.97, blue: 0.95, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

let note = "Not signed by Apple — first launch needs System Settings ▸ Privacy & Security."
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 11, weight: .regular),
    .foregroundColor: NSColor(white: 0.55, alpha: 1),
]
let size = (note as NSString).size(withAttributes: attrs)
(note as NSString).draw(at: NSPoint(x: W / 2 - size.width / 2,
                                    y: H - (noteFromTop * H) - size.height),
                        withAttributes: attrs)

NSGraphicsContext.restoreGraphicsState()
let out = URL(fileURLWithPath: "Resources/dmg-background.png")
try! NSBitmapImageRep(cgImage: ctx.makeImage()!)
    .representation(using: .png, properties: [:])!.write(to: out)
print("wrote \(out.path)")
