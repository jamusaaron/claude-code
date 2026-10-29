import SwiftUI
import SwiftData

@main
struct LidarMeasureApp: App {
    @StateObject private var settings = AppSettings()
    /// Created once: owns the single AR session shared by Measure and Scan.
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .modelContainer(for: [SavedMeasurement.self, SavedModel.self])
    }
}
