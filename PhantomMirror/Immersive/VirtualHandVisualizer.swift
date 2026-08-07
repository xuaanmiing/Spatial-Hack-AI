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

    /// Larger than real joints so the demo is obvious in passthrough.
    private let jointRadius: Float = 0.014
    private let boneRadius: Float = 0.006
    private let jointMaterial: UnlitMaterial
    private let boneMaterial: UnlitMaterial

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
            guard let entity = jointEntities[name] else { continue }
            entity.isEnabled = true
            entity.setTransformMatrix(transform, relativeTo: nil)
        }

        for (name, entity) in jointEntities where displayedTransforms[name] == nil {
            entity.isEnabled = false
        }

        for (child, parent) in Self.bonePairs {
            let key = "\(child)-\(parent)"
            guard let bone = boneEntities[key],
                  let childT = displayedTransforms[child],
                  let parentT = displayedTransforms[parent] else {
                boneEntities[key]?.isEnabled = false
                continue
            }

            let a = parentT.translation
            let b = childT.translation
            let mid = (a + b) * 0.5
            let dir = b - a
            let length = simd_length(dir)
            guard length > 0.001 else {
                bone.isEnabled = false
                continue
            }

            bone.isEnabled = true
            // Build a world transform for the cylinder (Y-up mesh → along dir).
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
            bone.setTransformMatrix(matrix, relativeTo: nil)
        }
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
