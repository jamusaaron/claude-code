import ARKit
import CoreVideo
import UIKit
import MeasureCore

/// A LiDAR depth reading under a screen point.
struct DepthSample {
    /// Median depth along the camera axis (m), from medium/high confidence pixels where possible.
    var depth: Float
    /// Confidence at the centre pixel (ARKit `ARConfidenceLevel`).
    var confidence: DepthConfidence
    /// The unprojected world-space point for the centre pixel at the median depth.
    var worldPosition: SIMD3<Float>
    /// Large depth spread inside the sampling window: the point is on an edge, a thin object or
    /// a hole, where the upsampled depth map blends foreground and background ("flying pixels").
    var isDiscontinuity: Bool
    /// Share of the window that had any valid depth.
    var validFraction: Float
}

/// Confidence statistics over a central region of the depth map.
struct DepthRegionStats {
    var lowConfidenceFraction: Float
    var invalidFraction: Float
    var medianDepth: Float?
}

/// Reads ARKit's per-frame LiDAR depth and confidence maps.
///
/// The depth map is 256×192 in the camera sensor's native landscape orientation, aligned with
/// `capturedImage`. A screen point goes through the inverse of `displayTransform` to normalised
/// image coordinates, then to depth-map pixels. Unprojection uses the camera intrinsics scaled
/// from the full image resolution down to the depth resolution.
enum DepthSampler {
    static func depthData(_ frame: ARFrame) -> ARDepthData? {
        frame.smoothedSceneDepth ?? frame.sceneDepth
    }

    /// Screen point → normalised image coordinates (0...1, top-left origin, sensor orientation).
    static func normalizedImagePoint(for viewPoint: CGPoint, frame: ARFrame, viewportSize: CGSize, orientation: UIInterfaceOrientation) -> CGPoint? {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return nil }
        let normalized = CGPoint(x: viewPoint.x / viewportSize.width, y: viewPoint.y / viewportSize.height)
        let toImage = frame.displayTransform(for: orientation, viewportSize: viewportSize).inverted()
        let p = normalized.applying(toImage)
        guard p.x >= 0, p.y >= 0, p.x <= 1, p.y <= 1 else { return nil }
        return p
    }

    static func sample(frame: ARFrame, viewPoint: CGPoint, viewportSize: CGSize, orientation: UIInterfaceOrientation, radius: Int = 2) -> DepthSample? {
        guard let data = depthData(frame),
              let imagePoint = normalizedImagePoint(for: viewPoint, frame: frame, viewportSize: viewportSize, orientation: orientation)
        else { return nil }

        let depthMap = data.depthMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let depthRow = CVPixelBufferGetBytesPerRow(depthMap)

        var confBase: UnsafeMutableRawPointer?
        var confRow = 0
        if let conf = data.confidenceMap {
            CVPixelBufferLockBaseAddress(conf, .readOnly)
            confBase = CVPixelBufferGetBaseAddress(conf)
            confRow = CVPixelBufferGetBytesPerRow(conf)
        }
        defer { if let conf = data.confidenceMap { CVPixelBufferUnlockBaseAddress(conf, .readOnly) } }

        let cx = min(width - 1, max(0, Int(imagePoint.x * CGFloat(width))))
        let cy = min(height - 1, max(0, Int(imagePoint.y * CGFloat(height))))

        func depth(_ x: Int, _ y: Int) -> Float {
            depthBase.load(fromByteOffset: y * depthRow + x * MemoryLayout<Float32>.stride, as: Float32.self)
        }
        func confidence(_ x: Int, _ y: Int) -> DepthConfidence {
            guard let confBase else { return .medium }
            let raw = confBase.load(fromByteOffset: y * confRow + x, as: UInt8.self)
            return DepthConfidence(rawValue: Int(raw)) ?? .low
        }

        var good: [Float] = []
        var any: [Float] = []
        var total = 0
        for y in max(0, cy - radius)...min(height - 1, cy + radius) {
            for x in max(0, cx - radius)...min(width - 1, cx + radius) {
                total += 1
                let d = depth(x, y)
                guard d.isFinite, d > 0 else { continue }
                any.append(d)
                if confidence(x, y) >= .medium { good.append(d) }
            }
        }
        let values = good.count >= 3 ? good : any
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let median = sorted[sorted.count / 2]
        let spread = (sorted.last ?? median) - (sorted.first ?? median)
        let discontinuity = spread > max(0.05, 0.08 * median)

        let world = unproject(pixelX: Float(cx) + 0.5, pixelY: Float(cy) + 0.5, depth: median, frame: frame, depthWidth: width, depthHeight: height)
        return DepthSample(
            depth: median,
            confidence: confidence(cx, cy),
            worldPosition: world,
            isDiscontinuity: discontinuity,
            validFraction: Float(any.count) / Float(max(1, total))
        )
    }

    /// Depth-map pixel + depth → world point.
    ///
    /// Camera space in ARKit: +X right, +Y up, -Z forward (in the sensor's landscape orientation),
    /// whereas image rows grow downward. So (u, v, d) maps to ((u-cx)d/fx, -(v-cy)d/fy, -d).
    static func unproject(pixelX: Float, pixelY: Float, depth: Float, frame: ARFrame, depthWidth: Int, depthHeight: Int) -> SIMD3<Float> {
        let k = frame.camera.intrinsics
        let resolution = frame.camera.imageResolution
        let sx = Float(depthWidth) / Float(resolution.width)
        let sy = Float(depthHeight) / Float(resolution.height)
        let fx = k[0][0] * sx, fy = k[1][1] * sy
        let cx = k[2][0] * sx, cy = k[2][1] * sy
        let local = SIMD4<Float>((pixelX - cx) * depth / fx, -(pixelY - cy) * depth / fy, -depth, 1)
        let world = frame.camera.transform * local
        return SIMD3(world.x, world.y, world.z)
    }

    /// Statistics over the central `regionFraction` of the depth map (used for warnings).
    static func centralStats(frame: ARFrame, regionFraction: CGFloat = 0.35) -> DepthRegionStats? {
        guard let data = depthData(frame) else { return nil }
        let depthMap = data.depthMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let width = CVPixelBufferGetWidth(depthMap), height = CVPixelBufferGetHeight(depthMap)
        let depthRow = CVPixelBufferGetBytesPerRow(depthMap)

        var confBase: UnsafeMutableRawPointer?
        var confRow = 0
        if let conf = data.confidenceMap {
            CVPixelBufferLockBaseAddress(conf, .readOnly)
            confBase = CVPixelBufferGetBaseAddress(conf)
            confRow = CVPixelBufferGetBytesPerRow(conf)
        }
        defer { if let conf = data.confidenceMap { CVPixelBufferUnlockBaseAddress(conf, .readOnly) } }

        let x0 = Int(CGFloat(width) * (0.5 - regionFraction / 2)), x1 = Int(CGFloat(width) * (0.5 + regionFraction / 2))
        let y0 = Int(CGFloat(height) * (0.5 - regionFraction / 2)), y1 = Int(CGFloat(height) * (0.5 + regionFraction / 2))
        var total = 0, low = 0, invalid = 0
        var depths: [Float] = []
        depths.reserveCapacity((x1 - x0) * (y1 - y0) / 4)
        // Every second pixel is plenty for statistics.
        for y in stride(from: y0, to: y1, by: 2) {
            for x in stride(from: x0, to: x1, by: 2) {
                total += 1
                let d = depthBase.load(fromByteOffset: y * depthRow + x * 4, as: Float32.self)
                if !(d.isFinite && d > 0) { invalid += 1; continue }
                depths.append(d)
                if let confBase, confBase.load(fromByteOffset: y * confRow + x, as: UInt8.self) == 0 { low += 1 }
            }
        }
        guard total > 0 else { return nil }
        depths.sort()
        return DepthRegionStats(
            lowConfidenceFraction: Float(low) / Float(total),
            invalidFraction: Float(invalid) / Float(total),
            medianDepth: depths.isEmpty ? nil : depths[depths.count / 2]
        )
    }

    /// Colour-coded confidence image (sensor orientation) for the overlay: transparent where
    /// confidence is high, amber for medium, red for low or missing depth.
    static func confidenceOverlay(frame: ARFrame) -> CGImage? {
        guard let data = depthData(frame), let conf = data.confidenceMap else { return nil }
        CVPixelBufferLockBaseAddress(conf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(conf, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(conf) else { return nil }
        let width = CVPixelBufferGetWidth(conf), height = CVPixelBufferGetHeight(conf)
        let row = CVPixelBufferGetBytesPerRow(conf)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let c = base.load(fromByteOffset: y * row + x, as: UInt8.self)
                let o = (y * width + x) * 4
                switch c {
                case 2: continue // high: leave transparent (premultiplied zeros)
                case 1: // medium: amber, alpha 0.35 (premultiplied)
                    rgba[o] = 89; rgba[o + 1] = 70; rgba[o + 2] = 0; rgba[o + 3] = 89
                default: // low
                    rgba[o] = 140; rgba[o + 1] = 25; rgba[o + 2] = 20; rgba[o + 3] = 140
                }
            }
        }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
