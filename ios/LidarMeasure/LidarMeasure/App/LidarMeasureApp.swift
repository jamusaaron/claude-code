import SwiftUI
import SwiftData

@main
struct LidarMeasureApp: App {
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .modelContainer(for: [SavedMeasurement.self, SavedModel.self])
    }
}
