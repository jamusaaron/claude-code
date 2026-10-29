import ARKit
import CoreImage
import Foundation
import ImageIO
import simd
import MeasureCore

/// A camera frame saved for texturing: JPEG + LiDAR depth on disk, pose and intrinsics in memory.
struct KeyframeRecord: Sendable {
    let id: Int
    let imageURL: URL
    let depthURL: URL?
    let depthWidth: Int
    let depthHeight: Int
    let cameraToWorld: RigidTransform
    /// Intrinsics for the stored (downscaled) JPEG.
    let intrinsics: CameraIntrinsics

    func loadKeyframe() -> Keyframe {
        var depth: DepthImage?
        if let depthURL, let data = try? Data(contentsOf: depthURL), data.count == depthWidth * depthHeight * 4 {
            let values = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            depth = DepthImage(width: depthWidth, height: depthHeight, values: values)
        }
        return Keyframe(id: id, cameraToWorld: cameraToWorld, intrinsics: intrinsics, depth: depth)
    }
}

/// Picks well-spaced, sharp frames during a scan and writes them to disk.
///
/// Memory: the AR session must never be starved of camera buffers, so at most one frame is in
/// flight; frames arriving while it encodes are skipped. Images are stored as 1024-px JPEGs
/// (~150 KB) and depth as raw float32 (192 KB), so 100 keyframes cost ~35 MB of disk and almost
/// no RAM during the scan.
@MainActor
final class KeyframeRecorder {
    let directory: URL
    let maxKeyframes: Int
    private(set) var records: [KeyframeRecord] = []
    private var lastKeyPose: simd_float4x4?
    private var lastSample: (time: TimeInterval, pose: simd_float4x4)?
    private var isEncoding = false
    private var nextID = 0
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Stored image width; height follows the camera's aspect ratio (4:3 → 768).
    static let storedWidth = 1024
    /// New keyframe after this much translation (m) or rotation (rad).
    static let minimumTranslation: Float = 0.12
    static let minimumRotation: Float = 0.21
    /// Skip frames moving faster than this: they are motion-blurred.
    static let maximumAngularSpeed: Float = 0.8
    static let maximumLinearSpeed: Float = 0.6

    init(directory: URL, maxKeyframes: Int = 100) {
        self.directory = directory
        self.maxKeyframes = maxKeyframes
    }

    var isFull: Bool { records.count >= maxKeyframes }

    func consider(_ frame: ARFrame) {
        guard !isEncoding, !isFull, case .normal = frame.camera.trackingState else { return }
        let pose = frame.camera.transform

        // Motion-blur gate: speed since the previous sample.
        defer { lastSample = (frame.timestamp, pose) }
        if let last = lastSample {
            let dt = Float(frame.timestamp - last.time)
            if dt > 0 {
                let angular = Self.rotationAngle(from: last.pose, to: pose) / dt
                let linear = simd_distance(last.pose.origin, pose.origin) / dt
                if angular > Self.maximumAngularSpeed || linear > Self.maximumLinearSpeed { return }
            }
        }

        // Novelty gate: far enough from the previous keyframe.
        if let key = lastKeyPose {
            let moved = simd_distance(key.origin, pose.origin)
            let turned = Self.rotationAngle(from: key, to: pose)
            guard moved >= Self.minimumTranslation || turned >= Self.minimumRotation else { return }
        }
        if let light = frame.lightEstimate, light.ambientIntensity < 60 { return } // too dark to be useful colour

        lastKeyPose = pose
        isEncoding = true

        let id = nextID
        nextID += 1
        let pixelBuffer = frame.capturedImage
        let resolution = frame.camera.imageResolution
        let k = frame.camera.intrinsics
        let fullIntrinsics = CameraIntrinsics(
            fx: Double(k[0][0]), fy: Double(k[1][1]), cx: Double(k[2][0]), cy: Double(k[2][1]),
            width: Int(resolution.width), height: Int(resolution.height)
        )
        let storedHeight = Int((Double(Self.storedWidth) * Double(resolution.height) / Double(resolution.width)).rounded())
        let intrinsics = fullIntrinsics.scaled(toWidth: Self.storedWidth, height: storedHeight)
        let depth = Self.copyDepth(frame)
        let cameraToWorld = RigidTransform(pose)
        let directory = self.directory
        let context = self.ciContext
        let storedWidth = Self.storedWidth

        Task.detached(priority: .utility) { [self] in
            let imageURL = directory.appendingPathComponent("kf-\(id).jpg")
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            let scale = CGFloat(storedWidth) / resolution.width
            let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            var wrote = false
            if let space = CGColorSpace(name: CGColorSpace.sRGB),
               let jpeg = context.jpegRepresentation(of: scaled, colorSpace: space, options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.85]) {
                wrote = (try? jpeg.write(to: imageURL)) != nil
            }
            var depthURL: URL?
            if let depth {
                let url = directory.appendingPathComponent("kf-\(id).depth")
                let data = depth.values.withUnsafeBytes { Data($0) }
                if (try? data.write(to: url)) != nil { depthURL = url }
            }
            let record = wrote ? KeyframeRecord(id: id, imageURL: imageURL, depthURL: depthURL,
                                                depthWidth: depth?.width ?? 0, depthHeight: depth?.height ?? 0,
                                                cameraToWorld: cameraToWorld, intrinsics: intrinsics) : nil
            await MainActor.run {
                if let record { self.records.append(record) }
                self.isEncoding = false
            }
        }
    }

    /// Copies the depth map, zeroing low-confidence pixels so the occlusion test ignores them.
    static func copyDepth(_ frame: ARFrame) -> (width: Int, height: Int, values: [Float])? {
        guard let data = frame.smoothedSceneDepth ?? frame.sceneDepth else { return nil }
        let map = data.depthMap
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map)
        let row = CVPixelBufferGetBytesPerRow(map)

        var confBase: UnsafeMutableRawPointer?
        var confRow = 0
        if let conf = data.confidenceMap {
            CVPixelBufferLockBaseAddress(conf, .readOnly)
            confBase = CVPixelBufferGetBaseAddress(conf)
            confRow = CVPixelBufferGetBytesPerRow(conf)
        }
        defer { if let conf = data.confidenceMap { CVPixelBufferUnlockBaseAddress(conf, .readOnly) } }

        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                var d = base.load(fromByteOffset: y * row + x * 4, as: Float32.self)
                if let confBase, confBase.load(fromByteOffset: y * confRow + x, as: UInt8.self) == 0 { d = 0 }
                values[y * width + x] = d.isFinite ? d : 0
            }
        }
        return (width, height, values)
    }

    /// Angle (rad) of the relative rotation between two poses.
    static func rotationAngle(from a: simd_float4x4, to b: simd_float4x4) -> Float {
        let qa = simd_quatf(a), qb = simd_quatf(b)
        let dot = abs(simd_dot(qa.vector, qb.vector))
        return 2 * acos(min(1, dot))
    }

    /// Deletes all keyframe files.
    func discard() {
        try? FileManager.default.removeItem(at: directory)
        records.removeAll()
    }
}
