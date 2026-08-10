import Foundation
import simd

/// Mirrors a left-hand (or intact-hand) transform across the sagittal plane of the head,
/// producing a contralateral phantom-hand pose.
enum MirrorTransform {
    private static let reflectX = simd_float4x4(diagonal: SIMD4<Float>(-1, 1, 1, 1))

    /// Reflect a rigid world transform across the vertical sagittal plane through the head.
    /// Head pitch and roll are intentionally ignored so looking down does not tilt the body midline.
    static func mirror(
        _ transform: simd_float4x4,
        headPose: simd_float4x4
    ) -> simd_float4x4 {
        var right = SIMD3<Float>(
            headPose.columns.0.x,
            0,
            headPose.columns.0.z
        )
        guard simd_length_squared(right) > 0.000001 else { return transform }
        right = simd_normalize(right)

        let nx = right.x
        let nz = right.z
        let linearReflection = simd_float4x4(columns: (
            SIMD4(1 - 2 * nx * nx, 0, -2 * nx * nz, 0),
            SIMD4(0, 1, 0, 0),
            SIMD4(-2 * nx * nz, 0, 1 - 2 * nz * nz, 0),
            SIMD4(0, 0, 0, 1)
        ))

        let headPosition = headPose.translation
        let reflectedHead4 = linearReflection * SIMD4(headPosition, 1)
        let reflectedHead = SIMD3(reflectedHead4.x, reflectedHead4.y, reflectedHead4.z)
        var planeReflection = linearReflection
        let translation = headPosition - reflectedHead
        planeReflection.columns.3 = SIMD4(translation, 1)

        return planeReflection * transform * linearReflection
    }

    /// Rigid yaw-and-translation delta between two head poses. Applying this
    /// same matrix to every mirrored joint lets the phantom follow the head
    /// without changing any joint-to-joint relationship.
    static func rigidHorizontalHeadDelta(
        from referencePose: simd_float4x4,
        to currentPose: simd_float4x4
    ) -> simd_float4x4 {
        horizontalHeadFrame(currentPose) * simd_inverse(horizontalHeadFrame(referencePose))
    }

    private static func horizontalHeadFrame(_ pose: simd_float4x4) -> simd_float4x4 {
        var right = SIMD3<Float>(pose.columns.0.x, 0, pose.columns.0.z)
        if simd_length_squared(right) < 0.000001 {
            right = SIMD3(1, 0, 0)
        } else {
            right = simd_normalize(right)
        }
        let up = SIMD3<Float>(0, 1, 0)
        let back = simd_normalize(simd_cross(right, up))
        return simd_float4x4(columns: (
            SIMD4(right, 0),
            SIMD4(up, 0),
            SIMD4(back, 0),
            SIMD4(pose.translation, 1)
        ))
    }

    /// Mirror a parent-relative joint transform for the opposite hand.
    /// Used when copying left-hand `parentFromJointTransform` onto a right-hand skeleton.
    static func mirrorLocalJoint(_ parentFromJoint: simd_float4x4) -> simd_float4x4 {
        reflectX * parentFromJoint * reflectX
    }

    /// Apply calibration offset / yaw after mirroring. Scale is applied on the entity.
    static func applyCalibration(
        _ mirrored: simd_float4x4,
        calibration: CalibrationData,
        headPose: simd_float4x4
    ) -> simd_float4x4 {
        var result = mirrored

        var headRight = SIMD3<Float>(headPose.columns.0.x, 0, headPose.columns.0.z)
        if simd_length_squared(headRight) < 0.000001 {
            headRight = SIMD3(1, 0, 0)
        } else {
            headRight = simd_normalize(headRight)
        }
        let worldUp = SIMD3<Float>(0, 1, 0)
        let headBack = simd_normalize(simd_cross(headRight, worldUp))
        let worldOffset =
            headRight * calibration.phantomOffset.x
            + worldUp * calibration.phantomOffset.y
            + headBack * calibration.phantomOffset.z
        result.columns.3 += SIMD4(worldOffset, 0)

        if abs(calibration.phantomYawRadians) > 0.0001 {
            let yaw = simd_quatf(angle: calibration.phantomYawRadians, axis: SIMD3<Float>(0, 1, 0))
            let yawMatrix = simd_float4x4(yaw)
            let wrist = result.translation
            var oriented = yawMatrix * result
            oriented.columns.3 = SIMD4(wrist.x, wrist.y, wrist.z, 1)
            result = oriented
        }

        return result
    }
}

extension simd_float4x4 {
    var translation: SIMD3<Float> {
        SIMD3(columns.3.x, columns.3.y, columns.3.z)
    }
}

extension MirrorTransform {
    /// Place a point relative to the user's current head: +X right, +Y up, +Z forward (in front).
    static func pointRelativeToHead(
        _ headPose: simd_float4x4,
        right: Float,
        up: Float,
        forward: Float
    ) -> SIMD3<Float> {
        let headPosition = headPose.translation

        var headRight = SIMD3<Float>(headPose.columns.0.x, 0, headPose.columns.0.z)
        if simd_length_squared(headRight) < 0.000001 {
            headRight = SIMD3(1, 0, 0)
        } else {
            headRight = simd_normalize(headRight)
        }

        // Device looks along -Z; horizontal forward is the flattened opposite of column 2.
        var headForward = SIMD3<Float>(-headPose.columns.2.x, 0, -headPose.columns.2.z)
        if simd_length_squared(headForward) < 0.000001 {
            headForward = SIMD3(0, 0, -1)
        } else {
            headForward = simd_normalize(headForward)
        }

        let worldUp = SIMD3<Float>(0, 1, 0)
        return headPosition
            + headRight * right
            + worldUp * up
            + headForward * forward
    }
}
