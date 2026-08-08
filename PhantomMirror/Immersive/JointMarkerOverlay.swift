import Foundation
import RealityKit
import ARKit
import simd
import UIKit

/// Draws a small unlit sphere at every phantom-hand joint the user can calibrate.
///
/// Purpose: while the user is nudging a bone in the `JointDebugPanel`, they can
/// *see* exactly which bone they are moving on the actual phantom hand — the
/// selected marker glows brighter and pulses. Idle markers stay small and dim
/// so they don't distract during the training phase.
///
/// The overlay owns a fixed pool of `ModelEntity` spheres (one per adjustable
/// joint), reused every frame — no per-frame allocations.
@MainActor
final class JointMarkerOverlay {
    let root = Entity()

    private var markers: [HandSkeleton.JointName: ModelEntity] = [:]

    /// Base radius of an unselected marker (meters).
    private let baseRadius: Float = 0.004
    /// Radius the selected marker grows to at the peak of its pulse.
    private let selectedRadius: Float = 0.008

    private let idleColor    = UIColor(red: 0.35, green: 0.75, blue: 1.00, alpha: 0.85)
    private let tunedColor   = UIColor(red: 1.00, green: 0.55, blue: 0.15, alpha: 0.95)
    private let selectedColor = UIColor(red: 1.00, green: 0.90, blue: 0.25, alpha: 1.00)

    private var isVisibleFlag = true

    init() {
        root.name = "jointMarkers"
        for joint in CalibrationData.adjustableJoints {
            let sphere = ModelEntity(
                mesh: .generateSphere(radius: baseRadius),
                materials: [UnlitMaterial(color: idleColor)]
            )
            sphere.name = "marker-\(CalibrationData.jointKey(joint))"
            sphere.isEnabled = false
            root.addChild(sphere)
            markers[joint] = sphere
        }
    }

    /// Master switch — hide markers entirely during training so the demo looks clean.
    func setVisible(_ visible: Bool) {
        isVisibleFlag = visible
        root.isEnabled = visible
        if !visible {
            for entity in markers.values { entity.isEnabled = false }
        }
    }

    /// Update marker positions from the current phantom-hand world transforms.
    /// - Parameters:
    ///   - worldTransforms: joint → world 4×4 (from `HandSceneController`).
    ///   - selectedJoint: the joint currently highlighted in the calibration UI.
    ///   - tunedJoints: joints that have a non-zero offset (rendered in orange).
    ///   - time: monotonic time in seconds, used to animate the selected pulse.
    func update(
        worldTransforms: [HandSkeleton.JointName: simd_float4x4],
        selectedJoint: HandSkeleton.JointName,
        tunedJoints: Set<HandSkeleton.JointName>,
        time: TimeInterval
    ) {
        guard isVisibleFlag else { return }

        // Pulse: 0…1 sinusoid, 1.6 Hz — visible without being seizure-inducing.
        let pulse = 0.5 + 0.5 * sinf(Float(time) * 3.2)

        for (joint, entity) in markers {
            guard let world = worldTransforms[joint] else {
                entity.isEnabled = false
                continue
            }

            let isSelected = joint == selectedJoint
            let isTuned = tunedJoints.contains(joint)

            let radius: Float
            let color: UIColor
            if isSelected {
                radius = baseRadius + (selectedRadius - baseRadius) * pulse
                color = selectedColor
            } else if isTuned {
                radius = baseRadius * 1.15
                color = tunedColor
            } else {
                radius = baseRadius
                color = idleColor
            }

            entity.isEnabled = true
            entity.setTransformMatrix(world, relativeTo: nil)
            // Scale a unit-radius sphere pre-baked at baseRadius up/down.
            let s = radius / baseRadius
            entity.transform.scale = SIMD3(repeating: s)
            entity.model?.materials = [UnlitMaterial(color: color)]
        }
    }

    /// Hide every marker (called when the phantom hand is not being drawn).
    func hideAll() {
        for entity in markers.values { entity.isEnabled = false }
    }
}
