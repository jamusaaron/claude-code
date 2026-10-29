import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import MeasureCore

/// Simple colour correction applied to the captured texture.
struct ColorAdjustments: Equatable, Codable {
    /// Equalise exposure between keyframes so neighbouring faces from different frames match.
    var normaliseExposure = true
    /// Exposure compensation in EV stops.
    var exposure: Double = 0
    var contrast: Double = 1
    var saturation: Double = 1
    /// White balance target in kelvin (6500 = neutral).
    var temperature: Double = 6500

    static let neutral = ColorAdjustments()
}

/// Builds the texture atlas image described by `AtlasLayout` from the stored keyframe JPEGs.
///
/// Each keyframe is drawn into its cell, after optional per-keyframe exposure normalisation
/// (ARKit auto-exposure changes between frames, which otherwise shows as patchy brightness) and
/// the user's global adjustments. Adjustments are applied per cell rather than to the finished
/// atlas, so peak memory stays at one full-size bitmap (~50 MB for 4096²).
enum AtlasCompositor {
    enum CompositorError: LocalizedError {
        case contextCreationFailed
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .contextCreationFailed: return "Couldn't allocate the texture image (not enough memory)."
            case .encodingFailed: return "Couldn't encode the texture image."
            }
        }
    }

    static func compose(layout: AtlasLayout, keyframes: [Int: KeyframeRecord], adjustments: ColorAdjustments) throws -> CGImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: layout.width, height: layout.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw CompositorError.contextCreationFailed }

        // Neutral grey everywhere (the gutter strip is what untextured faces sample).
        ctx.setFillColor(CGColor(gray: 0.55, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: layout.width, height: layout.height))
        ctx.interpolationQuality = .high

        let ciContext = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: space])
        let images: [(AtlasCell, CIImage)] = layout.cells.compactMap { cell in
            guard let record = keyframes[cell.keyframeID],
                  let source = CGImageSourceCreateWithURL(record.imageURL as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { return nil }
            return (cell, CIImage(cgImage: image))
        }

        // Exposure normalisation towards the median keyframe brightness.
        var gains: [Int: Double] = [:]
        if adjustments.normaliseExposure {
            let lumas = images.compactMap { cell, image in meanLuminance(image, context: ciContext).map { (cell.keyframeID, $0) } }
            let sorted = lumas.map { $0.1 }.sorted()
            if let target = sorted.isEmpty ? nil : sorted[sorted.count / 2], target > 0.02 {
                for (id, luma) in lumas where luma > 0.02 {
                    gains[id] = max(-0.6, min(0.6, log2(target / luma)))
                }
            }
        }

        for (cell, image) in images {
            autoreleasepool {
                var ci = image
                let ev = (gains[cell.keyframeID] ?? 0) + adjustments.exposure
                if abs(ev) > 0.01 {
                    ci = ci.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: ev])
                }
                if abs(adjustments.contrast - 1) > 0.001 || abs(adjustments.saturation - 1) > 0.001 {
                    ci = ci.applyingFilter("CIColorControls", parameters: [
                        kCIInputContrastKey: adjustments.contrast,
                        kCIInputSaturationKey: adjustments.saturation,
                        kCIInputBrightnessKey: 0,
                    ])
                }
                if abs(adjustments.temperature - 6500) > 1 {
                    ci = ci.applyingFilter("CITemperatureAndTint", parameters: [
                        "inputNeutral": CIVector(x: 6500, y: 0),
                        "inputTargetNeutral": CIVector(x: CGFloat(adjustments.temperature), y: 0),
                    ])
                }
                guard let rendered = ciContext.createCGImage(ci, from: image.extent) else { return }
                // CoreGraphics has a bottom-left origin; atlas cells are laid out top-left.
                let rect = CGRect(x: cell.x, y: layout.height - cell.y - cell.height, width: cell.width, height: cell.height)
                ctx.draw(rendered, in: rect)
            }
        }

        guard let atlas = ctx.makeImage() else { throw CompositorError.contextCreationFailed }
        return atlas
    }

    static func meanLuminance(_ image: CIImage, context: CIContext) -> Double? {
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: image,
            kCIInputExtentKey: CIVector(cgRect: image.extent),
        ]), let output = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return (0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2])) / 255
    }

    static func jpegData(_ image: CGImage, quality: Double = 0.88) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CompositorError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CompositorError.encodingFailed }
        return data as Data
    }

    /// Portrait thumbnail from a keyframe (keyframes are stored in landscape sensor orientation).
    static func thumbnail(from record: KeyframeRecord, maxDimension: CGFloat = 360) -> Data? {
        guard let source = CGImageSourceCreateWithURL(record.imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        var ci = CIImage(cgImage: image).oriented(.right)
        let scale = maxDimension / max(ci.extent.width, ci.extent.height)
        ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.origin.x, y: -ci.extent.origin.y))
        let context = CIContext()
        guard let cg = context.createCGImage(ci, from: ci.extent) else { return nil }
        return try? jpegData(cg, quality: 0.8)
    }
}
