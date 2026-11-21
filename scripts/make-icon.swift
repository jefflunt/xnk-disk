import Cocoa
import CoreGraphics

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets/icon-1024.png"
let size = 1024
let scale: CGFloat = 4.0 // 256 -> 1024

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fputs("Failed to create CGContext\n", stderr)
    exit(1)
}

// Flip Y axis so coordinates match SVG (top-left origin, 256x256 space)
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: scale, y: -scale)

func rgba(_ hex: UInt32, _ a: CGFloat = 1.0) -> CGColor {
    let r = CGFloat((hex >> 16) & 0xFF) / 255.0
    let g = CGFloat((hex >> 8) & 0xFF) / 255.0
    let b = CGFloat(hex & 0xFF) / 255.0
    return CGColor(colorSpace: colorSpace, components: [r, g, b, a])!
}

func roundedRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
    return CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
}

// 1. macOS Squircle Base
let squircle = roundedRect(12, 12, 232, 232, 52)
ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()

let bgGrad = CGGradient(
    colorsSpace: colorSpace,
    colors: [rgba(0x141417), rgba(0x000000)] as CFArray,
    locations: [0.0, 1.0]
)!
ctx.drawLinearGradient(bgGrad, start: CGPoint(x: 12, y: 12), end: CGPoint(x: 244, y: 244), options: [])

// Subtle top-left radial spotlight
let spotGrad = CGGradient(
    colorsSpace: colorSpace,
    colors: [rgba(0xFFFFFF, 0.09), rgba(0xFFFFFF, 0.0)] as CFArray,
    locations: [0.0, 1.0]
)!
ctx.drawRadialGradient(
    spotGrad,
    startCenter: CGPoint(x: 70, y: 55), startRadius: 0,
    endCenter: CGPoint(x: 70, y: 55), endRadius: 175,
    options: []
)
ctx.restoreGState()

// Hairline frost border
ctx.addPath(squircle)
ctx.setStrokeColor(rgba(0xD6EBFD, 0.25))
ctx.setLineWidth(2.5)
ctx.strokePath()

func drawBlock(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat,
               fill: CGColor, stroke: CGColor? = nil, strokeW: CGFloat = 1.2,
               glow: CGColor? = nil, glowBlur: CGFloat = 0) {
    let p = roundedRect(x, y, w, h, r)
    ctx.saveGState()
    if let g = glow {
        ctx.setShadow(offset: .zero, blur: glowBlur, color: g)
    }
    ctx.addPath(p)
    ctx.setFillColor(fill)
    ctx.fillPath()
    ctx.restoreGState()

    if let s = stroke {
        ctx.addPath(p)
        ctx.setStrokeColor(s)
        ctx.setLineWidth(strokeW)
        ctx.strokePath()
    }
}

// Col 0: Disk Root (Primary Blue Used + Available Obsidian)
drawBlock(40, 44, 38, 122, 6, fill: rgba(0x2F81F7, 1.0), glow: rgba(0x2F81F7, 0.50), glowBlur: 18)
drawBlock(40, 172, 38, 40, 6, fill: rgba(0x1C1C21, 1.0), stroke: rgba(0xFFFFFF, 0.12), strokeW: 1.5)

// Col 1: Depth 1 (Blue Primary + Orange Contrast Accent)
drawBlock(86, 44, 38, 80, 6, fill: rgba(0x2F81F7, 0.82))
drawBlock(86, 130, 38, 36, 6, fill: rgba(0xFF7722, 0.94), glow: rgba(0xFF7722, 0.38), glowBlur: 12)

// Col 2: Depth 2
drawBlock(132, 44, 38, 50, 6, fill: rgba(0x2F81F7, 0.62))
drawBlock(132, 100, 38, 24, 5, fill: rgba(0x27272A, 1.0), stroke: rgba(0xFFFFFF, 0.12), strokeW: 1.0)
drawBlock(132, 130, 38, 22, 5, fill: rgba(0xFF7722, 0.64))

// Col 3: Depth 3
drawBlock(178, 44, 38, 30, 5, fill: rgba(0x2F81F7, 0.44))
drawBlock(178, 80, 38, 14, 4, fill: rgba(0x27272A, 1.0), stroke: rgba(0xFFFFFF, 0.10), strokeW: 1.0)
drawBlock(178, 130, 38, 13, 4, fill: rgba(0xFF7722, 0.42))

// Emerald status LED
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 8, color: rgba(0x10B981, 0.65))
ctx.setFillColor(rgba(0x10B981, 1.0))
ctx.fillEllipse(in: CGRect(x: 201, y: 197, width: 10, height: 10))
ctx.restoreGState()

guard let cgImage = ctx.makeImage() else {
    fputs("Failed to make CGImage\n", stderr)
    exit(1)
}
let rep = NSBitmapImageRep(cgImage: cgImage)
guard let pngData = rep.representation(using: .png, properties: [:]) else {
    fputs("Failed to encode PNG\n", stderr)
    exit(1)
}
try pngData.write(to: URL(fileURLWithPath: outPath))
print("Rendered \(outPath)")
