import SwiftUI
import RealityKit
import ARKit
import simd

struct ImmersiveView: View {
    @Environment(AppState.self) private var appState
    @Environment(HandTrackingManager.self) private var handTracker
    @Environment(TaskManager.self) private var tasks
    @Environment(HandSceneController.self) private var scene

    var body: some View {
        RealityView { content in
            scene.attach(to: content, tasks: tasks)
            scene.setHintVisible(true)
        }
        .upperLimbVisibility(appState.hideRealUpperLimbs ? .hidden : .automatic)
        .task {
            await scene.loadModels()
            await setupTracking()
        }
        .onAppear {
            handTracker.intactChirality = appState.missingSide.intactIsLeft ? .left : .right
            if appState.phase == .training {
                startTrainingTasks()
            }
        }
        .onChange(of: appState.phase) { _, phase in
            if phase == .training {
                startTrainingTasks()
            }
        }
        .onChange(of: appState.missingSide) { _, _ in
            handTracker.intactChirality = appState.missingSide.intactIsLeft ? .left : .right
        }
        .onDisappear {
            handTracker.stop()
        }
    }

    private func startTrainingTasks() {
        tasks.configure(phantomIsLeft: appState.missingSide == .left)
        tasks.resetAll()
        tasks.start(.openClose)
        appState.taskInstruction = TaskManager.TaskKind.openClose.instruction
        appState.currentTaskIndex = 0
    }

    private func setupTracking() async {
        handTracker.intactChirality = appState.missingSide.intactIsLeft ? .left : .right
        appState.trackingStatus = "Loading hand model… \(scene.statusDetail)"

        handTracker.onIntactHandLost = {
            appState.trackingStatus = "Intact hand lost — hold \(appState.missingSide.intactSideTitle) in view"
            appState.session.framesLost += 1
            // Keep last pose visible briefly? Safer: show hint so user knows to re-present hand.
            scene.hideHands(showHint: true)
        }

        handTracker.onIntactHandUpdate = { anchor, head in
            Self.processFrame(
                anchor: anchor,
                head: head,
                appState: appState,
                handTracker: handTracker,
                scene: scene,
                tasks: tasks
            )
        }

        await handTracker.start()

        if handTracker.authorizationDenied {
            let detail = handTracker.lastErrorDescription ?? "unsupported"
            appState.trackingStatus = "Preview mode — \(detail) · \(scene.statusDetail)"
            scene.showPreview(showIntact: appState.showVirtualIntactHand)
            return
        }

        appState.trackingStatus = "Looking for \(appState.missingSide.intactSideTitle) · \(scene.statusDetail)"
    }

    private static func processFrame(
        anchor: HandAnchor,
        head: DeviceAnchor?,
        appState: AppState,
        handTracker: HandTrackingManager,
        scene: HandSceneController,
        tasks: TaskManager
    ) {
        guard anchor.isTracked, let skeleton = anchor.handSkeleton else {
            scene.hideHands(showHint: true)
            return
        }

        appState.session.framesTracked += 1
        appState.handUpdateIntervalMs = handTracker.averageUpdateIntervalMs
        appState.session.averageHandUpdateIntervalMs = handTracker.averageUpdateIntervalMs

        let headPose: simd_float4x4?
        if let head, head.isTracked {
            headPose = head.originFromAnchorTransform
        } else {
            headPose = handTracker.currentHeadPose()
        }
        guard let headPose else {
            appState.trackingStatus = "Waiting for head pose to establish the body midline…"
            scene.hideHands(showHint: true)
            return
        }

        let intactIsLeft = appState.missingSide.intactIsLeft

        scene.applyTrackedHand(
            skeleton: skeleton,
            wristWorld: anchor.originFromAnchorTransform,
            headPose: headPose,
            calibration: appState.calibration,
            intactIsLeft: intactIsLeft,
            showIntact: appState.showVirtualIntactHand
        )

        let mode = scene.usingFallback ? "procedural" : "USDZ"
        appState.trackingStatus =
            "Tracking \(intactIsLeft ? "left→right" : "right→left") · \(mode) · joints \(scene.jointCountLastFrame)"

        guard appState.phase == .training else { return }

        tasks.updateOpenClose(openness: scene.lastPhantomOpenness)
        tasks.updateTouchOrbs(phantomIndexTip: scene.lastPhantomIndexTip)
        tasks.updateBimanual(
            intactTip: scene.lastIntactIndexTip,
            phantomTip: scene.lastPhantomIndexTip
        )
        appState.taskInstruction = tasks.current.instruction
    }
}
