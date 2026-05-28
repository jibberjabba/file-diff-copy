#!/usr/bin/env swift
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func makeIcon(pixels: Int) -> Data? {
    let sz  = CGFloat(pixels)
    let cs  = CGColorSpaceCreateDeviceRGB()

    guard let ctx = CGContext(
        data: nil, width: pixels, height: pixels,
        bitsPerComponent: 8, bytesPerRow: pixels * 4, space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // Clip to rounded-rect (macOS icon shape, ~22.5% radius)
    let rad = sz * 0.225
    ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: sz, height: sz),
                       cornerWidth: rad, cornerHeight: rad, transform: nil))
    ctx.clip()

    // Blue gradient background (top-light → bottom-dark)
    let topC = CGColor(red: 0.25, green: 0.60, blue: 1.00, alpha: 1)
    let botC = CGColor(red: 0.05, green: 0.33, blue: 0.82, alpha: 1)
    guard let grad = CGGradient(colorsSpace: cs, colors: [topC, botC] as CFArray,
                                locations: [0, 1]) else { return nil }
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: sz / 2, y: sz),
                           end:   CGPoint(x: sz / 2, y: 0),
                           options: [])

    // Bold white right-pointing arrow, centred
    let cx = sz * 0.500
    let cy = sz * 0.500
    let totalW = sz * 0.560   // full arrow width (shaft + head)
    let shaftH = sz * 0.190   // shaft thickness
    let headH  = sz * 0.440   // arrowhead full height (top edge → bottom edge)
    let headW  = sz * 0.220   // arrowhead horizontal depth
    let x0 = cx - totalW / 2  // shaft left
    let x1 = cx + totalW / 2  // tip right
    let x2 = x1 - headW       // neck (shaft/head join)

    ctx.beginPath()
    ctx.move(to:    CGPoint(x: x0, y: cy + shaftH / 2))
    ctx.addLine(to: CGPoint(x: x2, y: cy + shaftH / 2))
    ctx.addLine(to: CGPoint(x: x2, y: cy + headH  / 2))
    ctx.addLine(to: CGPoint(x: x1, y: cy))
    ctx.addLine(to: CGPoint(x: x2, y: cy - headH  / 2))
    ctx.addLine(to: CGPoint(x: x2, y: cy - shaftH / 2))
    ctx.addLine(to: CGPoint(x: x0, y: cy - shaftH / 2))
    ctx.closePath()
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
    ctx.fillPath()

    guard let img = ctx.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
}

// Pixel sizes needed: 16, 32 (shared for 16@2x & 32@1x), 64, 128, 256, 512, 1024
let sizes = [16, 32, 64, 128, 256, 512, 1024]
for px in sizes {
    guard let data = makeIcon(pixels: px) else { print("Failed \(px)"); continue }
    let path = (outDir as NSString).appendingPathComponent("AppIcon_\(px).png")
    do {
        try data.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    } catch {
        print("error: \(error)")
    }
}
