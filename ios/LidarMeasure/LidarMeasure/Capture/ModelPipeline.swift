import CoreGraphics
import Foundation
import simd
import MeasureCore

/// Everything captured during a scan, frozen when the user taps Stop.
struct CaptureSnapshot: Sendable {
    var rawMesh: TriangleMesh
    var keyframes: [KeyframeRecord]
    var keyframeDirectory: URL
    var region: OrientedBox?
    var scope: CaptureScope
}

/// User-tunable cleanup, texture and material options.
struct ProcessingOptions: Equatable {
    var cropToRegion = true
    /// Extra margin around the capture box (m).
    var cropMargin: Double = 0.02
    var removeSupportSurface = true
    /// Vertex clustering cell (cm). 0 keeps full LiDAR resolution.
    var simplifyCentimetres: Double = 1
    var removeNoise = true
    /// Pieces smaller than this share of the main piece are removed.
    var noiseThreshold: Double = 0.02
    var textureKeyframes = 16
    var materialPreset: MaterialSpec.Preset = .capturedTexture
    var customColour = SIMD3<Float>(0.8, 0.8, 0.8)
    var adjustments = ColorAdjustments.neutral
}

/// A processed model waiting in a temporary folder to be saved or discarded.
struct ProcessedModel: Identifiable, Equatable {
    let id = UUID()
    let folder: URL
    let stats: ModelStats
    var usdzURL: URL { folder.appendingPathComponent(ModelStore.usdzFile) }
}

/// Post-scan processing: cleanup → texture projection → atlas → USDZ.
///
/// Runs off the main thread. The raw snapshot is never modified, so the user can change
/// options and re-run without rescanning.
enum ModelPipeline {
    enum PipelineError: LocalizedError {
        case emptyMesh
        case nothingInRegion

        var errorDescription: String? {
            switch self {
            case .emptyMesh: return "The scan has no geometry. Scan for longer, closer to the surfaces (0.3–3 m)."
            case .nothingInRegion: return "Nothing was captured inside the box. Move or enlarge it, or turn off cropping."
            }
        }
    }

    typealias Progress = @Sendable (_ stage: String, _ fraction: Double) -> Void

    static func run(_ snapshot: CaptureSnapshot, options: ProcessingOptions, progress: Progress) throws -> ProcessedModel {
        guard !snapshot.rawMesh.isEmpty else { throw PipelineError.emptyMesh }

        // 1. Cleanup.
        var cleanup = MeshCleanupOptions()
        if options.cropToRegion, var box = snapshot.region {
            box.size += Vec3(repeating: options.cropMargin * 2)
            box.center.y += options.cropMargin // keep the base where it was
            cleanup.cropBox = box
        }
        if options.removeSupportSurface, let region = snapshot.region {
            cleanup.supportPlaneY = region.baseY
        }
        cleanup.simplifyCellSize = options.simplifyCentimetres / 100
        if options.removeNoise {
            cleanup.minimumComponentShare = options.noiseThreshold
            cleanup.minimumComponentTriangles = 30
        } else {
            cleanup.minimumComponentShare = 0
            cleanup.minimumComponentTriangles = 0
        }
        progress("Cleaning mesh", 0)
        let cleaned = MeshProcessing.process(snapshot.rawMesh, options: cleanup) { progress("Cleaning mesh", $0 * 0.3) }
        guard !cleaned.isEmpty else { throw snapshot.region != nil && options.cropToRegion ? PipelineError.nothingInRegion : PipelineError.emptyMesh }
        try Task.checkCancellation()

        // 2. Volume: exact for a closed single-piece mesh; for object scans, the open-bottomed
        //    surface plus the support plane; otherwise none (rooms are open by nature).
        let volume = VolumeGeometry.estimateVolume(
            positions: cleaned.positions,
            indices: cleaned.indices,
            supportPlaneY: snapshot.scope == .object ? snapshot.region?.baseY : nil
        )

        // 3. Texture.
        let material = MaterialSpec.preset(options.materialPreset, customColour: options.customColour)
        var textured = TexturedMesh(untextured: cleaned)
        var textureJPEG: Data?
        if material.usesTexture, !snapshot.keyframes.isEmpty {
            progress("Projecting texture", 0.3)
            let keyframes = snapshot.keyframes.map { $0.loadKeyframe() }
            let projection = TextureProjectionOptions(maxKeyframes: options.textureKeyframes)
            let candidate = TextureProjector.project(mesh: cleaned, keyframes: keyframes, options: projection) {
                progress("Projecting texture", 0.3 + $0 * 0.35)
            }
            try Task.checkCancellation()
            if let layout = candidate.atlas {
                progress("Building texture atlas", 0.65)
                let records = Dictionary(uniqueKeysWithValues: snapshot.keyframes.map { ($0.id, $0) })
                let atlas = try AtlasCompositor.compose(layout: layout, keyframes: records, adjustments: options.adjustments)
                textureJPEG = try AtlasCompositor.jpegData(atlas)
                textured = candidate
            }
        }
        try Task.checkCancellation()

        // 4. Put the origin at the bottom centre so the model sits on the floor in AR Quick Look.
        guard let bounds = textured.bounds else { throw PipelineError.emptyMesh }
        textured = textured.translated(by: -bounds.baseCenter)

        // 5. Write the bundle.
        progress("Writing USDZ", 0.85)
        let folder = try ModelStore.makeTemporaryFolder(prefix: "model")
        try MeshArchive.encode(textured).write(to: folder.appendingPathComponent(ModelStore.meshFile), options: .atomic)
        if let textureJPEG {
            try textureJPEG.write(to: folder.appendingPathComponent(ModelStore.textureFile), options: .atomic)
        }
        let usdz = try USDZExporter.makeUSDZ(mesh: textured, material: material, textureJPEG: textureJPEG)
        try usdz.write(to: folder.appendingPathComponent(ModelStore.usdzFile), options: .atomic)

        if let best = bestThumbnailKeyframe(snapshot.keyframes, target: Vec.double(bounds.center)),
           let thumb = AtlasCompositor.thumbnail(from: best) {
            try? thumb.write(to: folder.appendingPathComponent(ModelStore.thumbnailFile), options: .atomic)
        }

        let size = bounds.size
        let stats = ModelStats(
            vertexCount: textured.vertexCount,
            triangleCount: textured.triangleCount,
            size: Vec3(Double(size.x), Double(size.y), Double(size.z)),
            volume: volume?.volume,
            volumeReliable: volume?.isReliable ?? false,
            volumeOpenness: volume?.openness,
            volumeMethod: volume?.method,
            texturedShare: textured.hasTexture ? textured.texturedAreaShare : 0,
            materialPreset: options.materialPreset
        )
        try ModelStore.writeMeta(ModelStore.Meta(stats: stats, material: material, name: nil, createdAt: nil, scope: snapshot.scope), to: folder)
        try? ExportNotes.readme(format: "USDZ").write(to: folder.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        progress("Done", 1)
        return ProcessedModel(folder: folder, stats: stats)
    }

    /// The keyframe looking most directly at the model's centre, for the library thumbnail.
    static func bestThumbnailKeyframe(_ keyframes: [KeyframeRecord], target: Vec3) -> KeyframeRecord? {
        keyframes.max { a, b in score(a, target) < score(b, target) }
    }

    private static func score(_ k: KeyframeRecord, _ target: Vec3) -> Double {
        let toTarget = target - k.cameraToWorld.translation
        let distance = Vec.length(toTarget)
        guard distance > 0.05 else { return -1 }
        let alignment = Vec.dot(k.cameraToWorld.cameraForward, toTarget / distance)
        return alignment - 0.05 * distance
    }
}
