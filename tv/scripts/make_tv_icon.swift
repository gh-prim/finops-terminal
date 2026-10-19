#!/usr/bin/env swift
// Draws the finops Apple TV icon (layered, for the focus parallax) and Top Shelf images,
// in the style of app/scripts/make_icon.swift.
//   swift tv/scripts/make_tv_icon.swift tv/Sources/Assets.xcassets

import AppKit
import CoreGraphics
import Foundation

let amber = CGColor(red: 1.0, green: 0.66, blue: 0.10, alpha: 1)
let amberSoft = CGColor(red: 1.0, green: 0.66, blue: 0.10, alpha: 0.35)
let red = CGColor(red: 0.95, green: 0.33, blue: 0.30, alpha: 1)
let gridColor = CGColor(red: 1, green: 1, blue: 1, alpha: 0.055)

enum Layer { case back, middle, front }

func context(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

/// Background: gradient and chart grid across the whole canvas (opaque).
func drawBack(_ ctx: CGContext, _ w: CGFloat, _ h: CGFloat) {
    let bg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
        CGColor(red: 0.115, green: 0.115, blue: 0.13, alpha: 1),
        CGColor(red: 0.035, green: 0.035, blue: 0.045, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: w / 2, y: h), end: CGPoint(x: w / 2, y: 0), options: [])
    ctx.setStrokeColor(gridColor)
    ctx.setLineWidth(max(h / 340, 1))
    for i in 1...5 {
        let y = h * CGFloat(i) / 6
        ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: w, y: y))
    }
    let cols = Int((w / h * 6).rounded())
    for i in 1..<cols {
        let x = w * CGFloat(i) / CGFloat(cols)
        ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: h))
    }
    ctx.strokePath()
}

struct Candle { let x, low, open, close, high: CGFloat }
let candles = [
    Candle(x: 230, low: 390, open: 420, close: 500, high: 530),
    Candle(x: 345, low: 455, open: 500, close: 575, high: 610),
    Candle(x: 460, low: 520, open: 600, close: 545, high: 625),
    Candle(x: 575, low: 540, open: 560, close: 660, high: 690),
    Candle(x: 690, low: 640, open: 665, close: 745, high: 785),
    Candle(x: 805, low: 720, open: 750, close: 840, high: 880),
]

/// The 1024-unit artwork, drawn into `rect` (a square), one layer at a time.
func drawArt(_ ctx: CGContext, in rect: CGRect, layer: Layer) {
    let s = rect.width / 1024
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
    switch layer {
    case .back:
        break
    case .middle:
        // Glowing trend line behind the candles.
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 28 * s, color: amberSoft)
        ctx.setStrokeColor(CGColor(red: 1.0, green: 0.80, blue: 0.40, alpha: 0.9))
        ctx.setLineWidth(9 * s)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.addLines(between: candles.map { p($0.x, $0.close + 40) })
        ctx.strokePath()
        ctx.restoreGState()
    case .front:
        for c in candles {
            let color = c.close >= c.open ? amber : red
            ctx.setStrokeColor(color)
            ctx.setLineWidth(10 * s)
            ctx.setLineCap(.round)
            ctx.move(to: p(c.x, c.low)); ctx.addLine(to: p(c.x, c.high))
            ctx.strokePath()
            let body = CGRect(x: rect.minX + (c.x - 31) * s, y: rect.minY + min(c.open, c.close) * s,
                              width: 62 * s, height: abs(c.close - c.open) * s)
            ctx.setFillColor(color)
            ctx.addPath(CGPath(roundedRect: body, cornerWidth: 8 * s, cornerHeight: 8 * s, transform: nil))
            ctx.fillPath()
        }
        // Terminal prompt ">_".
        ctx.setStrokeColor(amber)
        ctx.setLineWidth(30 * s)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: p(150, 275)); ctx.addLine(to: p(230, 215)); ctx.addLine(to: p(150, 155))
        ctx.strokePath()
        ctx.setFillColor(amber)
        ctx.addPath(CGPath(roundedRect: CGRect(x: rect.minX + 270 * s, y: rect.minY + 140 * s, width: 120 * s, height: 30 * s),
                           cornerWidth: 15 * s, cornerHeight: 15 * s, transform: nil))
        ctx.fillPath()
    }
}

func write(_ ctx: CGContext, _ url: URL) {
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

func json(_ object: Any, _ url: URL) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: url)
}

let info: [String: Any] = ["author": "xcode", "version": 1]
let catalog = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Assets.xcassets", isDirectory: true)
let fm = FileManager.default
try? fm.removeItem(at: catalog)
try! fm.createDirectory(at: catalog, withIntermediateDirectories: true)
json(["info": info], catalog.appending(path: "Contents.json"))
let brand = catalog.appending(path: "App Icon & Top Shelf Image.brandassets")
try! fm.createDirectory(at: brand, withIntermediateDirectories: true)

/// One layer image: the art fills a centred square 80% of the height (inside the parallax safe zone).
func layerImage(_ layer: Layer, w: Int, h: Int) -> CGContext {
    let ctx = context(w, h)
    let W = CGFloat(w), H = CGFloat(h)
    if layer == .back { drawBack(ctx, W, H) }
    let side = H * 0.86
    drawArt(ctx, in: CGRect(x: (W - side) / 2, y: (H - side) / 2 - H * 0.02, width: side, height: side), layer: layer)
    return ctx
}

/// An image stack (App Icon, App Store icon) with Front / Middle / Back layers.
func imageStack(_ name: String, sizes: [(scale: String, w: Int, h: Int)]) {
    let stack = brand.appending(path: "\(name).imagestack")
    try! fm.createDirectory(at: stack, withIntermediateDirectories: true)
    let layers: [(String, Layer)] = [("Front", .front), ("Middle", .middle), ("Back", .back)]
    json(["info": info, "layers": layers.map { ["filename": "\($0.0).imagestacklayer"] }], stack.appending(path: "Contents.json"))
    for (title, layer) in layers {
        let dir = stack.appending(path: "\(title).imagestacklayer")
        let set = dir.appending(path: "Content.imageset")
        try! fm.createDirectory(at: set, withIntermediateDirectories: true)
        json(["info": info], dir.appending(path: "Contents.json"))
        var images: [[String: String]] = []
        for size in sizes {
            let file = "\(title.lowercased())-\(size.w)x\(size.h).png"
            write(layerImage(layer, w: size.w, h: size.h), set.appending(path: file))
            images.append(["idiom": "tv", "scale": size.scale, "filename": file])
        }
        json(["info": info, "images": images], set.appending(path: "Contents.json"))
    }
}

/// Top Shelf: the background, a row of candles on the right and the wordmark on the left.
func topShelf(_ name: String, sizes: [(scale: String, w: Int, h: Int)]) {
    let set = brand.appending(path: "\(name).imageset")
    try! fm.createDirectory(at: set, withIntermediateDirectories: true)
    var images: [[String: String]] = []
    for size in sizes {
        let ctx = context(size.w, size.h)
        let W = CGFloat(size.w), H = CGFloat(size.h)
        drawBack(ctx, W, H)
        let side = H * 0.9
        let art = CGRect(x: W - side - H * 0.25, y: (H - side) / 2, width: side, height: side)
        drawArt(ctx, in: art, layer: .middle)
        drawArt(ctx, in: art, layer: .front)
        // Wordmark.
        let font = NSFont.monospacedSystemFont(ofSize: H * 0.22, weight: .bold)
        let title = NSAttributedString(string: "finops", attributes: [.font: font, .foregroundColor: NSColor(cgColor: amber)!])
        let sub = NSAttributedString(string: "terminal · dashboards", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: H * 0.065, weight: .medium),
            .foregroundColor: NSColor(white: 0.6, alpha: 1)])
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        title.draw(at: CGPoint(x: H * 0.3, y: H * 0.42))
        sub.draw(at: CGPoint(x: H * 0.32, y: H * 0.3))
        NSGraphicsContext.restoreGraphicsState()
        let file = "\(name.lowercased().replacingOccurrences(of: " ", with: "-"))-\(size.w)x\(size.h).png"
        write(ctx, set.appending(path: file))
        images.append(["idiom": "tv", "scale": size.scale, "filename": file])
    }
    json(["info": info, "images": images], set.appending(path: "Contents.json"))
}

imageStack("App Icon", sizes: [("1x", 400, 240), ("2x", 800, 480)])
imageStack("App Icon - App Store", sizes: [("1x", 1280, 768)])
topShelf("Top Shelf Image", sizes: [("1x", 1920, 720), ("2x", 3840, 1440)])
topShelf("Top Shelf Image Wide", sizes: [("1x", 2320, 720), ("2x", 4640, 1440)])

json(["info": info, "assets": [
    ["filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"],
    ["filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"],
    ["filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"],
    ["filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"],
]], brand.appending(path: "Contents.json"))
print("wrote \(catalog.path)")
