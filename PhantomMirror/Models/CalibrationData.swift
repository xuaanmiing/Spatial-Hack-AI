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
