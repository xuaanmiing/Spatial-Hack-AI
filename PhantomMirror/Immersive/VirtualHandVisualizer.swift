import Foundation
import RealityKit
import ARKit
import simd
import UIKit

/// Procedural hand visualization: large unlit joint spheres + bone cylinders (demo-visible).
@MainActor
final class VirtualHandVisualizer {
    let root = Entity()
    private var jointEntities: [HandSkeleton.JointName: ModelEntity] = [:]
    private var boneEntities: [String: ModelEntity] = [:]
    private var skinJointEntities: [HandSkeleton.JointName: ModelEntity] = [:]
    private var skinBoneEntities: [String: ModelEntity] = [:]
    private let palmEntity: ModelEntity

    /// Larger than real joints so the demo is obvious in passthrough.
    private let jointRadius: Float = 0.014
    private let boneRadius: Float = 0.006
    private let skinJointRadius: Float = 0.024
    private let skinBoneRadius: Float = 0.016
    private let jointMaterial: UnlitMaterial
    private let boneMaterial: UnlitMaterial
    private let skinMaterial: PhysicallyBasedMaterial

    private static let bonePairs: [(HandSkeleton.JointName, HandSkeleton.JointName)] = [
        (.wrist, .forearmWrist),
        (.forearmWrist, .forearmArm),

        (.thumbKnuckle, .wrist),
        (.thumbIntermediateBase, .thumbKnuckle),
        (.thumbIntermediateTip, .thumbIntermediateBase),
        (.thumbTip, .thumbIntermediateTip),

        (.indexFingerMetacarpal, .wrist),
        (.indexFingerKnuckle, .indexFingerMetacarpal),
        (.indexFingerIntermediateBase, .indexFingerKnuckle),
        (.indexFingerIntermediateTip, .indexFingerIntermediateBase),
        (.indexFingerTip, .indexFingerIntermediateTip),

        (.middleFingerMetacarpal, .wrist),
        (.middleFingerKnuckle, .middleFingerMetacarpal),
        (.middleFingerIntermediateBase, .middleFingerKnuckle),
        (.middleFingerIntermediateTip, .middleFingerIntermediateBase),
        (.middleFingerTip, .middleFingerIntermediateTip),

        (.ringFingerMetacarpal, .wrist),
        (.ringFingerKnuckle, .ringFingerMetacarpal),
        (.ringFingerIntermediateBase, .ringFingerKnuckle),
        (.ringFingerIntermediateTip, .ringFingerIntermediateBase),
        (.ringFingerTip, .ringFingerIntermediateTip),

        (.littleFingerMetacarpal, .wrist),
        (.littleFingerKnuckle, .littleFingerMetacarpal),
        (.littleFingerIntermediateBase, .littleFingerKnuckle),
        (.littleFingerIntermediateTip, .littleFingerIntermediateBase),
        (.littleFingerTip, .littleFingerIntermediateTip)
    ]

    init(name: String, color: UIColor) {
        root.name = name
        jointMaterial = UnlitMaterial(color: color)
        boneMaterial = UnlitMaterial(color: color.withAlphaComponent(0.9))
        var skin = PhysicallyBasedMaterial()
        skin.baseColor = .init(tint: UIColor(red: 0.86, green: 0.62, blue: 0.50, alpha: 0.78))
        skin.roughness = 0.34
        skin.metallic = 0.0
        skinMaterial = skin

        palmEntity = ModelEntity(
            mesh: .generateBox(size: SIMD3<Float>(0.11, 0.035, 0.09), cornerRadius: 0.025),
            materials: [skinMaterial]
        )
        palmEntity.name = "\(name)-skin-palm"
        palmEntity.isEnabled = false
        root.addChild(palmEntity)

        for jointName in HandSkeleton.JointName.allCases {
            let sphere = ModelEntity(
                mesh: .generateSphere(radius: skinJointRadius),
                materials: [skinMaterial]
            )
            sphere.name = "\(name)-skin-\(jointName)"
            sphere.isEnabled = false
            root.addChild(sphere)
            skinJointEntities[jointName] = sphere
        }

        for (child, parent) in Self.bonePairs {
            let key = "\(child)-\(parent)"
            let radius = Self.isForearmPair(child, parent) ? skinBoneRadius * 1.8 : skinBoneRadius
            let bone = ModelEntity(
                mesh: .generateCylinder(height: 1, radius: radius),
                materials: [skinMaterial]
            )
            bone.name = "\(name)-skin-bone-\(key)"
            bone.isEnabled = false
            root.addChild(bone)
            skinBoneEntities[key] = bone
        }

        for jointName in HandSkeleton.JointName.allCases {
            let sphere = ModelEntity(
                mesh: .generateSphere(radius: jointRadius),
                materials: [jointMaterial]
            )
            sphere.name = "\(name)-\(jointName)"
            sphere.isEnabled = false
            root.addChild(sphere)
            jointEntities[jointName] = sphere
        }

        for (child, parent) in Self.bonePairs {
            let key = "\(child)-\(parent)"
            let bone = ModelEntity(
                mesh: .generateCylinder(height: 1, radius: boneRadius),
                materials: [boneMaterial]
            )
            bone.name = "\(name)-bone-\(key)"
            bone.isEnabled = false
            root.addChild(bone)
            boneEntities[key] = bone
        }
    }

    func setVisible(_ visible: Bool) {
        root.isEnabled = visible
    }

    func update(worldTransforms: [HandSkeleton.JointName: simd_float4x4], scale: Float = 1.0) {
        root.scale = .one
        let clampedScale = max(0.01, abs(scale))
        let pivot = worldTransforms[.wrist]?.translation
        let displayedTransforms: [HandSkeleton.JointName: simd_float4x4]
        if let pivot, abs(clampedScale - 1) > 0.0001 {
            displayedTransforms = worldTransforms.mapValues { transform in
                var scaled = transform
                let position = pivot + (transform.translation - pivot) * clampedScale
                scaled.columns.3 = SIMD4(position.x, position.y, position.z, 1)
                return scaled
            }
        } else {
            displayedTransforms = worldTransforms
        }

        for (name, transform) in displayedTransforms {
            if let entity = skinJointEntities[name] {
                entity.isEnabled = true
                entity.setTransformMatrix(transform, relativeTo: nil)
            }
            guard let entity = jointEntities[name] else { continue }
            entity.isEnabled = true
            entity.setTransformMatrix(transform, relativeTo: nil)
        }

        for (name, entity) in jointEntities where displayedTransforms[name] == nil {
            entity.isEnabled = false
        }
        for (name, entity) in skinJointEntities where displayedTransforms[name] == nil {
            entity.isEnabled = false
        }

        updatePalm(from: displayedTransforms)

        for (child, parent) in Self.bonePairs {
            let key = "\(child)-\(parent)"
            guard let childT = displayedTransforms[child],
                  let parentT = displayedTransforms[parent] else {
                boneEntities[key]?.isEnabled = false
                skinBoneEntities[key]?.isEnabled = false
                continue
            }

            let a = parentT.translation
            let b = childT.translation
            let dir = b - a
            let length = simd_length(dir)
            guard length > 0.001 else {
                boneEntities[key]?.isEnabled = false
                skinBoneEntities[key]?.isEnabled = false
                continue
            }

            if let skinBone = skinBoneEntities[key] {
                updateCylinder(skinBone, from: a, to: b)
            }
            if let bone = boneEntities[key] {
                updateCylinder(bone, from: a, to: b)
            }
        }
    }

    private func updatePalm(from transforms: [HandSkeleton.JointName: simd_float4x4]) {
        guard let wrist = transforms[.wrist]?.translation,
              let index = transforms[.indexFingerMetacarpal]?.translation,
              let middle = transforms[.middleFingerMetacarpal]?.translation,
              let little = transforms[.littleFingerMetacarpal]?.translation else {
            palmEntity.isEnabled = false
            return
        }

        let center = (wrist + index + middle + little) * 0.25
        let across = simd_normalize(little - index)
        let forward = simd_normalize(middle - wrist)
        let normal = simd_normalize(simd_cross(across, forward))
        let correctedForward = simd_cross(normal, across)
        palmEntity.isEnabled = true
        palmEntity.setTransformMatrix(
            simd_float4x4(columns: (
                SIMD4(across.x * 0.75, across.y * 0.75, across.z * 0.75, 0),
                SIMD4(normal.x, normal.y, normal.z, 0),
                SIMD4(correctedForward.x, correctedForward.y, correctedForward.z, 0),
                SIMD4(center.x, center.y, center.z, 1)
            )),
            relativeTo: nil
        )
    }

    private func updateCylinder(_ entity: ModelEntity, from a: SIMD3<Float>, to b: SIMD3<Float>) {
        entity.isEnabled = true
        let mid = (a + b) * 0.5
        let dir = b - a
        let length = simd_length(dir)
        let y = simd_normalize(dir)
        let arbitrary: SIMD3<Float> = abs(y.y) < 0.99 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
        let x = simd_normalize(simd_cross(arbitrary, y))
        let z = simd_cross(x, y)
        let matrix = simd_float4x4(columns: (
            SIMD4(x.x, x.y, x.z, 0),
            SIMD4(y.x * length, y.y * length, y.z * length, 0),
            SIMD4(z.x, z.y, z.z, 0),
            SIMD4(mid.x, mid.y, mid.z, 1)
        ))
        entity.setTransformMatrix(matrix, relativeTo: nil)
    }

    private static func isForearmPair(_ a: HandSkeleton.JointName, _ b: HandSkeleton.JointName) -> Bool {
        (a == .wrist && b == .forearmWrist) || (a == .forearmWrist && b == .forearmArm)
    }

    func gripOpenness(from worldTransforms: [HandSkeleton.JointName: simd_float4x4]) -> Float? {
        guard let wrist = worldTransforms[.wrist]?.translation else { return nil }
        let tips: [HandSkeleton.JointName] = [
            .thumbTip, .indexFingerTip, .middleFingerTip, .ringFingerTip, .littleFingerTip
        ]
        var sum: Float = 0
        var count: Float = 0
        for tip in tips {
            guard let p = worldTransforms[tip]?.translation else { continue }
            sum += simd_distance(wrist, p)
            count += 1
        }
        guard count > 0 else { return nil }
        return sum / count
    }
}
