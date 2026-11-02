// Turns a simulator recording into a small looping GIF, frame for frame, with no editing.
// Usage: swift scripts/make-demo-gif.swift <input.mov> <output.gif>
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let framesPerSecond = 12.0
let width = 300.0

let group = DispatchGroup()
group.enter()
Task {
    defer { group.leave() }
    let asset = AVURLAsset(url: input)
    let seconds = try await asset.load(.duration).seconds
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: width, height: 0)
    generator.requestedTimeToleranceAfter = .zero
    generator.requestedTimeToleranceBefore = .zero

    let count = Int(seconds * framesPerSecond)
    let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, count, nil)!
    CGImageDestinationSetProperties(
        destination,
        [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
    )
    let frameProperties =
        [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / framesPerSecond]] as CFDictionary
    for index in 0..<count {
        let time = CMTime(seconds: Double(index) / framesPerSecond, preferredTimescale: 600)
        let image = try await generator.image(at: time).image
        CGImageDestinationAddImage(destination, image, frameProperties)
    }
    CGImageDestinationFinalize(destination)
    print("wrote \(count) frames to \(output.path)")
}
group.wait()
