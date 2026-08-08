import Foundation
import simd
import ARKit

struct CalibrationData: Codable, Equatable {
    /// Head-yaw-relative offset applied after mirroring, in meters.
    var phantomOffset: SIMD3<Float> = .zero

    /// Uniform scale of the phantom hand (telescoping compensation).
    var phantomScale: Float = 1.0

    /// Extra yaw (radians) around the up axis after mirroring.
    var phantomYawRadians: Float = 0

    /// Per-joint local translation offsets (meters), keyed by `String(describing: HandSkeleton.JointName)`.
    /// Applied on top of the USDZ rest bone lengths after rotations are driven.
    var jointOffsets: [String: SIMD3<Float>] = [:]

    static let offsetStep: Float = 0.01
    static let scaleStep: Float = 0.05
    static let jointOffsetStep: Float = 0.002

    static let adjustableJoints: [HandSkeleton.JointName] = HandSkeleton.JointName.allCases

    static func jointKey(_ joint: HandSkeleton.JointName) -> String {
        String(describing: joint)
    }

    func offset(for joint: HandSkeleton.JointName) -> SIMD3<Float> {
        jointOffsets[Self.jointKey(joint)] ?? .zero
    }

    mutating func setOffset(_ value: SIMD3<Float>, for joint: HandSkeleton.JointName) {
        let key = Self.jointKey(joint)
        if simd_length_squared(value) < 1e-12 {
            jointOffsets.removeValue(forKey: key)
        } else {
            jointOffsets[key] = value
        }
    }

    mutating func nudge(_ joint: HandSkeleton.JointName, axis: Int, delta: Float) {
        var v = offset(for: joint)
        switch axis {
        case 0: v.x += delta
        case 1: v.y += delta
        default: v.z += delta
        }
        setOffset(v, for: joint)
    }

    mutating func resetJointOffsets() {
        jointOffsets.removeAll()
    }

    /// Map used by the skinned hand driver.
    var jointOffsetMap: [HandSkeleton.JointName: SIMD3<Float>] {
        var map: [HandSkeleton.JointName: SIMD3<Float>] = [:]
        for joint in Self.adjustableJoints {
            let v = offset(for: joint)
            if simd_length_squared(v) > 1e-12 {
                map[joint] = v
            }
        }
        return map
    }

    /// Compact dump for copying tuned values into code later.
    var jointOffsetsDebugDump: String {
        let lines = Self.adjustableJoints.compactMap { joint -> String? in
            let v = offset(for: joint)
            guard simd_length_squared(v) > 1e-12 else { return nil }
            return String(format: "%@: (%.4f, %.4f, %.4f)", Self.jointKey(joint), v.x, v.y, v.z)
        }
        return lines.isEmpty ? "(no joint offsets)" : lines.joined(separator: "\n")
    }
}
