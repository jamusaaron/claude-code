import ARKit
import Foundation
import MeasureCore

/// Conditions that make LiDAR readings unreliable, surfaced honestly instead of silently
/// producing bad numbers.
enum EnvironmentWarning: String, Identifiable, CaseIterable {
    case trackingLimited
    case lowLight
    case reflectiveOrDark
    case depthEdge
    case tooFar
    case tooClose
    case noDepth
    case thermal
    case interrupted
    case memory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .trackingLimited: return "Tracking limited"
        case .lowLight: return "Low light"
        case .reflectiveOrDark: return "Unreliable surface"
        case .depthEdge: return "Edge or thin object"
        case .tooFar: return "Beyond reliable range"
        case .tooClose: return "Too close"
        case .noDepth: return "No LiDAR return"
        case .thermal: return "Device is hot"
        case .interrupted: return "Session interrupted"
        case .memory: return "Memory is low"
        }
    }

    var detail: String {
        switch self {
        case .trackingLimited: return "Move slowly over a textured area. Points placed now may drift."
        case .lowLight: return "LiDAR works in the dark, but tracking and colour capture degrade. Add light if you can."
        case .reflectiveOrDark: return "Glass, mirrors, polished metal and very dark or black surfaces scatter the laser. Readings here are unreliable."
        case .depthEdge: return "Depth is blended at edges and on thin objects (cables, chair legs). Aim at a flat face or let it snap to the edge."
        case .tooFar: return "Phone LiDAR is reliable to about 5 m. Move closer for accurate points."
        case .tooClose: return "LiDAR needs about 20 cm of distance. Move back a little."
        case .noDepth: return "Nothing measurable under the reticle (sky, open space, or an absorbing surface)."
        case .thermal: return "Performance is being reduced to cool the device; tracking may suffer."
        case .interrupted: return "The camera was interrupted. Existing points may have shifted; check them before saving."
        case .memory: return "The scan is using a lot of memory. Finish soon or it will stop automatically."
        }
    }

    var systemImage: String {
        switch self {
        case .trackingLimited: return "move.3d"
        case .lowLight: return "sun.min"
        case .reflectiveOrDark: return "sparkles"
        case .depthEdge: return "square.split.diagonal"
        case .tooFar: return "arrow.up.left.and.arrow.down.right"
        case .tooClose: return "arrow.down.right.and.arrow.up.left"
        case .noDepth: return "questionmark.circle"
        case .thermal: return "thermometer.high"
        case .interrupted: return "pause.circle"
        case .memory: return "memorychip"
        }
    }

    /// Lower number = more important (shown first).
    var priority: Int {
        switch self {
        case .interrupted: return 0
        case .trackingLimited: return 1
        case .memory: return 2
        case .noDepth: return 3
        case .reflectiveOrDark: return 4
        case .tooFar: return 5
        case .tooClose: return 6
        case .depthEdge: return 7
        case .lowLight: return 8
        case .thermal: return 9
        }
    }
}

/// Evaluates warnings a few times per second with hysteresis, so banners don't flicker when a
/// condition hovers at its threshold.
@MainActor
final class EnvironmentMonitor {
    private var onSince: [EnvironmentWarning: TimeInterval] = [:]
    private var offSince: [EnvironmentWarning: TimeInterval] = [:]
    private(set) var active: Set<EnvironmentWarning> = []
    /// Sticky flags set by the controller (interruption, memory pressure).
    var externalFlags: Set<EnvironmentWarning> = []

    private let showDelay: TimeInterval = 0.6
    private let hideDelay: TimeInterval = 1.2

    func reset() {
        onSince.removeAll()
        offSince.removeAll()
        active.removeAll()
        externalFlags.removeAll()
    }

    /// Returns warnings sorted by priority.
    func evaluate(frame: ARFrame, centre: DepthSample?, stats: DepthRegionStats?) -> [EnvironmentWarning] {
        var raw = Set<EnvironmentWarning>()

        if case .limited = frame.camera.trackingState { raw.insert(.trackingLimited) }
        if case .notAvailable = frame.camera.trackingState { raw.insert(.trackingLimited) }

        // ARKit's ambient estimate is ~1000 lm in a well-lit room; below ~150 tracking suffers.
        if let light = frame.lightEstimate, light.ambientIntensity < 150 { raw.insert(.lowLight) }

        if let stats {
            if stats.invalidFraction > 0.6 { raw.insert(.noDepth) }
            // Many low-confidence returns in the centre: specular, transparent or absorbing surface.
            else if stats.lowConfidenceFraction > 0.45 { raw.insert(.reflectiveOrDark) }
        }

        if let centre {
            if centre.depth > Float(AccuracyModel.reliableRange) { raw.insert(.tooFar) }
            if centre.depth < 0.2 { raw.insert(.tooClose) }
            if centre.isDiscontinuity { raw.insert(.depthEdge) }
            if centre.confidence == .low && !raw.contains(.noDepth) { raw.insert(.reflectiveOrDark) }
        } else if stats != nil, !raw.contains(.noDepth) {
            raw.insert(.noDepth)
        }

        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .serious || thermal == .critical { raw.insert(.thermal) }

        let now = frame.timestamp
        for w in EnvironmentWarning.allCases {
            if raw.contains(w) {
                offSince[w] = nil
                let start = onSince[w] ?? now
                onSince[w] = start
                if now - start >= showDelay { active.insert(w) }
            } else {
                onSince[w] = nil
                let start = offSince[w] ?? now
                offSince[w] = start
                if now - start >= hideDelay { active.remove(w) }
            }
        }
        return active.union(externalFlags).sorted { $0.priority < $1.priority }
    }
}
