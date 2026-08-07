import SwiftUI
import RealityKit
import ARKit
import simd
import QuartzCore
import UIKit

struct ImmersiveView: View {
    @Environment(AppState.self) private var appState
    @Environment(HandTrackingManager.self) private var handTracker
    @Environment(TaskManager.self) private var tasks

    @State private var intactHand: VirtualHandVisualizer?
    @State private var phantomHand: VirtualHandVisualizer?
    @State private var rootEntity = Entity()
    @State private var lastUpdateTime: CFTimeInterval = 0
    @State private var latencySamples: [Double] = []

    var body: some View {
        RealityView { content in
            content.add(rootEntity)

            let intactColor: UIColor = .systemCyan
            let phantomColor: UIColor = UIColor(red: 1.0, green: 0.72, blue: 0.55, alpha: 1.0)

            let intact = VirtualHandVisualizer(name: "intactHand", color: intactColor)
            let phantom = VirtualHandVisualizer(name: "phantomHand", color: phantomColor)
            rootEntity.addChild(intact.root)
            rootEntity.addChild(phantom.root)
            rootEntity.addChild(tasks.orbRoot)
            rootEntity.addChild(tasks.cubeRoot)

            intactHand = intact
            phantomHand = phantom

            intact.setVisible(appState.showVirtualIntactHand)
        } update: { _ in
            intactHand?.setVisible(appState.showVirtualIntactHand)
        }
        .upperLimbVisibility(appState.hideRealUpperLimbs ? .hidden : .automatic)
        .task {
            await setupTracking()
        }
        .onAppear {
            if appState.phase == .training {
                tasks.resetAll()
                tasks.start(.openClose)
                appState.taskInstruction = TaskManager.TaskKind.openClose.instruction
                appState.currentTaskIndex = 0
            }
        }
        .onDisappear {
            handTracker.onIntactHandUpdate = nil
            handTracker.onTrackingLost = nil
            handTracker.stop()
        }
    }

    private func setupTracking() async {
        await handTracker.start()

        if handTracker.authorizationDenied {
            appState.trackingStatus = "Hand tracking unavailable (need Vision Pro + permission)"
            return
        }

        handTracker.onTrackingLost = { [appState] in
            appState.trackingStatus = "Hand lost — keep intact hand in view"
            appState.session.framesLost += 1
            phantomHand?.setVisible(false)
        }

        handTracker.onIntactHandUpdate = { [appState, handTracker] anchor, head in
            handleIntactUpdate(anchor: anchor, head: head, tracker: handTracker)
        }
    }

    private func handleIntactUpdate(
        anchor: HandAnchor,
        head: DeviceAnchor?,
        tracker: HandTrackingManager
    ) {
        let now = CACurrentMediaTime()
        if lastUpdateTime > 0 {
            let ms = (now - lastUpdateTime) * 1000
            latencySamples.append(ms)
            if latencySamples.count > 60 { latencySamples.removeFirst() }
            appState.syncLatencyMs = latencySamples.reduce(0, +) / Double(latencySamples.count)
            appState.session.averageLatencyMs = appState.syncLatencyMs
        }
        lastUpdateTime = now

        let intactIsLeft = appState.missingSide.intactIsLeft
        let expected: HandAnchor.Chirality = intactIsLeft ? .left : .right
        guard anchor.chirality == expected else { return }
        guard anchor.isTracked, let skeleton = anchor.handSkeleton else {
            appState.trackingStatus = "Hand lost — keep intact hand in view"
            appState.session.framesLost += 1
            return
        }

        appState.session.framesTracked += 1
        appState.trackingStatus = "Tracking \(intactIsLeft ? "left" : "right") hand · \(Int(appState.syncLatencyMs)) ms"

        let headPose = head?.isTracked == true
            ? head!.originFromAnchorTransform
            : tracker.currentHeadPose()

        let wristWorld = anchor.originFromAnchorTransform

        // Intact hand: 1:1 world joints
        var intactWorld: [HandSkeleton.JointName: simd_float4x4] = [:]
        for jointName in HandSkeleton.JointName.allCases {
            let joint = skeleton.joint(jointName)
            guard joint.isTracked else { continue }
            intactWorld[jointName] = MirrorTransform.worldJoint(
                wristWorld: wristWorld,
                jointLocal: joint.anchorFromJointTransform
            )
        }
        intactHand?.update(worldTransforms: intactWorld, scale: 1.0)
        intactHand?.setVisible(appState.showVirtualIntactHand)

        // Phantom: mirror each joint across head sagittal plane, then calibration.
        var phantomWorld: [HandSkeleton.JointName: simd_float4x4] = [:]
        for (name, worldT) in intactWorld {
            let mirrored = MirrorTransform.mirror(worldT, headPose: headPose)
            phantomWorld[name] = MirrorTransform.applyCalibration(
                mirrored,
                calibration: appState.calibration,
                headPose: headPose
            )
        }
        phantomHand?.setVisible(true)
        phantomHand?.update(
            worldTransforms: phantomWorld,
            scale: appState.calibration.phantomScale
        )

        // Training task updates
        guard appState.phase == .training else { return }

        let openness = phantomHand?.gripOpenness(from: phantomWorld)
        tasks.updateOpenClose(openness: openness)
        tasks.updateTouchOrbs(phantomIndexTip: phantomWorld[.indexFingerTip]?.translation)
        tasks.updateBimanual(
            intactTip: intactWorld[.indexFingerTip]?.translation,
            phantomTip: phantomWorld[.indexFingerTip]?.translation
        )

        appState.taskInstruction = tasks.current.instruction
        if tasks.isComplete {
            // auto-advance handled by HUD button; surface progress
        }
    }
}
