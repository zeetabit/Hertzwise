import AppKit
import SwiftUI
import ImageIO

// Renders the Hertzwise app icon and the README / site artwork.
//
// The mark is a level dial: a knob carrying one sine cycle (the sample rate
// the app follows), ringed by level ticks lit up to its pointer (the volume
// it applies), on the sumi squircle Hertzwise keeps from SyncHz.
//
// Writes:
//   AppIcon.icon/Assets/ticks.png, knob.png, wave.png   Icon Composer layers
//   branding/icon_1024.png                       masked squircle + shadow (README)
//   branding/banner-light.png, banner-dark.png   README header (icon + wordmark)
//   docs/icon.png, favicon.png, apple-touch-icon.png
//   docs/social.png                              1280×640 link preview (Open Graph,
//                                                GitHub social preview); needs
//                                                docs/screenshots/panel-dark.png
// Run from the repo root: swift branding/render_icon.swift

let canvas: CGFloat = 1024
// Apple's macOS icon grid: an 824 pt body on a 1024 pt canvas.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tileRadius: CGFloat = 185.4

func srgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let sumiTop = srgb(0x2C2B2E)
let sumiBottom = srgb(0x151416)
let paper = srgb(0xF2EEE4)
let rikyu = srgb(0xB6C07A)          // the app's dark-mode 利休 accent
let ink = srgb(0x18181A)
let inkSoft = srgb(0x18181A, 0.58)
let paperSoft = srgb(0xF2EEE4, 0.62)

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func makeContext(_ width: CGFloat, _ height: CGFloat) -> CGContext {
    CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func save(_ image: CGImage, to path: String) {
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                               "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(path)")
}

func squircle(_ rect: CGRect, radius: CGFloat) -> CGPath {
    RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
}

// MARK: - Mark parts (drawn in a 1024 canvas, CoreGraphics y-up)

let dialCenter = CGPoint(x: 512, y: 512)
/// The knob's sweep, clockwise from lower left to lower right, and the level shown.
let sweepStart = CGFloat.pi * 1.25, sweepEnd = -CGFloat.pi * 0.25, level: CGFloat = 0.6

func sweepAngle(_ fraction: CGFloat) -> CGFloat {
    sweepStart + (sweepEnd - sweepStart) * fraction
}

/// Level ticks round the knob: lit in 利休 up to the level, faint after it.
func drawTicks(_ ctx: CGContext) {
    let count = 13, inner: CGFloat = 318, outer: CGFloat = 368
    ctx.setLineWidth(22)
    ctx.setLineCap(.round)
    for index in 0..<count {
        let fraction = CGFloat(index) / CGFloat(count - 1)
        let angle = sweepAngle(fraction)
        ctx.setStrokeColor(fraction <= level + 0.001 ? rikyu : srgb(0xF2EEE4, 0.2))
        ctx.move(to: CGPoint(x: dialCenter.x + cos(angle) * inner, y: dialCenter.y + sin(angle) * inner))
        ctx.addLine(to: CGPoint(x: dialCenter.x + cos(angle) * outer, y: dialCenter.y + sin(angle) * outer))
        ctx.strokePath()
    }
}

/// The knob face, a shade above the tile, with a hairline rim.
func drawKnob(_ ctx: CGContext) {
    let face = CGRect(x: dialCenter.x - 262, y: dialCenter.y - 262, width: 524, height: 524)
    ctx.setFillColor(srgb(0x2A292C))
    ctx.fillEllipse(in: face)
    ctx.setStrokeColor(srgb(0xFFFFFF, 0.09))
    ctx.setLineWidth(6)
    ctx.strokeEllipse(in: face.insetBy(dx: 3, dy: 3))
}

/// One sine cycle across the knob, and the pointer dot at the level.
func drawWave(_ ctx: CGContext) {
    let path = CGMutablePath()
    let x0: CGFloat = 336, x1: CGFloat = 688, amp: CGFloat = 104
    for index in 0...240 {
        let t = CGFloat(index) / 240
        let point = CGPoint(x: x0 + (x1 - x0) * t, y: dialCenter.y + amp * sin(t * 2 * .pi))
        index == 0 ? path.move(to: point) : path.addLine(to: point)
    }
    ctx.addPath(path)
    ctx.setStrokeColor(paper)
    ctx.setLineWidth(52)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    let angle = sweepAngle(level), radius: CGFloat = 206, dot: CGFloat = 52
    ctx.setFillColor(rikyu)
    ctx.fillEllipse(in: CGRect(x: dialCenter.x + cos(angle) * radius - dot / 2,
                               y: dialCenter.y + sin(angle) * radius - dot / 2, width: dot, height: dot))
}

func drawMark(_ ctx: CGContext) {
    drawTicks(ctx)
    drawKnob(ctx)
    drawWave(ctx)
}

@discardableResult
func drawText(_ ctx: CGContext, _ string: String, size: CGFloat, weight: NSFont.Weight,
              color: CGColor, x: CGFloat, baseline: CGFloat, anchor: CGFloat = 0.5,
              tracking: CGFloat = 0, font: NSFont? = nil) -> CGRect {
    let font = font ?? NSFont.systemFont(ofSize: size, weight: weight)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: NSColor(cgColor: color)!, .kern: tracking,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    let origin = CGPoint(x: x - bounds.width * anchor - bounds.minX, y: baseline)
    ctx.textPosition = origin
    CTLineDraw(line, ctx)
    return CGRect(x: origin.x + bounds.minX, y: origin.y + bounds.minY,
                  width: bounds.width, height: bounds.height)
}

func drawTileBody(_ ctx: CGContext) {
    let path = squircle(tile, radius: tileRadius)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [sumiTop, sumiBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
    ctx.restoreGState()
    drawMark(ctx)
    // Hairline rim so the tile holds its edge on dark backgrounds.
    ctx.addPath(path)
    ctx.setLineWidth(3)
    ctx.setStrokeColor(srgb(0xFFFFFF, 0.07))
    ctx.strokePath()
}

/// The finished icon as macOS draws it: squircle body with a soft drop shadow.
func renderIcon() -> CGImage {
    let ctx = makeContext(canvas, canvas)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: srgb(0x000000, 0.32))
    ctx.addPath(squircle(tile, radius: tileRadius))
    ctx.setFillColor(sumiBottom)
    ctx.fillPath()
    ctx.restoreGState()
    drawTileBody(ctx)
    return ctx.makeImage()!
}

/// Full-bleed square (no mask, no shadow) for apple-touch-icon.
func renderFullBleed() -> CGImage {
    let ctx = makeContext(canvas, canvas)
    let gradient = CGGradient(colorsSpace: space, colors: [sumiTop, sumiBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: canvas), end: .zero, options: [])
    ctx.translateBy(x: 512, y: 512)
    ctx.scaleBy(x: 1.18, y: 1.18)
    ctx.translateBy(x: -512, y: -512)
    drawMark(ctx)
    return ctx.makeImage()!
}

func scaled(_ image: CGImage, to side: CGFloat) -> CGImage {
    let ctx = makeContext(side, side)
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    return ctx.makeImage()!
}

// MARK: - README banner: icon, wordmark, tagline

func renderBanner(dark: Bool, icon: CGImage) -> CGImage {
    let width: CGFloat = 1840, height: CGFloat = 720
    let ctx = makeContext(width, height)
    ctx.draw(icon, in: CGRect(x: 40, y: 0, width: 720, height: 720))
    let textX: CGFloat = 790
    drawText(ctx, "Hertzwise", size: 220, weight: .bold, color: dark ? paper : ink,
             x: textX, baseline: 352, anchor: 0, tracking: -6)
    drawText(ctx, "for Tidal and Apple Music on Mac", size: 72, weight: .medium, color: dark ? paperSoft : inkSoft,
             x: textX + 6, baseline: 214, anchor: 0, tracking: -1)
    return ctx.makeImage()!
}

// MARK: - Link preview: icon, wordmark and the panel

func renderSocial(icon: CGImage, screenshot: CGImage) -> CGImage {
    let width: CGFloat = 1280, height: CGFloat = 640
    let ctx = makeContext(width, height)
    let background = CGGradient(colorsSpace: space, colors: [srgb(0x232225), srgb(0x111012)] as CFArray,
                                locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: height), end: .zero, options: [])

    // The panel, at the right, in a rounded window frame.
    let shotHeight: CGFloat = 548
    let shotWidth = shotHeight * CGFloat(screenshot.width) / CGFloat(screenshot.height)
    let shot = CGRect(x: width - shotWidth - 72, y: (height - shotHeight) / 2, width: shotWidth, height: shotHeight)
    let frame = squircle(shot, radius: 22)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: srgb(0x000000, 0.55))
    ctx.addPath(frame)
    ctx.setFillColor(srgb(0x18181A))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(frame)
    ctx.clip()
    ctx.interpolationQuality = .high
    ctx.draw(screenshot, in: shot)
    ctx.restoreGState()
    ctx.addPath(frame)
    ctx.setLineWidth(1.5)
    ctx.setStrokeColor(srgb(0xFFFFFF, 0.12))
    ctx.strokePath()

    let left: CGFloat = 76
    ctx.draw(icon, in: CGRect(x: left - 26, y: 372, width: 212, height: 212))
    drawText(ctx, "Hertzwise", size: 104, weight: .bold, color: paper,
             x: left, baseline: 262, anchor: 0, tracking: -3)
    drawText(ctx, "for Tidal and Apple Music on Mac", size: 34, weight: .medium, color: paperSoft,
             x: left + 2, baseline: 196, anchor: 0)
    drawText(ctx, "Automatic sample-rate switching,", size: 28, weight: .regular,
             color: srgb(0xF2EEE4, 0.48), x: left + 2, baseline: 118, anchor: 0)
    drawText(ctx, "DAC volume and per-device headphone EQ", size: 28, weight: .regular,
             color: srgb(0xF2EEE4, 0.48), x: left + 2, baseline: 80, anchor: 0)
    return ctx.makeImage()!
}

// MARK: - Icon Composer layers

func renderLayer(_ draw: (CGContext) -> Void) -> CGImage {
    let ctx = makeContext(canvas, canvas)
    draw(ctx)
    return ctx.makeImage()!
}

let icon = renderIcon()
save(icon, to: "branding/icon_1024.png")
save(renderBanner(dark: false, icon: icon), to: "branding/banner-light.png")
save(renderBanner(dark: true, icon: icon), to: "branding/banner-dark.png")

// The system masks and lights the layers itself; fill = the sumi gradient in icon.json.
save(renderLayer(drawTicks), to: "AppIcon.icon/Assets/ticks.png")
save(renderLayer(drawKnob), to: "AppIcon.icon/Assets/knob.png")
save(renderLayer(drawWave), to: "AppIcon.icon/Assets/wave.png")

save(scaled(icon, to: 512), to: "docs/icon.png")
save(scaled(icon, to: 64), to: "docs/favicon.png")
save(scaled(renderFullBleed(), to: 180), to: "docs/apple-touch-icon.png")

if let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: "docs/screenshots/panel-dark.png") as CFURL, nil),
   let screenshot = CGImageSourceCreateImageAtIndex(source, 0, nil) {
    save(renderSocial(icon: icon, screenshot: screenshot), to: "docs/social.png")
}
