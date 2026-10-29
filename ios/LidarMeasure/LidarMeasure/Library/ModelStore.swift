import Foundation
import SwiftData
import MeasureCore

/// File layout for captured models. Each model is a folder:
///
///     mesh.bin       processed geometry (MeshArchive), source for every export
///     texture.jpg    composited texture atlas (absent for untextured models)
///     model.usdz     primary export, opened by the viewer and AR Quick Look
///     thumbnail.jpg  library thumbnail
///     meta.json      ModelStats + material
///     exports/       OBJ zip and GLB, generated on first request
///
/// Everything stays on the device; nothing is uploaded.
enum ModelStore {
    static let meshFile = "mesh.bin"
    static let textureFile = "texture.jpg"
    static let usdzFile = "model.usdz"
    static let thumbnailFile = "thumbnail.jpg"
    static let metaFile = "meta.json"

    /// `meta.json`: everything needed to rebuild the library record from the folder alone,
    /// so a model survives the app being killed between writing files and saving the record.
    struct Meta: Codable {
        var stats: ModelStats
        var material: MaterialSpec
        var name: String?
        var createdAt: Date?
        var scope: CaptureScope?
    }

    enum StoreError: LocalizedError {
        case missingMesh
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingMesh: return "The model's geometry file is missing."
            case .exportFailed(let reason): return "Export failed: \(reason)"
            }
        }
    }

    static var rootDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var temporaryRoot: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LidarMeasure", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func folder(named name: String) -> URL {
        rootDirectory.appendingPathComponent(name, isDirectory: true)
    }

    static func makeTemporaryFolder(prefix: String) throws -> URL {
        let url = temporaryRoot.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Moves a processed temp folder into the library and returns the folder name.
    static func adopt(temporaryFolder: URL, id: UUID) throws -> String {
        let name = id.uuidString
        let destination = folder(named: name)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryFolder, to: destination)
        return name
    }

    static func delete(folderName: String) {
        try? FileManager.default.removeItem(at: folder(named: folderName))
    }

    static func readMeta(_ folder: URL) -> Meta? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(metaFile)) else { return nil }
        return try? JSONDecoder().decode(Meta.self, from: data)
    }

    static func writeMeta(_ meta: Meta, to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(meta).write(to: folder.appendingPathComponent(metaFile), options: .atomic)
    }

    /// Records the final name and date in `meta.json` once a model is saved.
    static func finalise(folder: URL, name: String, createdAt: Date, scope: CaptureScope) {
        guard var meta = readMeta(folder) else { return }
        meta.name = name
        meta.createdAt = createdAt
        meta.scope = scope
        try? writeMeta(meta, to: folder)
    }

    // MARK: Recovery

    struct ReconcileResult {
        var recovered = 0
        var missing: [SavedModel] = []
    }

    /// Re-registers model folders that have no library record (e.g. the app was killed right
    /// after the files were committed) and reports records whose files are gone.
    @MainActor
    static func reconcile(known: [SavedModel], context: ModelContext) -> ReconcileResult {
        var result = ReconcileResult()
        let fm = FileManager.default
        let knownFolders = Set(known.map(\.folderName))
        let folders = (try? fm.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey], options: [.skipsHiddenFiles])) ?? []
        for folder in folders where !knownFolders.contains(folder.lastPathComponent) {
            guard fm.fileExists(atPath: folder.appendingPathComponent(usdzFile).path),
                  let meta = readMeta(folder) else { continue }
            let created = meta.createdAt ?? (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            let record = SavedModel(
                id: UUID(uuidString: folder.lastPathComponent) ?? UUID(),
                name: meta.name ?? "Recovered scan",
                createdAt: created,
                folderName: folder.lastPathComponent,
                stats: meta.stats,
                scope: meta.scope ?? .scene
            )
            context.insert(record)
            result.recovered += 1
        }
        if result.recovered > 0 { try? context.save() }
        result.missing = known.filter { !fm.fileExists(atPath: $0.folderURL.appendingPathComponent(usdzFile).path) }
        return result
    }

    // MARK: Exports

    enum ExportFormat: String, CaseIterable, Identifiable {
        case usdz, objZip, glb

        var id: String { rawValue }

        var title: String {
            switch self {
            case .usdz: return "USDZ (AR Quick Look)"
            case .objZip: return "OBJ + MTL + texture (zip)"
            case .glb: return "glTF binary (.glb)"
            }
        }

        var fileExtension: String {
            switch self {
            case .usdz: return "usdz"
            case .objZip: return "zip"
            case .glb: return "glb"
            }
        }
    }

    /// Produces a share-ready file named after the model. Runs off the main thread for big meshes.
    static func export(folder: URL, format: ExportFormat, displayName: String) throws -> URL {
        let safeName = sanitizedFileName(displayName)
        let shareDir = temporaryRoot.appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: shareDir, withIntermediateDirectories: true)
        let destination = shareDir.appendingPathComponent("\(safeName).\(format.fileExtension)")

        if format == .usdz {
            try FileManager.default.copyItem(at: folder.appendingPathComponent(usdzFile), to: destination)
            return destination
        }

        let meshURL = folder.appendingPathComponent(meshFile)
        guard let meshData = try? Data(contentsOf: meshURL) else { throw StoreError.missingMesh }
        let mesh = try MeshArchive.decode(meshData)
        let texture = try? Data(contentsOf: folder.appendingPathComponent(textureFile))
        let material = readMeta(folder)?.material ?? MaterialSpec()

        let data: Data
        switch format {
        case .objZip:
            data = try OBJExporter.makeZip(mesh: mesh, material: material, textureJPEG: texture, baseName: safeName)
        case .glb:
            data = try GLBExporter.makeGLB(mesh: mesh, material: material, textureJPEG: texture)
        case .usdz:
            data = Data()
        }
        try data.write(to: destination, options: .atomic)
        return destination
    }

    static func sanitizedFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Scan" : String(cleaned.prefix(80))
    }

    // MARK: Housekeeping

    static func diskUsage() -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: rootDirectory, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    static func clearTemporaryFiles() {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    static func deleteEverything() {
        try? FileManager.default.removeItem(at: rootDirectory)
        clearTemporaryFiles()
    }
}
