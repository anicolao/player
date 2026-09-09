#!/usr/bin/env swift

import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Listing: Decodable {
  let slides: [Slide]
}

struct Slide: Decodable {
  let id: String
  let theme: String
  let eyebrow: String
  let headline: String
  let body: String
  let layout: String
  let sources: [String]
}

struct Palette {
  let backgroundTop: CGColor
  let backgroundBottom: CGColor
  let ink: CGColor
  let muted: CGColor
  let accent: CGColor
  let frame: CGColor
}

let canvasWidth = 1320
let canvasHeight = 2868

func color(_ hex: UInt32) -> CGColor {
  CGColor(
    colorSpace: CGColorSpaceCreateDeviceRGB(),
    components: [
      CGFloat((hex >> 16) & 0xff) / 255,
      CGFloat((hex >> 8) & 0xff) / 255,
      CGFloat(hex & 0xff) / 255,
      1,
    ]
  )!
}

func palette(named name: String) -> Palette {
  switch name {
  case "ember":
    return Palette(
      backgroundTop: color(0xc65735), backgroundBottom: color(0x92341f),
      ink: color(0xfffaf1), muted: color(0xf6d4c4), accent: color(0x272c2f), frame: color(0x6f2618)
    )
  case "night":
    return Palette(
      backgroundTop: color(0x2d3336), backgroundBottom: color(0x171c1f),
      ink: color(0xfffaf1), muted: color(0xd7d0c6), accent: color(0xe26c42), frame: color(0x0d1012)
    )
  default:
    return Palette(
      backgroundTop: color(0xfffaf1), backgroundBottom: color(0xeee2d2),
      ink: color(0x202529), muted: color(0x65645f), accent: color(0xb9472b), frame: color(0x352720)
    )
  }
}

func loadImage(_ url: URL) throws -> CGImage {
  guard
    let source = CGImageSourceCreateWithURL(url as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
  else {
    throw NSError(domain: "ListingRenderer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not load \(url.path)"])
  }
  return image
}

func font(_ preferred: String, fallback: NSFont, size: CGFloat) -> CTFont {
  if let selected = NSFont(name: preferred, size: size) {
    return selected as CTFont
  }
  return fallback.withSize(size) as CTFont
}

func drawText(
  _ text: String,
  in rect: CGRect,
  font: CTFont,
  color: CGColor,
  lineSpacing: CGFloat = 0,
  tracking: CGFloat = 0
) {
  let paragraph = NSMutableParagraphStyle()
  paragraph.lineSpacing = lineSpacing
  paragraph.lineBreakMode = .byWordWrapping
  let attributes: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor(cgColor: color)!,
    .paragraphStyle: paragraph,
    .kern: tracking,
  ]
  let attributed = NSAttributedString(string: text, attributes: attributes)
  let setter = CTFramesetterCreateWithAttributedString(attributed)
  let path = CGPath(rect: rect, transform: nil)
  let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
  CTFrameDraw(frame, NSGraphicsContext.current!.cgContext)
}

func drawPhone(_ image: CGImage, in rect: CGRect, context: CGContext, frameColor: CGColor) {
  // Match the proportions used by the website's current iPhone frame. The
  // XCTest framebuffer has square outer pixels, so both renderers must restore
  // the physical display mask themselves.
  let outerRect = rect.insetBy(dx: -16, dy: -16)
  let outerCornerRadius = outerRect.width * (38.0 / 325.0)
  let displayCornerRadius = rect.width * (30.0 / 311.0)

  context.saveGState()
  context.setShadow(offset: CGSize(width: 0, height: -22), blur: 44, color: color(0x000000).copy(alpha: 0.28))
  context.setFillColor(frameColor)
  let outer = CGPath(
    roundedRect: outerRect,
    cornerWidth: outerCornerRadius,
    cornerHeight: outerCornerRadius,
    transform: nil
  )
  context.addPath(outer)
  context.fillPath()
  context.restoreGState()

  context.saveGState()
  let clip = CGPath(
    roundedRect: rect,
    cornerWidth: displayCornerRadius,
    cornerHeight: displayCornerRadius,
    transform: nil
  )
  context.addPath(clip)
  context.clip()
  context.interpolationQuality = .high
  context.draw(image, in: rect)

  // XCTest's XCUIScreen attachment captures the app framebuffer but omits the
  // physical display mask. Restore the Dynamic Island used by the iPhone 17
  // marketing device so these frames match the website's phone treatment.
  let islandWidth = rect.width * 0.313
  let islandHeight = rect.height * 0.0332
  let islandTopInset = rect.height * 0.0122
  let islandRect = CGRect(
    x: rect.midX - islandWidth / 2,
    y: rect.maxY - islandTopInset - islandHeight,
    width: islandWidth,
    height: islandHeight
  )
  context.setFillColor(color(0x000000))
  context.addPath(
    CGPath(
      roundedRect: islandRect,
      cornerWidth: islandHeight / 2,
      cornerHeight: islandHeight / 2,
      transform: nil
    )
  )
  context.fillPath()
  context.restoreGState()
}

func render(slide: Slide, input: URL, output: URL) throws {
  let colorSpace = CGColorSpaceCreateDeviceRGB()
  guard let context = CGContext(
    data: nil,
    width: canvasWidth,
    height: canvasHeight,
    bitsPerComponent: 8,
    bytesPerRow: canvasWidth * 4,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
  ) else {
    throw NSError(domain: "ListingRenderer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create canvas"])
  }

  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
  defer { NSGraphicsContext.restoreGraphicsState() }

  let colors = palette(named: slide.theme)
  let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [colors.backgroundBottom, colors.backgroundTop] as CFArray,
    locations: [0, 1]
  )!
  context.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: 0),
    end: CGPoint(x: CGFloat(canvasWidth), y: CGFloat(canvasHeight)),
    options: []
  )

  context.saveGState()
  context.setFillColor(colors.accent.copy(alpha: slide.theme == "paper" ? 0.08 : 0.15)!)
  context.fillEllipse(in: CGRect(x: 880, y: 2210, width: 620, height: 620))
  context.restoreGState()

  drawText(
    slide.eyebrow,
    in: CGRect(x: 92, y: 2670, width: 1136, height: 76),
    font: font("SFProDisplay-Bold", fallback: .boldSystemFont(ofSize: 35), size: 35),
    color: colors.accent,
    tracking: 4
  )
  drawText(
    slide.headline,
    in: CGRect(x: 82, y: 2240, width: 1160, height: 420),
    font: font("IowanOldStyle-Bold", fallback: .systemFont(ofSize: 104, weight: .bold), size: 104),
    color: colors.ink,
    lineSpacing: -7
  )
  drawText(
    slide.body,
    in: CGRect(x: 92, y: 2048, width: 1120, height: 192),
    font: font("SFProDisplay-Regular", fallback: .systemFont(ofSize: 50), size: 50),
    color: colors.muted,
    lineSpacing: 6
  )

  let images = try slide.sources.map { try loadImage(input.appendingPathComponent($0)) }
  if slide.layout == "pair", images.count == 2 {
    let width: CGFloat = 650
    let height = width * CGFloat(images[0].height) / CGFloat(images[0].width)
    drawPhone(images[0], in: CGRect(x: -80, y: 250, width: width, height: height), context: context, frameColor: colors.frame)
    drawPhone(images[1], in: CGRect(x: 750, y: 80, width: width, height: height), context: context, frameColor: colors.frame)
  } else if let image = images.first {
    let width: CGFloat = 960
    let height = width * CGFloat(image.height) / CGFloat(image.width)
    drawPhone(image, in: CGRect(x: 180, y: -120, width: width, height: height), context: context, frameColor: colors.frame)
  }

  guard let rendered = context.makeImage() else {
    throw NSError(domain: "ListingRenderer", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not finish canvas"])
  }
  guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    throw NSError(domain: "ListingRenderer", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not create \(output.path)"])
  }
  CGImageDestinationAddImage(destination, rendered, nil)
  guard CGImageDestinationFinalize(destination) else {
    throw NSError(domain: "ListingRenderer", code: 5, userInfo: [NSLocalizedDescriptionKey: "Could not write \(output.path)"])
  }
}

guard CommandLine.arguments.count == 4 else {
  fputs("usage: render-app-store-listing.swift <listing.json> <fresh-screenshot-directory> <output-directory>\n", stderr)
  exit(2)
}

let listingURL = URL(fileURLWithPath: CommandLine.arguments[1])
let inputURL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let outputURL = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
let listing = try JSONDecoder().decode(Listing.self, from: Data(contentsOf: listingURL))
try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

for slide in listing.slides {
  let destination = outputURL.appendingPathComponent("\(slide.id).png")
  try render(slide: slide, input: inputURL, output: destination)
  print(destination.path)
}
