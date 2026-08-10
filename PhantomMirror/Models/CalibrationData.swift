import Foundation
import simd
import ARKit

struct CalibrationData: Codable, Equatable {
    private static let defaultSkinCenter = SIMD3<Float>(
        0.91588604, -1.3858759, -0.3796959
    )
    private static let defaultSkinRotation = SIMD4<Float>(
        0.41597965, -0.71764684, -0.54932106, 0.10094717
    )
    private static let defaultSkinScale: Float = 1.0

    /// Head-yaw-relative offset applied after mirroring, in meters.
    var phantomOffset: SIMD3<Float> = .zero

    /// Uniform scale of the phantom hand (telescoping compensation).
    var phantomScale: Float = 1.0

    /// Extra yaw (radians) around the up axis after mirroring.
    var phantomYawRadians: Float = 0

    /// Per-joint local translation offsets (meters), keyed by `String(describing: HandSkeleton.JointName)`.
    /// Applied on top of the USDZ rest bone lengths after rotations are driven.
    var jointOffsets: [String: SIMD3<Float>] = [:]

    /// Global transform used to align the selected handed skin with the procedural ARKit skeleton.
    /// User adjustment relative to the recorded default alignment.
    var skinOffset: SIMD3<Float> = .zero
    /// Current model center expressed in the fixed alignment frame. This is
    /// separate from the slider values because fixed-origin rotation also
    /// rotates the model center around that origin.
    var skinModelCenterOffset: SIMD3<Float>? = Self.defaultSkinCenter
    var skinRotationDegrees: SIMD3<Float> = .zero
    /// Accumulated orientation in the fixed alignment coordinate frame.
    /// Optional so calibration data saved by older builds still decodes.
    var skinRotationQuaternionVector: SIMD4<Float>? = Self.defaultSkinRotation
    var skinScale: Float = Self.defaultSkinScale
    var showSkinRig = true
    var skinAlignmentConfirmed = false

    static let offsetStep: Float = 0.1
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

    mutating func resetSkinAlignment() {
        skinOffset = .zero
        skinModelCenterOffset = Self.defaultSkinCenter
        skinRotationDegrees = .zero
        skinRotationQuaternionVector = Self.defaultSkinRotation
        skinScale = Self.defaultSkinScale
        showSkinRig = true
        skinAlignmentConfirmed = false
    }

    var skinRotationQuaternion: simd_quatf {
        if let vector = skinRotationQuaternionVector,
           simd_length_squared(vector) > 1e-12 {
            return simd_normalize(simd_quatf(vector: vector))
        }

        let radians = skinRotationDegrees * (.pi / 180)
        let qx = simd_quatf(angle: radians.x, axis: SIMD3<Float>(1, 0, 0))
        let qy = simd_quatf(angle: radians.y, axis: SIMD3<Float>(0, 1, 0))
        let qz = simd_quatf(angle: radians.z, axis: SIMD3<Float>(0, 0, 1))
        return simd_normalize(qz * qy * qx)
    }

    var resolvedSkinModelCenterOffset: SIMD3<Float> {
        if let skinModelCenterOffset {
            return skinModelCenterOffset
        }
        // Migrate the previous hierarchy, where translation lived below the
        // fixed-frame rotation pivot.
        return skinRotationQuaternion.act(skinOffset)
    }

    mutating func setSkinTranslation(axis: Int, value: Float) {
        let delta = value - skinOffset[axis]
        var center = resolvedSkinModelCenterOffset
        center[axis] += delta
        skinModelCenterOffset = center
        skinOffset[axis] = value
        skinAlignmentConfirmed = false
    }

    mutating func setSkinRotation(axis: Int, degrees: Float) {
        let delta = (degrees - skinRotationDegrees[axis]) * (.pi / 180)
        let fixedAxis: SIMD3<Float>
        switch axis {
        case 0: fixedAxis = SIMD3(1, 0, 0)
        case 1: fixedAxis = SIMD3(0, 1, 0)
        default: fixedAxis = SIMD3(0, 0, 1)
        }

        let fixedFrameDelta = simd_quatf(angle: delta, axis: fixedAxis)
        skinModelCenterOffset = fixedFrameDelta.act(resolvedSkinModelCenterOffset)
        let updated = simd_normalize(fixedFrameDelta * skinRotationQuaternion)
        skinRotationQuaternionVector = updated.vector
        skinRotationDegrees[axis] = degrees
        skinAlignmentConfirmed = false
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

    // MARK: - Human-friendly grouping (for the calibration UI)

    /// Semantic groups of joints, ordered wrist → forearm → thumb → fingers (radial to ulnar).
    /// Used by the calibration panel to render collapsible sections instead of one flat list.
    enum JointGroup: String, CaseIterable, Identifiable {
        case wrist
        case forearm
        case thumb
        case index
        case middle
        case ring
        case little

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .wrist:   return "Wrist"
            case .forearm: return "Forearm"
            case .thumb:   return "Thumb"
            case .index:   return "Index finger"
            case .middle:  return "Middle finger"
            case .ring:    return "Ring finger"
            case .little:  return "Little finger"
            }
        }

        var systemImage: String {
            switch self {
            case .wrist:   return "hand.point.up.left.fill"
            case .forearm: return "figure.arms.open"
            default:       return "hand.raised.fingers.spread.fill"
            }
        }

        /// Joints belonging to this group, in root-to-tip order.
        var joints: [HandSkeleton.JointName] {
            switch self {
            case .wrist:
                return [.wrist]
            case .forearm:
                return [.forearmWrist, .forearmArm]
            case .thumb:
                return [
                    .thumbKnuckle,
                    .thumbIntermediateBase,
                    .thumbIntermediateTip,
                    .thumbTip
                ]
            case .index:
                return [
                    .indexFingerMetacarpal,
                    .indexFingerKnuckle,
                    .indexFingerIntermediateBase,
                    .indexFingerIntermediateTip,
                    .indexFingerTip
                ]
            case .middle:
                return [
                    .middleFingerMetacarpal,
                    .middleFingerKnuckle,
                    .middleFingerIntermediateBase,
                    .middleFingerIntermediateTip,
                    .middleFingerTip
                ]
            case .ring:
                return [
                    .ringFingerMetacarpal,
                    .ringFingerKnuckle,
                    .ringFingerIntermediateBase,
                    .ringFingerIntermediateTip,
                    .ringFingerTip
                ]
            case .little:
                return [
                    .littleFingerMetacarpal,
                    .littleFingerKnuckle,
                    .littleFingerIntermediateBase,
                    .littleFingerIntermediateTip,
                    .littleFingerTip
                ]
            }
        }
    }

    /// Human label for the calibration panel row (e.g. "Tip", "Middle knuckle").
    static func friendlyName(for joint: HandSkeleton.JointName) -> String {
        switch joint {
        case .wrist:                          return "Wrist center"
        case .forearmWrist:                   return "Forearm — wrist end"
        case .forearmArm:                     return "Forearm — elbow end"

        case .thumbKnuckle:                   return "Base (CMC)"
        case .thumbIntermediateBase:          return "Middle (MCP)"
        case .thumbIntermediateTip:           return "Upper (IP)"
        case .thumbTip:                       return "Tip"

        case .indexFingerMetacarpal:          return "Metacarpal"
        case .indexFingerKnuckle:             return "Knuckle (MCP)"
        case .indexFingerIntermediateBase:    return "Middle (PIP)"
        case .indexFingerIntermediateTip:     return "Upper (DIP)"
        case .indexFingerTip:                 return "Tip"

        case .middleFingerMetacarpal:         return "Metacarpal"
        case .middleFingerKnuckle:            return "Knuckle (MCP)"
        case .middleFingerIntermediateBase:   return "Middle (PIP)"
        case .middleFingerIntermediateTip:    return "Upper (DIP)"
        case .middleFingerTip:                return "Tip"

        case .ringFingerMetacarpal:           return "Metacarpal"
        case .ringFingerKnuckle:              return "Knuckle (MCP)"
        case .ringFingerIntermediateBase:     return "Middle (PIP)"
        case .ringFingerIntermediateTip:      return "Upper (DIP)"
        case .ringFingerTip:                  return "Tip"

        case .littleFingerMetacarpal:         return "Metacarpal"
        case .littleFingerKnuckle:            return "Knuckle (MCP)"
        case .littleFingerIntermediateBase:   return "Middle (PIP)"
        case .littleFingerIntermediateTip:    return "Upper (DIP)"
        case .littleFingerTip:                return "Tip"

        @unknown default:
            return Self.jointKey(joint)
        }
    }

    /// Group that a joint belongs to (used to preselect the correct section).
    static func group(for joint: HandSkeleton.JointName) -> JointGroup {
        for group in JointGroup.allCases where group.joints.contains(joint) {
            return group
        }
        return .wrist
    }

    /// Number of joints in this group with a non-zero offset (for badge display).
    func tunedCount(in group: JointGroup) -> Int {
        group.joints.reduce(0) { count, joint in
            simd_length_squared(offset(for: joint)) > 1e-12 ? count + 1 : count
        }
    }

    /// Reset every offset within one group (used for per-finger "Reset" buttons).
    mutating func resetOffsets(in group: JointGroup) {
        for joint in group.joints {
            setOffset(.zero, for: joint)
        }
    }
}
