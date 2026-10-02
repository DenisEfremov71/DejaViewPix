#!/usr/bin/env swift
//
//  seed-simulator-photos.swift
//
//  Generates labeled JPEGs with EXIF capture dates and GPS coordinates, then adds them to
//  the booted simulator's photo library, so searches have real dates and places to find.
//
//  Usage: swift scripts/seed-simulator-photos.swift [output-dir]
//

import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Sample {
    var name: String
    var date: String  // local time, "yyyy:MM:dd HH:mm:ss"
    var offset: String  // UTC offset of `date`, e.g. "-08:00"
    var location: (latitude: Double, longitude: Double)?
}

let samples = [
    Sample(name: "Whistler Village", date: "2026:01:14 10:30:00", offset: "-08:00", location: (50.1163, -122.9574)),
    Sample(name: "Blackcomb Peak", date: "2026:02:07 13:15:00", offset: "-08:00", location: (50.0950, -122.8890)),
    Sample(name: "Whistler Creekside", date: "2025:12:28 09:45:00", offset: "-08:00", location: (50.0950, -122.9890)),
    Sample(name: "Whistler in summer", date: "2025:07:19 16:00:00", offset: "-07:00", location: (50.1163, -122.9574)),
    Sample(name: "Stanley Park, Vancouver", date: "2026:01:03 11:00:00", offset: "-08:00", location: (49.3043, -123.1443)),
    Sample(name: "Squamish", date: "2026:02:14 15:30:00", offset: "-08:00", location: (49.7016, -123.1558)),
    Sample(name: "Eiffel Tower, Paris", date: "2026:06:12 19:20:00", offset: "+02:00", location: (48.8584, 2.2945)),
    Sample(name: "Long Beach, Tofino", date: "2026:08:09 18:40:00", offset: "-07:00", location: (49.0806, -125.7576)),
    Sample(name: "No location (Jan 20)", date: "2026:01:20 08:00:00", offset: "-08:00", location: nil),
]

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? NSTemporaryDirectory())
    .appendingPathComponent("seed-photos", isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func makeImage(label: String, hue: CGFloat) -> CGImage {
    let width = 1200, height = 900
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: hue, green: 0.55, blue: 1 - hue, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 72, nil)
    let text = NSAttributedString(string: label, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
    ])
    let line = CTLineCreateWithAttributedString(text)
    context.textPosition = CGPoint(x: 60, y: CGFloat(height) / 2)
    CTLineDraw(line, context)
    return context.makeImage()!
}

var paths: [String] = []
for (index, sample) in samples.enumerated() {
    let label = "\(sample.name)  \(sample.date.prefix(10).replacingOccurrences(of: ":", with: "-"))"
    let image = makeImage(label: label, hue: CGFloat(index) / CGFloat(samples.count))

    var properties: [CFString: Any] = [
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: sample.date,
            kCGImagePropertyExifDateTimeDigitized: sample.date,
            kCGImagePropertyExifOffsetTimeOriginal: sample.offset,
            kCGImagePropertyExifOffsetTimeDigitized: sample.offset,
        ],
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFDateTime: sample.date],
    ]
    if let location = sample.location {
        properties[kCGImagePropertyGPSDictionary] = [
            kCGImagePropertyGPSLatitude: abs(location.latitude),
            kCGImagePropertyGPSLatitudeRef: location.latitude >= 0 ? "N" : "S",
            kCGImagePropertyGPSLongitude: abs(location.longitude),
            kCGImagePropertyGPSLongitudeRef: location.longitude >= 0 ? "E" : "W",
        ]
    }

    let fileName = sample.name.replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression)
    let url = outputDirectory.appendingPathComponent("\(index + 1)-\(fileName).jpg")
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { fatalError("Could not write \(url.path)") }
    paths.append(url.path)
}

let simctl = Process()
simctl.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
simctl.arguments = ["simctl", "addmedia", "booted"] + paths
try simctl.run()
simctl.waitUntilExit()
print(simctl.terminationStatus == 0
    ? "Added \(paths.count) photos to the booted simulator."
    : "simctl addmedia failed; the JPEGs are in \(outputDirectory.path).")
