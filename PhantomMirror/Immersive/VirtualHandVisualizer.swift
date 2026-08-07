import Foundation
import RealityKit
import ARKit
import simd
import UIKit

/// Procedural hand visualization: joint spheres + bone cylinders.
/// Used for both intact (1:1) and phantom (mirrored) hands so the demo runs without a USDZ asset.
@MainActor
final class VirtualHandVisualizer {
    let root = Entity()
    private var jointEntities: [HandSkeleton.JointName: ModelEntity] = [:]
    private var boneEntities: [String: ModelEntity] = [:]

    private let jointRadius: Float = 0.008
    private let boneRadius: Float = 0.0035
    private let material: SimpleMaterial
    private let boneMaterial: SimpleMaterial

    /// Parent pairs for drawing bones (child → parent).
    private static let bonePairs: [(HandSkeleton.JointName, HandSkeleton.JointName)] = [
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
        material = SimpleMaterial(color: color, isMetallic: false)
        var bone = SimpleMaterial(color: color.withAlphaComponent(0.85), isMetallic: false)
        bone.roughness = 0.6
        boneMaterial = bone

        for jointName in HandSkeleton.JointName.allCases {
            let sphere = ModelEntity(
                mesh: .generateSphere(radius: jointRadius),
                materials: [material]
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

    /// Update all joints from world-space transforms keyed by joint name.
    func update(worldTransforms: [HandSkeleton.JointName: simd_float4x4], scale: Float = 1.0) {
        root.scale = SIMD3(repeating: scale)

        for (name, transform) in worldTransforms {
            guard let entity = jointEntities[name] else { continue }
            entity.isEnabled = true
            entity.transform = Transform(matrix: transform)
        }

        // Disable missing joints.
        for (name, entity) in jointEntities where worldTransforms[name] == nil {
            entity.isEnabled = false
        }

        for (child, parent) in Self.bonePairs {
            let key = "\(child)-\(parent)"
            guard let bone = boneEntities[key],
                  let childT = worldTransforms[child],
                  let parentT = worldTransforms[parent] else {
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
            bone.position = mid
            bone.scale = SIMD3(1, length, 1)

            // Orient cylinder (default Y-up) along `dir`.
            let y = simd_normalize(dir)
            let arbitrary: SIMD3<Float> = abs(y.y) < 0.99 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
            let x = simd_normalize(simd_cross(arbitrary, y))
            let z = simd_cross(x, y)
            bone.orientation = simd_quatf(simd_float3x3(columns: (x, y, z)))
        }
    }

    func tipPosition(of joint: HandSkeleton.JointName = .indexFingerTip) -> SIMD3<Float>? {
        guard let entity = jointEntities[joint], entity.isEnabled else { return nil }
        return entity.position(relativeTo: nil)
    }

    func wristPosition() -> SIMD3<Float>? {
        tipPosition(of: .wrist)
    }

    /// Approximate grip openness: average fingertip distance to wrist (meters).
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
