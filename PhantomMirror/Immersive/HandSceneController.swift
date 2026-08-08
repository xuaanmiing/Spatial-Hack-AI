import Foundation
import RealityKit
import SwiftUI
import ARKit
import simd
import UIKit

/// Scene owner: procedurally-skinned phantom hand + optional intact visual + task props.
/// The phantom hand is a `SkinnedProceduralHand` (PBR spheres + capsules) placed at the
/// exact same world-space joint positions the blue calibration skeleton uses, so the
/// skin coincides with the calibration markers by construction.
///
/// Never relies on SwiftUI View state for entity references.
@MainActor
@Observable
final class HandSceneController {
    let root = Entity()

    /// Procedurally-skinned hand for the phantom (mirrored) side.
    private let phantomSkin = SkinnedProceduralHand(name: "phantomSkin")
    /// Procedurally-skinned hand for the intact side (only shown when the
    /// user opts in during calibration / debug).
    private let intactSkin = SkinnedProceduralHand(name: "intactSkin")

    /// Debug fallback — original blue "wireframe" skeleton. Never shown in
    /// the shipping demo; kept here so future debugging can flip it on.
    private let fallbackIntact: VirtualHandVisualizer
    private let fallbackPhantom: VirtualHandVisualizer

    /// Debug markers drawn on every phantom joint so the user can see which
    /// bone their calibration UI is currently editing. Hidden during training.
    let jointMarkers = JointMarkerOverlay()

    private var hintEntity: ModelEntity?
    private(set) var isBuilt = false
    private(set) var modelsReady = false
    private(set) var statusDetail: String = "Procedural skin ready"
    private(set) var jointCountLastFrame: Int = 0
    /// Kept as `false` — the procedural skin path is always primary now.
    private(set) var usingFallback: Bool = false

    /// Most recent phantom-hand world transforms — reused by the marker
    /// overlay so it doesn't have to recompute the mirror math itself.
    private(set) var lastPhantomWorld: [HandSkeleton.JointName: simd_float4x4] = [:]

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
        root.addChild(phantomSkin.root)
        root.addChild(intactSkin.root)
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
        phantomSkin.setVisible(false)
        intactSkin.setVisible(false)
        isBuilt = true
    }

    func loadModels() async {
        // Procedural skin is built at init(); nothing to load asynchronously.
        modelsReady = true
        usingFallback = false
        statusDetail = "Procedural skin ready"
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

        // Apply per-joint offsets (calibration nudges) in world space, same
        // way the blue skeleton was doing it — so the skin lands on the same
        // markers the user calibrated with.
        phantomWorld = Self.applyJointOffsets(calibration.jointOffsetMap, to: phantomWorld)

        lastIntactIndexTip = intactWorld[.indexFingerTip]?.translation
        lastPhantomIndexTip = phantomWorld[.indexFingerTip]?.translation
        lastPhantomOpenness = fallbackPhantom.gripOpenness(from: phantomWorld)
        lastPhantomWorld = phantomWorld
        jointCountLastFrame = intactWorld.count
        setHintVisible(false)

        // Show the procedurally-skinned phantom hand at the mirrored+calibrated positions.
        phantomSkin.setVisible(true)
        phantomSkin.update(worldTransforms: phantomWorld, scale: calibration.phantomScale)

        // Optionally show the intact side too.
        if showIntact {
            intactSkin.setVisible(true)
            intactSkin.update(worldTransforms: intactWorld, scale: 1.0)
        } else {
            intactSkin.setVisible(false)
        }

        // Debug fallbacks stay off in the shipping demo.
        fallbackPhantom.setVisible(false)
        fallbackIntact.setVisible(false)
    }

    func hideHands(showHint: Bool = true) {
        phantomSkin.setVisible(false)
        intactSkin.setVisible(false)
        fallbackIntact.setVisible(false)
        fallbackPhantom.setVisible(false)
        jointMarkers.hideAll()
        setHintVisible(showHint)
        jointCountLastFrame = 0
        lastIntactIndexTip = nil
        lastPhantomIndexTip = nil
        lastPhantomOpenness = nil
        lastPhantomWorld = [:]
    }

    /// Simulator / no-tracking preview: place a rest-pose skinned hand in
    /// front of the user so the calibration UI has something visible.
    /// - Parameter phantomIsLeft: `true` when the missing (phantom) side is
    ///   the left hand.
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

        phantomSkin.setVisible(true)
        phantomSkin.update(worldTransforms: phantomPose, scale: phantomScale)

        if showIntact {
            intactSkin.setVisible(true)
            intactSkin.update(worldTransforms: intactPose)
        } else {
            intactSkin.setVisible(false)
        }

        fallbackIntact.setVisible(false)
        fallbackPhantom.setVisible(false)

        jointCountLastFrame = phantomPose.count
        lastIntactIndexTip = intactPose[.indexFingerTip]?.translation
        lastPhantomIndexTip = phantomPose[.indexFingerTip]?.translation
        lastPhantomOpenness = 0.12
        lastPhantomWorld = phantomPose
    }

    // MARK: - Helpers

    private static func applyJointOffsets(
        _ offsets: [HandSkeleton.JointName: SIMD3<Float>],
        to transforms: [HandSkeleton.JointName: simd_float4x4]
    ) -> [HandSkeleton.JointName: simd_float4x4] {
        guard !offsets.isEmpty else { return transforms }
        var adjusted = transforms
        for (joint, offset) in offsets {
            guard var t = adjusted[joint] else { continue }
            t.columns.3 += SIMD4(offset.x, offset.y, offset.z, 0)
            adjusted[joint] = t
        }
        return adjusted
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
