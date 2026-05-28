#!/usr/bin/env swift
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func makeIcon(pixels: Int) -> Data? {
    let sz = CGFloat(pixels)
    let cs = CGColorSpaceCreateDeviceRGB()

    guard let ctx = CGContext(
        data: nil, width: pixels, height: pixels,
        bitsPerComponent: 8, bytesPerRow: pixels * 4, space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // Clip to macOS rounded-rect icon shape (~22.5% corner radius)
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

    // Draw a document page centred at (cx, cy).
    // CG coordinate system: y increases upward, so cy+h/2 is the visual top.
    // pageR/pageG/pageB: base page body colour; flapR/flapG/flapB: fold flap tint
    func drawPage(cx: CGFloat, cy: CGFloat, w: CGFloat, h: CGFloat,
                  alpha: CGFloat = 0.95,
                  pageR: CGFloat = 1.0, pageG: CGFloat = 1.0, pageB: CGFloat = 1.0,
                  flapR: CGFloat = 0.50, flapG: CGFloat = 0.74, flapB: CGFloat = 0.97) {
        let left   = cx - w / 2
        let right  = cx + w / 2
        let bottom = cy - h / 2
        let top    = cy + h / 2
        let fold   = w * 0.24        // folded-corner size

        // Page body
        let body = CGMutablePath()
        body.move(to:    CGPoint(x: left,         y: top))
        body.addLine(to: CGPoint(x: right - fold, y: top))
        body.addLine(to: CGPoint(x: right,        y: top - fold))
        body.addLine(to: CGPoint(x: right,        y: bottom))
        body.addLine(to: CGPoint(x: left,         y: bottom))
        body.closeSubpath()
        ctx.addPath(body)
        ctx.setFillColor(CGColor(red: pageR, green: pageG, blue: pageB, alpha: alpha))
        ctx.fillPath()

        // Fold flap (turned-up corner)
        let flap = CGMutablePath()
        flap.move(to:    CGPoint(x: right - fold, y: top))
        flap.addLine(to: CGPoint(x: right - fold, y: top - fold))
        flap.addLine(to: CGPoint(x: right,        y: top - fold))
        flap.closeSubpath()
        ctx.addPath(flap)
        ctx.setFillColor(CGColor(red: flapR, green: flapG, blue: flapB, alpha: alpha * 0.88))
        ctx.fillPath()

        // Ruled lines (text suggestion) — rendered only at 64 px and above.
        if sz >= 64 {
            let lineH   = max(1.0, h * 0.048)
            let lx      = left  + w * 0.14
            let lw      = w     * 0.62
            let ly0     = top   - fold - h * 0.10
            for i in 0 ..< 3 {
                let ly  = ly0 - CGFloat(i) * h * 0.150
                let lwa = i == 2 ? lw * 0.58 : lw
                ctx.setFillColor(CGColor(red: 0.22, green: 0.48, blue: 0.88, alpha: 0.18))
                ctx.fill(CGRect(x: lx, y: ly - lineH, width: lwa, height: lineH))
            }
        }
    }

    let pageW = sz * 0.220
    let pageH = sz * 0.282
    let off   = sz * 0.038

    // ── Left: source stack — warm cream/ivory pages ───────────────────────
    // Back page peeks out above-right of the front page
    drawPage(cx: sz * 0.220 + off, cy: sz * 0.500 + off * 0.55,
             w: pageW, h: pageH, alpha: 0.50,
             pageR: 0.98, pageG: 0.94, pageB: 0.84,   // warm cream
             flapR: 0.85, flapG: 0.74, flapB: 0.55)   // muted amber fold
    // Front page
    drawPage(cx: sz * 0.220,       cy: sz * 0.500,
             w: pageW, h: pageH, alpha: 0.95,
             pageR: 0.98, pageG: 0.94, pageB: 0.84,
             flapR: 0.85, flapG: 0.74, flapB: 0.55)

    // ── Right: destination page — light mint/green ────────────────────────
    drawPage(cx: sz * 0.780, cy: sz * 0.500,
             w: pageW, h: pageH, alpha: 0.95,
             pageR: 0.88, pageG: 0.97, pageB: 0.90,   // mint green
             flapR: 0.55, flapG: 0.82, flapB: 0.65)   // deeper green fold

    // ── Centre: transfer arrow — warm amber/gold ──────────────────────────
    let cx     = sz * 0.522
    let cy     = sz * 0.500
    let totalW = sz * 0.250
    let shaftH = sz * 0.096
    let headH  = sz * 0.232
    let headW  = sz * 0.104
    let x0     = cx - totalW / 2
    let x1     = cx + totalW / 2
    let x2     = x1 - headW

    ctx.beginPath()
    ctx.move(to:    CGPoint(x: x0, y: cy + shaftH / 2))
    ctx.addLine(to: CGPoint(x: x2, y: cy + shaftH / 2))
    ctx.addLine(to: CGPoint(x: x2, y: cy + headH  / 2))
    ctx.addLine(to: CGPoint(x: x1, y: cy))
    ctx.addLine(to: CGPoint(x: x2, y: cy - headH  / 2))
    ctx.addLine(to: CGPoint(x: x2, y: cy - shaftH / 2))
    ctx.addLine(to: CGPoint(x: x0, y: cy - shaftH / 2))
    ctx.closePath()
    // Amber/gold gradient for the arrow
    let arrowTop = CGColor(red: 1.00, green: 0.88, blue: 0.30, alpha: 0.97)
    let arrowBot = CGColor(red: 0.95, green: 0.65, blue: 0.05, alpha: 0.97)
    ctx.saveGState()
    ctx.clip()
    guard let arrowGrad = CGGradient(colorsSpace: cs,
                                     colors: [arrowTop, arrowBot] as CFArray,
                                     locations: [0, 1]) else { return nil }
    ctx.drawLinearGradient(arrowGrad,
                           start: CGPoint(x: cx, y: cy + headH / 2),
                           end:   CGPoint(x: cx, y: cy - headH / 2),
                           options: [])
    ctx.restoreGState()

    // ── Text labels ───────────────────────────────────────────────────────
    if sz >= 64 {
        let fontSize = sz * 0.164
        let fontRef  = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize, nil)
        let white    = CGColor(red: 1, green: 1, blue: 1, alpha: 0.95)

        func drawLabel(_ text: String, baselineY: CGFloat) {
            let attrs: [NSAttributedString.Key: Any] = [.font: fontRef, .foregroundColor: white]
            let line   = CTLineCreateWithAttributedString(
                            NSAttributedString(string: text, attributes: attrs))
            let bounds = CTLineGetBoundsWithOptions(line, [])
            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.textPosition = CGPoint(x: sz / 2 - bounds.width / 2, y: baselineY)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }

        drawLabel("File Diff", baselineY: sz * 0.760)
        drawLabel("Copy",      baselineY: sz * 0.088)
    }

    guard let img = ctx.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
}

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
