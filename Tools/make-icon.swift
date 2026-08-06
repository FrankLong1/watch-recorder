// Regenerates the app icon for both targets. Source of truth for a binary asset
// that would otherwise have none.
//
//   swift Tools/make-icon.swift /tmp/AppIcon.png
//   cp /tmp/AppIcon.png WatchApp/Assets.xcassets/AppIcon.appiconset/AppIcon.png
//   cp /tmp/AppIcon.png iOSApp/Assets.xcassets/AppIcon.appiconset/AppIcon.png

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Renders the WristMemo app icon: a microphone on a violet gradient.
// One 1024pt master; watchOS crops it to a circle and iOS to a squircle, so
// every element stays well inside a centred safe area.

let S: CGFloat = 1024

guard let ctx = CGContext(
    data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    // noneSkipLast, not premultipliedLast: App Store review rejects an app icon
    // that carries an alpha channel, even a fully opaque one.
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else { fatalError("no context") }

// Work in top-down coordinates so the geometry below reads like a layout.
ctx.translateBy(x: 0, y: S)
ctx.scaleBy(x: 1, y: -1)

// --- background ---------------------------------------------------------------
let space = CGColorSpaceCreateDeviceRGB()
let gradient = CGGradient(
    colorsSpace: space,
    colors: [
        CGColor(colorSpace: space, components: [0.18, 0.06, 0.40, 1.0])!,
        CGColor(colorSpace: space, components: [0.49, 0.23, 0.93, 1.0])!,
    ] as CFArray,
    locations: [0.0, 1.0]
)!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: S, y: S), options: [])

ctx.setFillColor(CGColor(colorSpace: space, components: [1, 1, 1, 1])!)
ctx.setStrokeColor(CGColor(colorSpace: space, components: [1, 1, 1, 1])!)

// --- capsule ------------------------------------------------------------------
let capsule = CGRect(x: 412, y: 210, width: 200, height: 390)
ctx.addPath(CGPath(roundedRect: capsule, cornerWidth: 100, cornerHeight: 100, transform: nil))
ctx.fillPath()

// --- the U cradle -------------------------------------------------------------
// Drawn as a full circle stroke clipped to its lower half. Doing it this way
// avoids depending on arc winding direction, which inverts in a flipped context.
let cradleCenterY: CGFloat = 520
let cradleRadius: CGFloat = 175
ctx.saveGState()
ctx.clip(to: CGRect(x: 0, y: cradleCenterY, width: S, height: S - cradleCenterY))
ctx.setLineWidth(46)
ctx.strokeEllipse(in: CGRect(
    x: 512 - cradleRadius, y: cradleCenterY - cradleRadius,
    width: cradleRadius * 2, height: cradleRadius * 2
))
ctx.restoreGState()

// --- stem and base ------------------------------------------------------------
let stemTop = cradleCenterY + cradleRadius
ctx.fill(CGRect(x: 512 - 23, y: stemTop, width: 46, height: 95))
ctx.addPath(CGPath(
    roundedRect: CGRect(x: 512 - 110, y: stemTop + 95, width: 220, height: 46),
    cornerWidth: 23, cornerHeight: 23, transform: nil
))
ctx.fillPath()

// --- write --------------------------------------------------------------------
guard let image = ctx.makeImage() else { fatalError("no image") }
let out = URL(fileURLWithPath: CommandLine.arguments[1])
guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("no destination") }
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("write failed") }
print("wrote \(out.path)")
