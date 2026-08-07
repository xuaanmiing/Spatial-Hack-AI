import Foundation
import simd

/// Mirrors a left-hand (or intact-hand) transform across the sagittal plane of the head,
/// producing a contralateral phantom-hand pose.
enum MirrorTransform {
    /// Reflect a rigid transform across the head's sagittal (YZ in head-local) plane.
    /// Using T' = R * T * R keeps orientations chirality-correct for left→right (and vice versa).
    static func mirror(
        _ transform: simd_float4x4,
        headPose: simd_float4x4
    ) -> simd_float4x4 {
        let headToWorld = headPose
        let worldToHead = headToWorld.inverse
        let reflectLocal = simd_float4x4(diagonal: SIMD4<Float>(-1, 1, 1, 1))

        // Bring into head space, reflect, back to world, then reflect orientation again.
        let inHead = worldToHead * transform
        let mirroredInHead = reflectLocal * inHead * reflectLocal
        return headToWorld * mirroredInHead
    }

    /// Apply calibration offset / yaw after mirroring. Scale is applied on the entity.
    static func applyCalibration(
        _ mirrored: simd_float4x4,
        calibration: CalibrationData,
        headPose: simd_float4x4
    ) -> simd_float4x4 {
        var result = mirrored

        result.columns.3.x += calibration.phantomOffset.x
        result.columns.3.y += calibration.phantomOffset.y
        result.columns.3.z += calibration.phantomOffset.z

        if abs(calibration.phantomYawRadians) > 0.0001 {
            let yaw = simd_quatf(angle: calibration.phantomYawRadians, axis: SIMD3<Float>(0, 1, 0))
            let yawMatrix = simd_float4x4(yaw)
            let wrist = result.translation
            // Rotate orientation about world up while keeping wrist translation.
            var oriented = yawMatrix * result
            oriented.columns.3 = SIMD4(wrist.x, wrist.y, wrist.z, 1)
            result = oriented
        }

        _ = headPose
        return result
    }

    /// World-space joint transform = wristWorld * jointLocal.
    static func worldJoint(
        wristWorld: simd_float4x4,
        jointLocal: simd_float4x4
    ) -> simd_float4x4 {
        wristWorld * jointLocal
    }
}

extension simd_float4x4 {
    var translation: SIMD3<Float> {
        SIMD3(columns.3.x, columns.3.y, columns.3.z)
    }

    init(_ quat: simd_quatf) {
        self = simd_float4x4(quat)
    }
}
