import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// A code-native OLIV mark: a warm canvas, an open olive-fruit O, and a single leaf.
// Regenerate with: swift Scripts/GenerateIcon.swift App/Assets.xcassets/AppIcon.appiconset/AppIcon.png
// Core Graphics uses a supported four-byte, opaque RGB bitmap. The earlier AppKit
// three-channel bitmap did not receive drawing commands and exported a black icon.
let side = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
guard let canvas = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                             bytesPerRow: side * 4, space: colorSpace,
                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    fatalError("Could not create an opaque icon canvas")
}
func color(_ hex: UInt32) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [CGFloat((hex >> 16) & 255) / 255,
                                               CGFloat((hex >> 8) & 255) / 255,
                                               CGFloat(hex & 255) / 255, 1])!
}
canvas.setAllowsAntialiasing(true)
canvas.setShouldAntialias(true)
canvas.setFillColor(color(0xF4F4EC))
canvas.fill(CGRect(x: 0, y: 0, width: side, height: side))
canvas.translateBy(x: 0, y: CGFloat(side))
canvas.scaleBy(x: 1, y: -1)

// A slightly angled, generous O stays legible at home-screen and Settings sizes.
canvas.saveGState()
canvas.translateBy(x: 477, y: 557)
canvas.rotate(by: .pi / 15)
canvas.setStrokeColor(color(0x304328))
canvas.setLineWidth(96)
canvas.strokeEllipse(in: CGRect(x: -210, y: -236, width: 420, height: 472))
canvas.restoreGState()

let leaf = CGMutablePath()
leaf.move(to: CGPoint(x: 578, y: 314))
leaf.addCurve(to: CGPoint(x: 797, y: 170), control1: CGPoint(x: 592, y: 172), control2: CGPoint(x: 693, y: 130))
leaf.addCurve(to: CGPoint(x: 578, y: 314), control1: CGPoint(x: 780, y: 318), control2: CGPoint(x: 679, y: 367))
leaf.closeSubpath()
canvas.addPath(leaf)
canvas.setFillColor(color(0x6D8251))
canvas.fillPath()

// A broad, quiet vein separates the leaf from the O without fine decorative detail.
let vein = CGMutablePath()
vein.move(to: CGPoint(x: 594, y: 309))
vein.addCurve(to: CGPoint(x: 743, y: 208), control1: CGPoint(x: 631, y: 266), control2: CGPoint(x: 682, y: 229))
canvas.addPath(vein)
canvas.setStrokeColor(color(0xF4F4EC))
canvas.setLineWidth(10)
canvas.setLineCap(.round)
canvas.strokePath()

// Verify the opaque canvas contains the expected light background before exporting.
guard let pixels = canvas.data?.assumingMemoryBound(to: UInt8.self),
      pixels[0] == 244, pixels[1] == 244, pixels[2] == 236,
      let image = canvas.makeImage() else {
    fatalError("Icon drawing failed its background pixel check")
}
let outputPath = CommandLine.arguments.dropFirst().first ?? "App/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
let outputURL = URL(fileURLWithPath: outputPath)
guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("Could not open icon destination")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Could not export icon") }
print("Wrote opaque 1024 × 1024 OLIV icon to \(outputPath)")
