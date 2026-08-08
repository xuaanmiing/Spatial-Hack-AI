import Foundation
import RealityKit
import ARKit
import simd
import UIKit

/// Loads a rigged hand/forearm USDZ and drives it from an ARKit `HandSkeleton`.
///
/// Joints are matched by **name**, not by array index: different assets author their
/// skeletons in different orders (Apple's own gloves disagree with each other), so an
/// index-based mapping silently swaps fingers.
@MainActor
final class ARKitHandModel {
    /// Asset names tried in order; first one present in the bundle wins.
    private static let candidateAssets = ["HandArm_Right", "RightHand_ARKit27"]

    private(set) var root = Entity()
    private(set) var model: ModelEntity?
    private(set) var isLoaded = false
    private(set) var loadError: String?
    private(set) var assetName: String?

    /// modelJointIndex -> ARKit joint that drives it.
    private var jointMap: [(index: Int, name: HandSkeleton.JointName)] = []
    var jointCount: Int { jointMap.count }

    /// Authored rest pose captured at load — translations are reapplied each frame so
    /// debug joint offsets never accumulate.
    private var restJointTransforms: [Transform] = []

    /// Apple's sample drives every joint including the wrist. If the hand ends up
    /// rotated on device, set this to false to keep the asset's authored wrist rest pose.
    var drivesWristRotation = true

    let name: String
    private let tint: UIColor

    init(name: String, tint: UIColor = UIColor(red: 0.88, green: 0.67, blue: 0.56, alpha: 1.0)) {
        self.name = name
        self.tint = tint
        root.name = name
    }

    func loadFromBundle() async {
        guard !isLoaded else { return }

        var lastError: String?
        for asset in Self.candidateAssets {
            guard let url = Self.bundleURL(for: asset) else {
                lastError = "\(asset) not in bundle"
                continue
            }
            do {
                let entity = try await Entity(contentsOf: url)
                // Keep the whole SkelRoot hierarchy. Re-parenting just the mesh
                // makes RealityKit drop the skin binding and jointTransforms.
                entity.name = "\(name)-asset"
                root.addChild(entity)

                if let skinned = Self.findSkinnedModel(in: entity) {
                    model = skinned
                    jointMap = Self.buildJointMap(for: skinned.jointNames)
                    restJointTransforms = skinned.jointTransforms
                    applyMaterial(to: skinned)
                } else {
                    model = nil
                    jointMap = []
                    restJointTransforms = []
                    loadError = "no skinned mesh in \(asset)"
                    Self.forEachModel(in: entity) { applyMaterial(to: $0) }
                }

                assetName = asset
                isLoaded = true
                root.isEnabled = false
                if jointMap.isEmpty, loadError == nil {
                    loadError = "0 joints matched in \(asset)"
                }
                return
            } catch {
                lastError = "\(asset): \(error.localizedDescription)"
            }
        }

        loadError = lastError ?? "no hand asset found"
        isLoaded = false
    }

    func setVisible(_ visible: Bool) {
        root.isEnabled = visible
    }

    /// Pose the model from a tracked hand.
    /// - Parameters:
    ///   - mirrored: reflect joint rotations across the sagittal plane (drives the phantom side).
    ///   - mirrorMeshX: flip the mesh in X, for showing this right-handed asset as a left hand.
    ///   - jointOffsets: parent-local translation nudges (meters) for debug / retargeting.
    func apply(
        skeleton: HandSkeleton,
        wristWorld: simd_float4x4,
        mirrored: Bool,
        scale: Float = 1.0,
        mirrorMeshX: Bool = false,
        jointOffsets: [HandSkeleton.JointName: SIMD3<Float>] = [:]
    ) {
        place(wristWorld: wristWorld, scale: scale, mirrorMeshX: mirrorMeshX)

        guard let model, !jointMap.isEmpty else { return }
        var transforms = restJointTransforms.isEmpty ? model.jointTransforms : restJointTransforms
        // Rest snapshot can go stale if RealityKit rebuilt the skeleton; fall back to
        // the live jointTransforms array so we always match the model's expected count.
        if transforms.count != model.jointTransforms.count {
            transforms = model.jointTransforms
        }
        for entry in jointMap where entry.index < transforms.count {
            if entry.name == .wrist && !drivesWristRotation {
                let base = restTranslation(at: entry.index, fallback: transforms[entry.index].translation)
                transforms[entry.index].translation = base + (jointOffsets[entry.name] ?? .zero)
                continue
            }
            var local = skeleton.joint(entry.name).parentFromJointTransform
            if mirrored {
                local = MirrorTransform.mirrorLocalJoint(local)
            }
            // Rotation from ARKit; translation from the asset rest pose (+ optional debug offset).
            let base = restTranslation(at: entry.index, fallback: transforms[entry.index].translation)
            transforms[entry.index].rotation = simd_quatf(local)
            transforms[entry.index].translation = base + (jointOffsets[entry.name] ?? .zero)
        }
        model.jointTransforms = transforms
    }

    /// Show the authored rest pose at a given wrist placement (simulator / preview).
    func applyRestPose(
        wristWorld: simd_float4x4,
        scale: Float = 1.0,
        mirrorMeshX: Bool = false,
        jointOffsets: [HandSkeleton.JointName: SIMD3<Float>] = [:]
    ) {
        place(wristWorld: wristWorld, scale: scale, mirrorMeshX: mirrorMeshX)
        guard let model, !restJointTransforms.isEmpty else { return }
        var transforms = restJointTransforms
        for entry in jointMap where entry.index < transforms.count {
            let base = restTranslation(at: entry.index, fallback: transforms[entry.index].translation)
            transforms[entry.index].translation = base + (jointOffsets[entry.name] ?? .zero)
        }
        model.jointTransforms = transforms
    }

    private func restTranslation(at index: Int, fallback: SIMD3<Float>) -> SIMD3<Float> {
        guard index < restJointTransforms.count else { return fallback }
        return restJointTransforms[index].translation
    }

    private func place(wristWorld: simd_float4x4, scale: Float, mirrorMeshX: Bool) {
        root.isEnabled = true
        var t = Transform(matrix: wristWorld)
        let s = abs(scale)
        t.scale = SIMD3(mirrorMeshX ? -s : s, s, s)
        root.transform = t
    }

    private func applyMaterial(to model: ModelEntity) {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: tint)
        material.roughness = 0.55
        material.metallic = 0.0
        // Keeps the limb readable against bright passthrough even with weak scene lighting.
        material.emissiveColor = .init(color: tint)
        material.emissiveIntensity = 0.25

        let count = max(model.model?.materials.count ?? 1, 1)
        model.model?.materials = Array(repeating: material, count: count)
    }

    private static func bundleURL(for asset: String) -> URL? {
        for ext in ["usdz", "usdc", "usda"] {
            if let url = Bundle.main.url(forResource: asset, withExtension: ext) {
                return url
            }
        }
        return nil
    }

    private static func findSkinnedModel(in entity: Entity) -> ModelEntity? {
        if let model = entity as? ModelEntity, !model.jointNames.isEmpty {
            return model
        }
        for child in entity.children {
            if let found = findSkinnedModel(in: child) {
                return found
            }
        }
        return nil
    }

    private static func forEachModel(in entity: Entity, _ body: (ModelEntity) -> Void) {
        if let model = entity as? ModelEntity { body(model) }
        for child in entity.children { forEachModel(in: child, body) }
    }

    // MARK: - Joint name matching

    /// Matches both ARKit-style names ("indexFingerKnuckle") and Apple's glove rig
    /// names ("right_handIndex_1_joint"), so any of our assets can drive the same code.
    private static func buildJointMap(for jointNames: [String]) -> [(index: Int, name: HandSkeleton.JointName)] {
        var map: [(Int, HandSkeleton.JointName)] = []
        var used = Set<String>()

        for (index, raw) in jointNames.enumerated() {
            let leaf = raw.split(separator: "/").last.map(String.init) ?? raw
            guard let joint = jointName(from: leaf) else { continue }
            // First match wins, so a stray duplicate can't hijack a finger.
            let key = String(describing: joint)
            if used.contains(key) { continue }
            used.insert(key)
            map.append((index, joint))
        }
        return map
    }

    private static func jointName(from leaf: String) -> HandSkeleton.JointName? {
        // Exact ARKit case name (our procedural asset).
        for joint in HandSkeleton.JointName.allCases where String(describing: joint) == leaf {
            return joint
        }

        let s = leaf.lowercased()

        if s.contains("twist") { return .forearmWrist }
        if s.contains("forearm") { return .forearmArm }

        let finger: (metacarpal: HandSkeleton.JointName,
                     knuckle: HandSkeleton.JointName,
                     base: HandSkeleton.JointName,
                     tip1: HandSkeleton.JointName,
                     tip: HandSkeleton.JointName)?

        if s.contains("thumb") {
            // Thumb has one fewer segment; handled separately below.
            if s.contains("start") { return .thumbKnuckle }
            if s.contains("end") { return .thumbTip }
            if s.contains("_1") { return .thumbIntermediateBase }
            if s.contains("_2") { return .thumbIntermediateTip }
            return nil
        } else if s.contains("index") {
            finger = (.indexFingerMetacarpal, .indexFingerKnuckle, .indexFingerIntermediateBase,
                      .indexFingerIntermediateTip, .indexFingerTip)
        } else if s.contains("mid") {
            finger = (.middleFingerMetacarpal, .middleFingerKnuckle, .middleFingerIntermediateBase,
                      .middleFingerIntermediateTip, .middleFingerTip)
        } else if s.contains("ring") {
            finger = (.ringFingerMetacarpal, .ringFingerKnuckle, .ringFingerIntermediateBase,
                      .ringFingerIntermediateTip, .ringFingerTip)
        } else if s.contains("pinky") || s.contains("little") {
            finger = (.littleFingerMetacarpal, .littleFingerKnuckle, .littleFingerIntermediateBase,
                      .littleFingerIntermediateTip, .littleFingerTip)
        } else {
            finger = nil
        }

        if let f = finger {
            if s.contains("start") { return f.metacarpal }
            if s.contains("end") { return f.tip }
            if s.contains("_1") { return f.knuckle }
            if s.contains("_2") { return f.base }
            if s.contains("_3") { return f.tip1 }
            return nil
        }

        if s.contains("hand") || s.contains("wrist") { return .wrist }
        return nil
    }
}
