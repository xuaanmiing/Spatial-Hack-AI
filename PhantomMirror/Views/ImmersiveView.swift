import SwiftUI
import RealityKit
import ARKit
import simd
import QuartzCore

struct ImmersiveView: View {
    @Environment(AppState.self) private var appState
    @Environment(HandTrackingManager.self) private var handTracker
    @Environment(TaskManager.self) private var tasks
    @Environment(BrickBuilderPlayground.self) private var bricks
    @Environment(HandSceneController.self) private var scene

    var body: some View {
        RealityView { content in
            scene.attach(to: content, tasks: tasks, bricks: bricks)
            scene.setHintVisible(true)
        }
        .gesture(
            SpatialTapGesture()
                .targetedToAnyEntity()
                .onEnded { value in
                    guard appState.phase == .playground else { return }
                    bricks.handleSpatialTap(on: value.entity)
                }
        )
        // `.visible` keeps passthrough hands above virtual props.
        // `.hidden` draws all virtual content over the real hands.
        .upperLimbVisibility(appState.hideRealUpperLimbs ? .hidden : .visible)
        .task {
            await scene.loadModels()
            await bricks.loadBrickModels()
            await setupTracking()
        }
        .task(id: appState.phase) {
            // Keep a head-relative phantom visible while waiting for the intact hand.
            await presentFallbackPhantomWhileWaiting()
        }
        .onAppear {
            handTracker.intactChirality = appState.missingSide.intactIsLeft ? .left : .right
            presentFallbackPhantom()
            if appState.phase == .training {
                startTrainingTasks()
            } else if appState.phase == .playground {
                startBrickPlayground()
            }
        }
        .onChange(of: appState.phase) { _, phase in
            switch phase {
            case .training:
                bricks.deactivate()
                startTrainingTasks()
            case .playground:
                tasks.clearSceneProps()
                scene.celebration.clear()
                startBrickPlayground()
            default:
                // Leaving training/playground must drop props immediately; immersive dismiss can lag.
                tasks.clearSceneProps()
                bricks.deactivate()
                scene.celebration.clear()
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
            tasks.clearSceneProps()
            bricks.deactivate()
            handTracker.stop()
            scene.detachFromImmersiveSpace(clearing: tasks, bricks: bricks)
        }
    }

    private func refreshPreviewIfNeeded() {
        // In preview / waiting mode, re-apply offsets immediately.
        // While live tracking, tracked frames already apply calibration every update.
        if handTracker.authorizationDenied || !scene.isShowingTrackedHand {
            presentFallbackPhantom()
        }
        updateJointMarkersForCurrentPhase()
    }

    private func presentFallbackPhantom() {
        scene.showPreviewOrHide(
            showIntact: appState.showVirtualIntactHand,
            phantomIsLeft: appState.missingSide == .left,
            jointOffsets: appState.calibration.jointOffsetMap,
            phantomScale: appState.calibration.phantomScale,
            headPose: handTracker.currentHeadPose() ?? scene.lastHeadPose
        )
        updateJointMarkersForCurrentPhase()
    }

    private func presentFallbackPhantomWhileWaiting() async {
        while !Task.isCancelled {
            if appState.phase == .calibration
                || appState.phase == .training
                || appState.phase == .playground {
                if let head = handTracker.currentHeadPose() {
                    scene.rememberHeadPose(head)
                    scene.placeHintInFrontOfHead(head)
                }
                // Only fill in a preview when we are not currently drawing a tracked hand.
                if !scene.isShowingTrackedHand {
                    presentFallbackPhantom()
                }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
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
        tasks.configure(
            phantomIsLeft: appState.missingSide == .left,
            headPose: handTracker.currentHeadPose()
        )
        tasks.resetAll()
        tasks.start(.touchOrbs)
        appState.taskInstruction = TaskManager.TaskKind.touchOrbs.instruction
        appState.currentTaskIndex = 0
    }

    private func startBrickPlayground() {
        bricks.activate()
        appState.taskInstruction = bricks.instruction
    }

    private func setupTracking() async {
        handTracker.intactChirality = appState.missingSide.intactIsLeft ? .left : .right
        appState.trackingStatus = "Loading hand model… \(scene.statusDetail)"

        handTracker.onIntactHandLost = {
            appState.trackingStatus = "Intact hand lost — hold \(appState.missingSide.intactSideTitle) in view"
            appState.session.framesLost += 1
            // Keep a head-relative phantom visible so calibration never goes blank.
            scene.showPreviewOrHide(
                showIntact: appState.showVirtualIntactHand,
                phantomIsLeft: appState.missingSide == .left,
                jointOffsets: appState.calibration.jointOffsetMap,
                phantomScale: appState.calibration.phantomScale,
                headPose: handTracker.currentHeadPose() ?? scene.lastHeadPose
            )
        }

        handTracker.onIntactHandUpdate = { anchor, head in
            Self.processFrame(
                anchor: anchor,
                head: head,
                appState: appState,
                handTracker: handTracker,
                scene: scene,
                tasks: tasks,
                bricks: bricks
            )
        }

        await handTracker.start()

        if handTracker.authorizationDenied {
            let detail = handTracker.lastErrorDescription ?? "unsupported"
            appState.trackingStatus = "Preview mode — \(detail) · \(scene.statusDetail)"
            presentFallbackPhantom()
            return
        }

        if let headPose = handTracker.currentHeadPose() {
            scene.rememberHeadPose(headPose)
            scene.placeHintInFrontOfHead(headPose)
        }
        presentFallbackPhantom()
        appState.trackingStatus = "Looking for \(appState.missingSide.intactSideTitle) · \(scene.statusDetail)"
    }

    private static func processFrame(
        anchor: HandAnchor,
        head: DeviceAnchor?,
        appState: AppState,
        handTracker: HandTrackingManager,
        scene: HandSceneController,
        tasks: TaskManager,
        bricks: BrickBuilderPlayground
    ) {
        guard anchor.isTracked, let skeleton = anchor.handSkeleton else {
            scene.showPreviewOrHide(
                showIntact: appState.showVirtualIntactHand,
                phantomIsLeft: appState.missingSide == .left,
                jointOffsets: appState.calibration.jointOffsetMap,
                phantomScale: appState.calibration.phantomScale,
                headPose: handTracker.currentHeadPose() ?? scene.lastHeadPose
            )
            return
        }

        appState.session.framesTracked += 1
        appState.handUpdateIntervalMs = handTracker.averageUpdateIntervalMs
        appState.session.averageHandUpdateIntervalMs = handTracker.averageUpdateIntervalMs

        let headPose: simd_float4x4?
        if let head, head.isTracked {
            headPose = head.originFromAnchorTransform
        } else {
            headPose = handTracker.currentHeadPose() ?? scene.lastHeadPose
        }
        guard let headPose else {
            appState.trackingStatus = "Waiting for head pose to establish the body midline…"
            scene.showPreviewOrHide(
                showIntact: appState.showVirtualIntactHand,
                phantomIsLeft: appState.missingSide == .left,
                jointOffsets: appState.calibration.jointOffsetMap,
                phantomScale: appState.calibration.phantomScale,
                headPose: nil,
                showHintIfNoPose: true
            )
            return
        }

        scene.rememberHeadPose(headPose)
        scene.placeHintInFrontOfHead(headPose)
        tasks.updateReferenceHeadPose(headPose)

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

        if appState.phase == .playground {
            bricks.updateBrickInteraction(phantomWorld: scene.lastPhantomWorld)
            appState.taskInstruction = bricks.instruction
            return
        }

        guard appState.phase == .training else { return }

        tasks.updateTouchOrbs(phantomWorld: scene.lastPhantomWorld)
        tasks.updateBimanual(
            intactWorld: scene.lastIntactWorld,
            phantomWorld: scene.lastPhantomWorld
        )
        tasks.updateClapHands(
            intactWorld: scene.lastIntactWorld,
            phantomWorld: scene.lastPhantomWorld
        )
        tasks.updateSliceBlocks(phantomWorld: scene.lastPhantomWorld)

        let now = CACurrentMediaTime()
        let celebrationOrigin = scene.lastPhantomIndexTip
            ?? scene.lastPhantomWorld[.wrist]?.translation
            ?? SIMD3(0, 1.3, -0.45)
        scene.updateCelebration(trigger: tasks.celebrationTrigger, origin: celebrationOrigin, now: now)

        appState.taskInstruction = tasks.current.instruction
    }
}
