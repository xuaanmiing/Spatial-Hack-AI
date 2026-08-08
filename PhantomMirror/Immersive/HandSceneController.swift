import Foundation
import RealityKit
import SwiftUI
import ARKit
import simd
import UIKit

/// Scene owner: calibrated procedural phantom hand + optional intact visual + task props.
/// Never relies on SwiftUI View state for entity references.
@MainActor
@Observable
final class HandSceneController {
    let root = Entity()

    /// Model roots are kept only so existing project references stay harmless.
    /// The visible phantom hand is the calibrated procedural skeleton below.
    let phantomUSDZ = ARKitHandModel(name: "phantomUSDZ")
    let intactUSDZ = ARKitHandModel(
        name: "intactUSDZ",
        tint: UIColor(red: 0.62, green: 0.78, blue: 0.88, alpha: 1.0)
    )

    private let fallbackIntact: VirtualHandVisualizer
    private let fallbackPhantom: VirtualHandVisualizer

    /// Debug markers drawn on every phantom joint so the user can see which bone
    /// their calibration UI is currently editing. Hidden during training.
    let jointMarkers = JointMarkerOverlay()

    private var hintEntity: ModelEntity?
    private(set) var isBuilt = false
    private(set) var modelsReady = false
    private(set) var statusDetail: String = "Models not loaded"
    private(set) var jointCountLastFrame: Int = 0
    private(set) var usingFallback: Bool = false
    private var mirrorReferenceHeadPose: simd_float4x4?

    /// Most recent hand world transforms — reused by overlays and training tasks.
    private(set) var lastIntactWorld: [HandSkeleton.JointName: simd_float4x4] = [:]
    private(set) var lastPhantomWorld: [HandSkeleton.JointName: simd_float4x4] = [:]

    /// Tip positions for training tasks (world space).
    private(set) var lastIntactIndexTip: SIMD3<Float>?
    private(set) var lastPhantomIndexTip: SIMD3<Float>?
    private(set) var lastPhantomOpenness: Float?

    init() {
        fallbackIntact = VirtualHandVisualizer(name: "fallbackIntact", color: .systemCyan)
        fallbackPhantom = VirtualHandVisualizer(
            name: "fallbackPhantom",
            color: UIColor(red: 0.35, green: 0.75, blue: 1.0, alpha: 1.0)
        )
    }

    func attach(to content: RealityViewContent, tasks: TaskManager) {
        if isBuilt {
            if root.parent == nil { content.add(root) }
            return
        }

        root.name = "handSceneRoot"
        content.add(root)
        root.addChild(phantomUSDZ.root)
        root.addChild(intactUSDZ.root)
        root.addChild(fallbackIntact.root)
        root.addChild(fallbackPhantom.root)
        root.addChild(jointMarkers.root)
        root.addChild(tasks.orbRoot)
        root.addChild(tasks.cubeRoot)

        let hint = ModelEntity(
            mesh: .generateSphere(radius: 0.04),
            materials: [UnlitMaterial(color: .systemYellow)]
        )
        hint.name = "trackingHint"
        hint.position = SIMD3(0, 1.3, -0.55)
        root.addChild(hint)
        hintEntity = hint

        fallbackIntact.setVisible(false)
        fallbackPhantom.setVisible(false)
        phantomUSDZ.setVisible(false)
        intactUSDZ.setVisible(false)
        isBuilt = true
    }

    func loadModels() async {
        phantomUSDZ.setVisible(false)
        intactUSDZ.setVisible(false)
        usingFallback = true
        modelsReady = true
        statusDetail = "Blue calibrated skeleton"
    }

    func setHintVisible(_ visible: Bool) {
        hintEntity?.isEnabled = visible
    }

    func detachFromImmersiveSpace() {
        mirrorReferenceHeadPose = nil
        root.removeFromParent()
    }

    /// Drive visuals from an intact-hand ARKit skeleton.
    func applyTrackedHand(
        skeleton: HandSkeleton,
        wristWorld: simd_float4x4,
        headPose: simd_float4x4,
        calibration: CalibrationData,
        intactIsLeft: Bool,
        showIntact: Bool
    ) {
        // World joint map for tips / openness / fallback.
        var intactWorld: [HandSkeleton.JointName: simd_float4x4] = [:]
        for name in HandSkeleton.JointName.allCases {
            let joint = skeleton.joint(name)
            guard joint.isTracked else { continue }
            intactWorld[name] = wristWorld * joint.anchorFromJointTransform
        }

        if mirrorReferenceHeadPose == nil {
            mirrorReferenceHeadPose = headPose
        }
        let referenceHeadPose = mirrorReferenceHeadPose ?? headPose

        var phantomWorld: [HandSkeleton.JointName: simd_float4x4] = [:]
        for (name, worldT) in intactWorld {
            let mirrored = MirrorTransform.mirror(worldT, headPose: referenceHeadPose)
            phantomWorld[name] = MirrorTransform.applyCalibration(
                mirrored,
                calibration: calibration,
                headPose: referenceHeadPose
            )
        }
        phantomWorld = Self.applyJointOffsets(calibration.jointOffsetMap, to: phantomWorld)

        lastIntactWorld = intactWorld
        lastIntactIndexTip = intactWorld[.indexFingerTip]?.translation
        lastPhantomIndexTip = phantomWorld[.indexFingerTip]?.translation
        lastPhantomOpenness = fallbackPhantom.gripOpenness(from: phantomWorld)
        lastPhantomWorld = phantomWorld
        jointCountLastFrame = intactWorld.count
        setHintVisible(false)

        phantomUSDZ.setVisible(false)
        intactUSDZ.setVisible(false)

        fallbackPhantom.setVisible(true)
        fallbackPhantom.update(worldTransforms: phantomWorld, scale: calibration.phantomScale)

        fallbackIntact.setVisible(showIntact)
        if showIntact {
            fallbackIntact.update(worldTransforms: intactWorld)
        }
    }


    func hideHands(showHint: Bool = true) {
        phantomUSDZ.setVisible(false)
        intactUSDZ.setVisible(false)
        fallbackIntact.setVisible(false)
        fallbackPhantom.setVisible(false)
        jointMarkers.hideAll()
        setHintVisible(showHint)
        jointCountLastFrame = 0
        lastIntactWorld = [:]
        lastIntactIndexTip = nil
        lastPhantomIndexTip = nil
        lastPhantomOpenness = nil
        lastPhantomWorld = [:]
    }

    /// Simulator / no-tracking: show the procedural skeleton in front of user.
    /// - Parameter phantomIsLeft: `true` when the missing (phantom) side is the left hand.
    func showPreview(
        showIntact: Bool,
        phantomIsLeft: Bool,
        jointOffsets: [HandSkeleton.JointName: SIMD3<Float>] = [:],
        phantomScale: Float = 1
    ) {
        setHintVisible(false)
        let leftWristPos = SIMD3<Float>(-0.18, 1.25, -0.45)
        let rightWristPos = SIMD3<Float>(0.18, 1.25, -0.45)
        let phantomPos = phantomIsLeft ? leftWristPos : rightWristPos
        let intactPos = phantomIsLeft ? rightWristPos : leftWristPos
        let phantomPose = Self.applyJointOffsets(
            jointOffsets,
            to: Self.makePreviewHandPose(wrist: phantomPos, isLeft: phantomIsLeft)
        )
        let intactPose = Self.makePreviewHandPose(wrist: intactPos, isLeft: !phantomIsLeft)
        phantomUSDZ.setVisible(false)
        intactUSDZ.setVisible(false)
        fallbackIntact.setVisible(showIntact)
        if showIntact { fallbackIntact.update(worldTransforms: intactPose) }
        fallbackPhantom.setVisible(true)
        fallbackPhantom.update(worldTransforms: phantomPose, scale: phantomScale)
        jointCountLastFrame = phantomPose.count
        lastIntactWorld = intactPose
        lastIntactIndexTip = intactPose[.indexFingerTip]?.translation
        lastPhantomIndexTip = phantomPose[.indexFingerTip]?.translation
        lastPhantomOpenness = 0.12
        lastPhantomWorld = phantomPose
    }

    private static func applyJointOffsets(
        _ offsets: [HandSkeleton.JointName: SIMD3<Float>],
        to transforms: [HandSkeleton.JointName: simd_float4x4]
    ) -> [HandSkeleton.JointName: simd_float4x4] {
        guard !offsets.isEmpty else { return transforms }

        var adjusted = transforms
        for (joint, offset) in offsets {
            guard var transform = adjusted[joint] else { continue }
            transform.columns.3 += SIMD4(offset.x, offset.y, offset.z, 0)
            adjusted[joint] = transform
        }
        return adjusted
    }

    private static func makePreviewHandPose(
        wrist: SIMD3<Float>,
        isLeft: Bool
    ) -> [HandSkeleton.JointName: simd_float4x4] {
        let side: Float = isLeft ? -1 : 1
        func mat(_ p: SIMD3<Float>) -> simd_float4x4 {
            var m = matrix_identity_float4x4
            m.columns.3 = SIMD4(p.x, p.y, p.z, 1)
            return m
        }
        var result: [HandSkeleton.JointName: simd_float4x4] = [.wrist: mat(wrist)]
        result[.forearmWrist] = mat(wrist + SIMD3(0, -0.045, 0.005))
        result[.forearmArm] = mat(wrist + SIMD3(0, -0.16, 0.015))

        let thumbBase = wrist + SIMD3(side * 0.03, 0.02, 0.01)
        result[.thumbKnuckle] = mat(thumbBase)
        result[.thumbIntermediateBase] = mat(thumbBase + SIMD3(side * 0.025, 0.02, 0.015))
        result[.thumbIntermediateTip] = mat(thumbBase + SIMD3(side * 0.04, 0.035, 0.025))
        result[.thumbTip] = mat(thumbBase + SIMD3(side * 0.05, 0.05, 0.03))
        let fingerDefs: [(HandSkeleton.JointName, HandSkeleton.JointName, HandSkeleton.JointName, HandSkeleton.JointName, HandSkeleton.JointName, Float)] = [
            (.indexFingerMetacarpal, .indexFingerKnuckle, .indexFingerIntermediateBase, .indexFingerIntermediateTip, .indexFingerTip, 0.03),
            (.middleFingerMetacarpal, .middleFingerKnuckle, .middleFingerIntermediateBase, .middleFingerIntermediateTip, .middleFingerTip, 0.0),
            (.ringFingerMetacarpal, .ringFingerKnuckle, .ringFingerIntermediateBase, .ringFingerIntermediateTip, .ringFingerTip, -0.03),
            (.littleFingerMetacarpal, .littleFingerKnuckle, .littleFingerIntermediateBase, .littleFingerIntermediateTip, .littleFingerTip, -0.055)
        ]
        for (meta, knuckle, interBase, interTip, tip, xOff) in fingerDefs {
            let base = wrist + SIMD3(side * xOff, 0.03, 0)
            result[meta] = mat(base)
            result[knuckle] = mat(base + SIMD3(0, 0.04, 0))
            result[interBase] = mat(base + SIMD3(0, 0.07, 0))
            result[interTip] = mat(base + SIMD3(0, 0.095, 0))
            result[tip] = mat(base + SIMD3(0, 0.12, 0))
        }
        return result
    }
}
