import SwiftUI
import MeasureCore

/// First-run introduction: what the app does, the LiDAR requirement, honest accuracy limits,
/// and camera permission.
struct OnboardingView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var camera: CameraPermission
    @State private var page = 0

    private let lastPage = 3

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                welcome.tag(0)
                requirements.tag(1)
                accuracy.tag(2)
                permission.tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button {
                if page < lastPage {
                    withAnimation { page += 1 }
                } else {
                    finish()
                }
            } label: {
                Text(page < lastPage ? "Continue" : "Get started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .foregroundStyle(.black)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .background(Color.black.ignoresSafeArea())
    }

    private func finish() {
        Task {
            await camera.request()
            settings.hasCompletedOnboarding = true
        }
    }

    // MARK: Pages

    private var welcome: some View {
        pageLayout(icon: "ruler", title: "Measure with LiDAR") {
            bullet("ruler", "Distances, areas and volumes in mm, cm and m, updating live.")
            bullet("cube.transparent", "Scan rooms and objects into textured 3D models.")
            bullet("square.and.arrow.up", "Export measurements as CSV and models as USDZ, OBJ or glTF.")
            bullet("lock.shield", "Everything is processed and stored on this device.")
        }
    }

    private var requirements: some View {
        pageLayout(icon: "dot.radiowaves.left.and.right", title: "LiDAR required") {
            Text("This app needs the LiDAR Scanner found on iPhone 12 Pro and later Pro models, and iPad Pro (2020 and later).")
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Image(systemName: DeviceCapabilities.hasLiDAR ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(DeviceCapabilities.hasLiDAR ? Theme.good : Theme.poor)
                    .font(.title2)
                Text(DeviceCapabilities.hasLiDAR ? "LiDAR detected on this device." : "No LiDAR on this device. You can still browse saved items, but measuring and scanning are unavailable.")
                    .font(.subheadline)
            }
            .padding()
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var accuracy: some View {
        pageLayout(icon: "plusminus.circle", title: "Honest accuracy") {
            bullet("checkmark.circle", "Typically about ±1 cm at 0.3–2 m on matte, well-lit surfaces.")
            bullet("exclamationmark.triangle", "Worse on glass, mirrors, black or shiny surfaces, thin objects, beyond ~5 m and in poor tracking.")
            bullet("gauge.with.needle", "Every value shows its estimated uncertainty and a confidence colour.")
            bullet("ruler", "Not survey-grade. Confirm critical dimensions with a tape or laser measure.")
        }
    }

    private var permission: some View {
        pageLayout(icon: "camera.viewfinder", title: "Camera access") {
            Text("LiDAR measurement runs through the camera. Video stays on the device and is never recorded or uploaded; only keyframes you capture for 3D textures are stored with the model.")
                .multilineTextAlignment(.center)
            switch camera.state {
            case .authorized:
                Label("Camera access granted", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.good)
            case .denied, .restricted:
                VStack(spacing: 8) {
                    Label("Camera access is off", systemImage: "xmark.octagon.fill").foregroundStyle(Theme.poor)
                    Button("Open Settings") { SystemSettings.open() }
                }
            case .notDetermined:
                Text("You'll be asked to allow access next.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func pageLayout<Content: View>(icon: String, title: String, @ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: icon)
                    .font(.system(size: 64, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 48)
                Text(title)
                    .font(.largeTitle.weight(.bold))
                    .multilineTextAlignment(.center)
                VStack(alignment: .leading, spacing: 16) { content() }
                    .padding(.horizontal, 28)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 60)
        }
        .foregroundStyle(.white)
    }

    private func bullet(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 28)
            Text(text).font(.body)
        }
    }
}
