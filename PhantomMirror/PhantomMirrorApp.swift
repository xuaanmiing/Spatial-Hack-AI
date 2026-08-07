import SwiftUI

@main
struct PhantomMirrorApp: App {
    @State private var appState = AppState()
    @State private var handTracker = HandTrackingManager()
    @State private var tasks = TaskManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(handTracker)
                .environment(tasks)
        }
        .windowStyle(.automatic)
        .defaultSize(width: 520, height: 720)

        ImmersiveSpace(id: "PhantomMirrorSpace") {
            ImmersiveView()
                .environment(appState)
                .environment(handTracker)
                .environment(tasks)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}

struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        Group {
            switch appState.phase {
            case .onboarding:
                OnboardingView()
            case .calibration:
                ZStack(alignment: .bottom) {
                    Color.clear
                    CalibrationPanel()
                        .padding()
                }
            case .training:
                ZStack(alignment: .bottomTrailing) {
                    Color.clear
                    TrainingHUD()
                        .padding()
                }
            case .report:
                ReportView()
            }
        }
        .onChange(of: appState.immersiveOpen) { _, open in
            Task {
                if open {
                    let result = await openImmersiveSpace(id: "PhantomMirrorSpace")
                    if case .error = result {
                        appState.trackingStatus = "Failed to open Immersive Space"
                        appState.immersiveOpen = false
                    }
                } else {
                    await dismissImmersiveSpace()
                }
            }
        }
    }
}
