#!/usr/bin/env swift
// Draws the finops-terminal app icon with CoreGraphics.
//   swift app/scripts/make_icon.swift <output-dir>
// Writes icon-ios-1024.png (full bleed; iPadOS applies the mask) and
// icon-mac-1024.png (macOS rounded rectangle with margin and shadow).

import AppKit
import CoreGraphics
import Foundation

let size: CGFloat = 1024
let amber = CGColor(red: 1.0, green: 0.66, blue: 0.10, alpha: 1)
let amberSoft = CGColor(red: 1.0, green: 0.66, blue: 0.10, alpha: 0.35)
let red = CGColor(red: 0.95, green: 0.33, blue: 0.30, alpha: 1)
let grid = CGColor(red: 1, green: 1, blue: 1, alpha: 0.055)

func makeContext() -> CGContext {
    CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

/// The artwork inside `rect` (origin bottom-left, CoreGraphics coordinates).
func drawArtwork(_ ctx: CGContext, in rect: CGRect) {
    let s = rect.width / size  // scale relative to a 1024 design

    // Background: near-black vertical gradient.
    let bg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
        CGColor(red: 0.115, green: 0.115, blue: 0.13, alpha: 1),
        CGColor(red: 0.035, green: 0.035, blue: 0.045, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])

    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }

    // Chart grid.
    ctx.setStrokeColor(grid)
    ctx.setLineWidth(3 * s)
    for i in 1...5 {
        let y = CGFloat(i) * 1024 / 6
        ctx.move(to: p(96, y)); ctx.addLine(to: p(928, y))
    }
    for i in 1...6 {
        let x = 96 + CGFloat(i) * 832 / 7
        ctx.move(to: p(x, 300)); ctx.addLine(to: p(x, 900))
    }
    ctx.strokePath()

    // Candlesticks rising left to right (one red pullback for realism).
    struct Candle { let x, low, open, close, high: CGFloat }
    let candles = [
        Candle(x: 230, low: 390, open: 420, close: 500, high: 530),
        Candle(x: 345, low: 455, open: 500, close: 575, high: 610),
        Candle(x: 460, low: 520, open: 600, close: 545, high: 625),  // down
        Candle(x: 575, low: 540, open: 560, close: 660, high: 690),
        Candle(x: 690, low: 640, open: 665, close: 745, high: 785),
        Candle(x: 805, low: 720, open: 750, close: 840, high: 880),
    ]
    let bodyWidth: CGFloat = 62
    for c in candles {
        let up = c.close >= c.open
        let color = up ? amber : red
        ctx.setStrokeColor(color)
        ctx.setLineWidth(10 * s)
        ctx.setLineCap(.round)
        ctx.move(to: p(c.x, c.low)); ctx.addLine(to: p(c.x, c.high))
        ctx.strokePath()
        let body = CGRect(x: rect.minX + (c.x - bodyWidth / 2) * s, y: rect.minY + min(c.open, c.close) * s,
                          width: bodyWidth * s, height: abs(c.close - c.open) * s)
        ctx.setFillColor(color)
        ctx.addPath(CGPath(roundedRect: body, cornerWidth: 8 * s, cornerHeight: 8 * s, transform: nil))
        ctx.fillPath()
    }

    // Trend line through the closes, with a soft glow.
    let closes = candles.map { p($0.x, $0.close + 40) }
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 28 * s, color: amberSoft)
    ctx.setStrokeColor(CGColor(red: 1.0, green: 0.80, blue: 0.40, alpha: 0.9))
    ctx.setLineWidth(9 * s)
    ctx.setLineJoin(.round)
    ctx.setLineCap(.round)
    ctx.addLines(between: closes)
    ctx.strokePath()
    ctx.restoreGState()

    // Terminal prompt ">_" bottom-left.
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

func writePNG(_ ctx: CGContext, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote \(url.path)")
}

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".", isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

// iPadOS: full bleed, opaque (the system applies the rounded mask).
let ios = makeContext()
drawArtwork(ios, in: CGRect(x: 0, y: 0, width: size, height: size))
writePNG(ios, to: out.appending(path: "icon-ios-1024.png"))

// macOS: 824 pt rounded rectangle centred on a transparent 1024 canvas, with a drop shadow.
let mac = makeContext()
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
mac.saveGState()
mac.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.45))
mac.addPath(shape)
mac.setFillColor(CGColor(gray: 0.05, alpha: 1))
mac.fillPath()
mac.restoreGState()
mac.saveGState()
mac.addPath(shape)
mac.clip()
drawArtwork(mac, in: tile)
mac.restoreGState()
mac.addPath(shape)
mac.setStrokeColor(CGColor(gray: 1, alpha: 0.08))
mac.setLineWidth(3)
mac.strokePath()
writePNG(mac, to: out.appending(path: "icon-mac-1024.png"))
