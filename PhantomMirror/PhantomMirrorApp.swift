import SwiftUI

@main
struct PhantomMirrorApp: App {
    @State private var appState = AppState()
    @State private var handTracker = HandTrackingManager()
    @State private var tasks = TaskManager()
    @State private var bricks = BrickBuilderPlayground()
    @State private var handScene = HandSceneController()
    @State private var audio = AudioFeedback()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(handTracker)
                .environment(tasks)
                .environment(bricks)
                .environment(handScene)
                .environment(audio)
                .onAppear {
                    tasks.audio = audio
                }
        }
        .windowStyle(.automatic)
        .defaultSize(width: 800, height: 800)

        ImmersiveSpace(id: "PhantomMirrorSpace") {
            ImmersiveView()
                .environment(appState)
                .environment(handTracker)
                .environment(tasks)
                .environment(bricks)
                .environment(handScene)
                .environment(audio)
                .onAppear {
                    tasks.audio = audio
                }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
        // Scene-level preference so real hands composite above virtual orbs/cubes.
        .upperLimbVisibility(appState.hideRealUpperLimbs ? .hidden : .visible)
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
            case .welcome:
                WelcomeView()
            case .onboarding:
                OnboardingView()
            case .calibration:
                ZStack(alignment: .center) {
                    Color.clear
                    CalibrationPanel()
                        .padding()
                }
            case .training:
                ZStack(alignment: .center) {
                    Color.clear
                    TrainingHUD()
                        .padding()
                }
            case .playground:
                ZStack(alignment: .center) {
                    Color.clear
                    PlaygroundHUD()
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
            case .welcome, .onboarding, .calibration, .playground, .report:
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
