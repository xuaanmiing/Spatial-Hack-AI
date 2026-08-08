import SwiftUI

@main
struct PhantomMirrorApp: App {
    @State private var appState = AppState()
    @State private var handTracker = HandTrackingManager()
    @State private var tasks = TaskManager()
    @State private var handScene = HandSceneController()
    @State private var audio = AudioFeedback()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(handTracker)
                .environment(tasks)
                .environment(handScene)
                .environment(audio)
                .onAppear {
                    audio.prepare()
                    tasks.audio = audio
                }
        }
        .windowStyle(.automatic)
        .defaultSize(width: 520, height: 720)

        ImmersiveSpace(id: "PhantomMirrorSpace") {
            ImmersiveView()
                .environment(appState)
                .environment(handTracker)
                .environment(tasks)
                .environment(handScene)
                .environment(audio)
                .onAppear {
                    audio.prepare()
                    tasks.audio = audio
                }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}

struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(AudioFeedback.self) private var audio
    @Environment(TaskManager.self) private var tasks
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
        .onAppear {
            tasks.audio = audio
        }
        .onChange(of: appState.phase) { _, phase in
            switch phase {
            case .training:
                audio.startAmbient()
            case .onboarding, .calibration, .report:
                audio.stopAmbient()
            }
        }
        .onChange(of: appState.immersiveOpen) { _, open in
            Task {
                if open {
                    switch await openImmersiveSpace(id: "PhantomMirrorSpace") {
                    case .opened:
                        appState.trackingStatus = "Immersive space opened — hold intact hand in view"
                    case .userCancelled:
                        appState.trackingStatus = "Immersive space cancelled"
                        appState.immersiveOpen = false
                    case .error:
                        appState.trackingStatus = "Failed to open Immersive Space"
                        appState.immersiveOpen = false
                    @unknown default:
                        appState.trackingStatus = "Unknown Immersive Space result"
                        appState.immersiveOpen = false
                    }
                } else {
                    await dismissImmersiveSpace()
                }
            }
        }
    }
}
