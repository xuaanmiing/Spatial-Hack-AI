import Foundation
import simd

struct CalibrationData: Codable, Equatable {
    /// Head-yaw-relative offset applied after mirroring, in meters.
    var phantomOffset: SIMD3<Float> = .zero

    /// Uniform scale of the phantom hand (telescoping compensation).
    var phantomScale: Float = 1.0

    /// Extra yaw (radians) around the up axis after mirroring.
    var phantomYawRadians: Float = 0

    static let offsetStep: Float = 0.01
    static let scaleStep: Float = 0.05
}
