import Foundation
import RealityKit
import SwiftUI
import ARKit
import simd
import UIKit

/// Scene owner: USDZ phantom hand + optional intact visual + task props.
/// Never relies on SwiftUI View state for entity references.
@MainActor
@Observable
final class HandSceneController {
    let root = Entity()

    /// Primary: rigged hand/forearm driving the phantom (mirrored) side.
    let phantomUSDZ = ARKitHandModel(name: "phantomUSDZ")
    /// Optional intact hand (same right-handed asset, mirrored in X when tracking left).
    let intactUSDZ = ARKitHandModel(
        name: "intactUSDZ",
        tint: UIColor(red: 0.62, green: 0.78, blue: 0.88, alpha: 1.0)
    )

    /// Fallback procedural skeleton if USDZ fails to load / has no joints.
    private let fallbackIntact: VirtualHandVisualizer
    private let fallbackPhantom: VirtualHandVisualizer

    private var hintEntity: ModelEntity?
    private(set) var isBuilt = false
    private(set) var modelsReady = false
    private(set) var statusDetail: String = "Models not loaded"
    private(set) var jointCountLastFrame: Int = 0
    private(set) var usingFallback: Bool = false

    /// Tip positions for training tasks (world space).
    private(set) var lastIntactIndexTip: SIMD3<Float>?
    private(set) var lastPhantomIndexTip: SIMD3<Float>?
    private(set) var lastPhantomOpenness: Float?

    init() {
        fallbackIntact = VirtualHandVisualizer(name: "fallbackIntact", color: .systemCyan)
        fallbackPhantom = VirtualHandVisualizer(
            name: "fallbackPhantom",
            color: UIColor(red: 1.0, green: 0.55, blue: 0.2, alpha: 1.0)
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
        await phantomUSDZ.loadFromBundle()
        await intactUSDZ.loadFromBundle()

        let phantomOK = phantomUSDZ.isLoaded && phantomUSDZ.jointCount > 0
        usingFallback = !phantomOK
        modelsReady = true

        if phantomOK {
            statusDetail = "\(phantomUSDZ.assetName ?? "USDZ") · \(phantomUSDZ.jointCount) joints"
        } else if phantomUSDZ.isLoaded {
            let err = phantomUSDZ.loadError ?? "0 joints"
            statusDetail = "USDZ mesh + procedural (\(err))"
        } else {
            let err = phantomUSDZ.loadError ?? "missing from bundle"
            statusDetail = "Procedural only (\(err))"
        }
    }

    func setHintVisible(_ visible: Bool) {
        hintEntity?.isEnabled = visible
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

        var phantomWorld: [HandSkeleton.JointName: simd_float4x4] = [:]
        for (name, worldT) in intactWorld {
            let mirrored = MirrorTransform.mirror(worldT, headPose: headPose)
            phantomWorld[name] = MirrorTransform.applyCalibration(
                mirrored,
                calibration: calibration,
                headPose: headPose
            )
        }

        lastIntactIndexTip = intactWorld[.indexFingerTip]?.translation
        lastPhantomIndexTip = phantomWorld[.indexFingerTip]?.translation
        lastPhantomOpenness = fallbackPhantom.gripOpenness(from: phantomWorld)
        jointCountLastFrame = intactWorld.count
        setHintVisible(false)

        let mirroredWrist = MirrorTransform.applyCalibration(
            MirrorTransform.mirror(wristWorld, headPose: headPose),
            calibration: calibration,
            headPose: headPose
        )

        if !usingFallback, phantomUSDZ.jointCount > 0 {
            let jointOffsets = calibration.jointOffsetMap

            // Phantom = right-handed asset at the mirrored wrist, driven by mirrored rotations.
            phantomUSDZ.apply(
                skeleton: skeleton,
                wristWorld: mirroredWrist,
                mirrored: true,
                scale: calibration.phantomScale,
                mirrorMeshX: !intactIsLeft,
                jointOffsets: jointOffsets
            )
            fallbackPhantom.setVisible(false)

            if showIntact, intactUSDZ.isLoaded, intactUSDZ.jointCount > 0 {
                // Same right-handed mesh; flip X when the intact side is the left hand.
                intactUSDZ.apply(
                    skeleton: skeleton,
                    wristWorld: wristWorld,
                    mirrored: false,
                    scale: 1.0,
                    mirrorMeshX: intactIsLeft,
                    jointOffsets: [:]
                )
                fallbackIntact.setVisible(false)
            } else if showIntact {
                intactUSDZ.setVisible(false)
                fallbackIntact.setVisible(true)
                fallbackIntact.update(worldTransforms: intactWorld)
            } else {
                intactUSDZ.setVisible(false)
                fallbackIntact.setVisible(false)
            }
        } else {
            // Never leave the user with nothing on device.
            // If USDZ mesh loaded without joints, park it at the wrist; always drive procedural.
            if phantomUSDZ.isLoaded {
                phantomUSDZ.applyRestPose(
                    wristWorld: mirroredWrist,
                    scale: calibration.phantomScale,
                    mirrorMeshX: !intactIsLeft,
                    jointOffsets: calibration.jointOffsetMap
                )
            } else {
                phantomUSDZ.setVisible(false)
            }
            intactUSDZ.setVisible(false)

            fallbackPhantom.setVisible(true)
            fallbackPhantom.update(worldTransforms: phantomWorld, scale: calibration.phantomScale)
            fallbackIntact.setVisible(showIntact)
            if showIntact { fallbackIntact.update(worldTransforms: intactWorld) }
        }
    }

    func hideHands(showHint: Bool = true) {
        phantomUSDZ.setVisible(false)
        intactUSDZ.setVisible(false)
        fallbackIntact.setVisible(false)
        fallbackPhantom.setVisible(false)
        setHintVisible(showHint)
        jointCountLastFrame = 0
        lastIntactIndexTip = nil
        lastPhantomIndexTip = nil
        lastPhantomOpenness = nil
    }

    /// Simulator / no-tracking: show USDZ rest pose (or procedural) in front of user.
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
        let phantomWrist = Self.makeWristMatrix(at: phantomPos)
        let intactWrist = Self.makeWristMatrix(at: intactPos)
        // Asset is right-handed; flip X only when placing a left phantom / left intact.
        let phantomMirrorX = phantomIsLeft
        let intactMirrorX = !phantomIsLeft

        if !usingFallback, phantomUSDZ.isLoaded {
            phantomUSDZ.applyRestPose(
                wristWorld: phantomWrist,
                scale: phantomScale,
                mirrorMeshX: phantomMirrorX,
                jointOffsets: jointOffsets
            )
            if showIntact, intactUSDZ.isLoaded {
                intactUSDZ.applyRestPose(wristWorld: intactWrist, scale: 1, mirrorMeshX: intactMirrorX)
            } else {
                intactUSDZ.setVisible(false)
            }
            fallbackIntact.setVisible(false)
            fallbackPhantom.setVisible(false)
            jointCountLastFrame = max(phantomUSDZ.jointCount, 27)
            lastPhantomIndexTip = phantomPos + SIMD3(0, 0.05, -0.12)
            lastIntactIndexTip = intactPos + SIMD3(0, 0.05, -0.12)
            lastPhantomOpenness = 0.12
        } else {
            let phantomPose = Self.makePreviewHandPose(wrist: phantomPos, isLeft: phantomIsLeft)
            let intactPose = Self.makePreviewHandPose(wrist: intactPos, isLeft: !phantomIsLeft)
            phantomUSDZ.setVisible(false)
            intactUSDZ.setVisible(false)
            fallbackIntact.setVisible(showIntact)
            if showIntact { fallbackIntact.update(worldTransforms: intactPose) }
            fallbackPhantom.setVisible(true)
            fallbackPhantom.update(worldTransforms: phantomPose)
            jointCountLastFrame = phantomPose.count
            lastIntactIndexTip = intactPose[.indexFingerTip]?.translation
            lastPhantomIndexTip = phantomPose[.indexFingerTip]?.translation
            lastPhantomOpenness = 0.12
        }
    }

    private static func makeWristMatrix(at p: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(p.x, p.y, p.z, 1)
        return m
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
