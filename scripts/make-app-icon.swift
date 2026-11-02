// Draws the app icon: a sung phrase as a line of light across the dark of a hall.
// Usage: swift scripts/make-app-icon.swift <output.png>
import AppKit
import CoreGraphics

let size = 1024
let scale = CGFloat(size)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: space,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

context.setFillColor(color(0.035, 0.028, 0.055))
context.fill(CGRect(x: 0, y: 0, width: size, height: size))

let curtain = CGGradient(
    colorsSpace: space,
    colors: [color(0.46, 0.09, 0.17, 0.95), color(0.17, 0.055, 0.15, 0.6), color(0.035, 0.028, 0.055, 0)] as CFArray,
    locations: [0, 0.5, 1]
)!
context.drawRadialGradient(
    curtain,
    startCenter: CGPoint(x: scale / 2, y: scale * 1.04),
    startRadius: 0,
    endCenter: CGPoint(x: scale / 2, y: scale * 1.04),
    endRadius: scale * 1.02,
    options: []
)

// Balcony lights, as on the programme screen.
for tier in 0..<3 {
    let depth = CGFloat(tier) / 2
    let radius = scale * (0.72 + depth * 0.5)
    let center = CGPoint(x: scale / 2, y: scale * (1.72 + depth * 0.32))
    let lights = 21 + tier * 6
    for light in 0...lights {
        let along = CGFloat(light) / CGFloat(lights)
        let angle = -CGFloat.pi / 2 + (along - 0.5) * 1.5
        let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        let dot = 11 - depth * 5
        context.setFillColor(color(1, 0.9, 0.7, 0.8 - depth * 0.42))
        context.fillEllipse(in: CGRect(x: point.x - dot / 2, y: point.y - dot / 2, width: dot, height: dot))
    }
}

// A held note with vibrato that scoops up from below, the shape of the pitch trail in the app.
let path = CGMutablePath()
let steps = 600
for step in 0...steps {
    let t = CGFloat(step) / CGFloat(steps)
    let x = scale * (0.08 + 0.84 * t)
    let scoop = -0.20 * exp(-t * 7.5)
    let swell = min(1, max(0, (t - 0.28) * 2.6))
    let vibrato = 0.055 * swell * sin(t * 2 * .pi * 5.2)
    let y = scale * (0.44 + scoop + vibrato)
    if step == 0 {
        path.move(to: CGPoint(x: x, y: y))
    } else {
        path.addLine(to: CGPoint(x: x, y: y))
    }
}
context.setLineCap(.round)
context.setLineJoin(.round)
context.addPath(path)
context.setStrokeColor(color(0.95, 0.56, 0.15, 0.20))
context.setShadow(offset: .zero, blur: 90, color: color(0.96, 0.56, 0.15, 1))
context.setLineWidth(58)
context.strokePath()
context.addPath(path)
context.setShadow(offset: .zero, blur: 34, color: color(1, 0.8, 0.45, 1))
context.setStrokeColor(color(0.96, 0.74, 0.40, 0.9))
context.setLineWidth(27)
context.strokePath()
context.addPath(path)
context.setShadow(offset: .zero, blur: 0, color: nil)
context.setStrokeColor(color(1, 0.96, 0.84))
context.setLineWidth(10)
context.strokePath()

let image = context.makeImage()!
let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
