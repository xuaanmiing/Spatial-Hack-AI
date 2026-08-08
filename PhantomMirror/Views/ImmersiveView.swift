import SwiftUI
import RealityKit
import ARKit
import simd
import QuartzCore

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
            refreshPreviewIfNeeded()
        }
        .onChange(of: appState.calibration) { _, _ in
            refreshPreviewIfNeeded()
        }
        .onChange(of: appState.showVirtualIntactHand) { _, _ in
            refreshPreviewIfNeeded()
        }
        .onChange(of: appState.selectedJoint) { _, _ in
            // Keep the in-scene highlight in sync even when live tracking hasn't
            // produced a new frame yet (fast successive taps in the panel).
            updateJointMarkersForCurrentPhase()
        }
        .onChange(of: appState.phase) { _, _ in
            updateJointMarkersForCurrentPhase()
        }
        .onDisappear {
            handTracker.stop()
            scene.detachFromImmersiveSpace()
        }
    }

    private func refreshPreviewIfNeeded() {
        // Live tracking already reapplies offsets every frame; only refresh static preview.
        guard handTracker.authorizationDenied else { return }
        scene.showPreview(
            showIntact: appState.showVirtualIntactHand,
            phantomIsLeft: appState.missingSide == .left,
            jointOffsets: appState.calibration.jointOffsetMap,
            phantomScale: appState.calibration.phantomScale
        )
        updateJointMarkersForCurrentPhase()
    }

    /// Show / hide the debug joint spheres based on the current app phase, using
    /// the last known phantom-hand world transforms.
    private func updateJointMarkersForCurrentPhase() {
        guard appState.phase == .calibration || appState.phase == .training else {
            scene.jointMarkers.setVisible(false)
            return
        }
        scene.jointMarkers.setVisible(true)
        let tuned: Set<HandSkeleton.JointName> = Set(
            CalibrationData.adjustableJoints.filter {
                simd_length_squared(appState.calibration.offset(for: $0)) > 1e-12
            }
        )
        scene.jointMarkers.update(
            worldTransforms: scene.lastPhantomWorld,
            selectedJoint: appState.selectedJoint,
            tunedJoints: tuned,
            time: CACurrentMediaTime()
        )
    }

    private func startTrainingTasks() {
        tasks.configure(phantomIsLeft: appState.missingSide == .left)
        tasks.resetAll()
        tasks.start(.touchOrbs)
        appState.taskInstruction = TaskManager.TaskKind.touchOrbs.instruction
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
            scene.showPreview(
                showIntact: appState.showVirtualIntactHand,
                phantomIsLeft: appState.missingSide == .left,
                jointOffsets: appState.calibration.jointOffsetMap,
                phantomScale: appState.calibration.phantomScale
            )
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

        // The calibrated marker positions are the visual source of truth; keep them
        // visible during both calibration and training.
        if appState.phase == .calibration || appState.phase == .training {
            scene.jointMarkers.setVisible(true)
            let tuned: Set<HandSkeleton.JointName> = Set(
                CalibrationData.adjustableJoints.filter {
                    simd_length_squared(appState.calibration.offset(for: $0)) > 1e-12
                }
            )
            scene.jointMarkers.update(
                worldTransforms: scene.lastPhantomWorld,
                selectedJoint: appState.selectedJoint,
                tunedJoints: tuned,
                time: CACurrentMediaTime()
            )
        } else {
            scene.jointMarkers.setVisible(false)
        }

        let mode = "calibrated skeleton"
        appState.trackingStatus =
            "Tracking \(intactIsLeft ? "left→right" : "right→left") · \(mode) · joints \(scene.jointCountLastFrame)"

        guard appState.phase == .training else { return }

        tasks.updateTouchOrbs(phantomWorld: scene.lastPhantomWorld)
        tasks.updateBimanual(
            intactTip: scene.lastIntactIndexTip,
            phantomTip: scene.lastPhantomIndexTip
        )
        tasks.updateClapHands(
            intactWorld: scene.lastIntactWorld,
            phantomWorld: scene.lastPhantomWorld
        )
        appState.taskInstruction = tasks.current.instruction
    }
}
