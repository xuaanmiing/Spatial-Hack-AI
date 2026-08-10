import Foundation
import SwiftUI
import simd
import ARKit

@MainActor
@Observable
final class AppState {
    enum Phase: String {
        case onboarding
        case calibration
        case training
        case report
    }

    enum CalibrationTab: String, CaseIterable, Identifiable {
        case pose
        case joints

        var id: String { rawValue }

        var title: String {
            switch self {
            case .pose: return "Pose"
            case .joints: return "Joints"
            }
        }
    }

    enum MissingSide: String, CaseIterable, Identifiable {
        case right
        case left

        var id: String { rawValue }

        var title: String {
            switch self {
            case .right: return "Right hand missing"
            case .left: return "Left hand missing"
            }
        }

        var intactSideTitle: String {
            switch self {
            case .right: return "Left (intact)"
            case .left: return "Right (intact)"
            }
        }

        /// Chirality of the intact hand we track.
        var intactIsLeft: Bool { self == .right }
    }

    var phase: Phase = .onboarding
    var missingSide: MissingSide = .right
    var calibration = CalibrationData()
    var session = SessionReport()
    var immersiveOpen = false
    /// Optional demo overlay of the intact side. Classic mirror therapy shows only the phantom.
    var showVirtualIntactHand = false
    var hideRealUpperLimbs = true

    /// When true, the report view presents the multi-step clinical intake
    /// sheet before showing the finalized report.
    var showingPostSessionIntake = false

    /// Calibration UI: whole-hand pose vs per-joint debug offsets.
    var calibrationTab: CalibrationTab = .pose
    /// Currently selected joint in the joint-debug list.
    var selectedJoint: HandSkeleton.JointName = .wrist
    /// Joint nudge step in meters (UI can change this).
    var jointOffsetStep: Float = CalibrationData.jointOffsetStep

    /// Live status for HUD.
    var trackingStatus: String = "Waiting for hand tracking…"
    var handUpdateIntervalMs: Double = 0
    var currentTaskIndex: Int = 0
    var taskInstruction: String = ""

    func nudgeSelectedJoint(axis: Int, delta: Float) {
        var next = calibration
        next.nudge(selectedJoint, axis: axis, delta: delta)
        calibration = next
    }

    func resetSelectedJointOffset() {
        var next = calibration
        next.setOffset(.zero, for: selectedJoint)
        calibration = next
    }

    func resetAllJointOffsets() {
        var next = calibration
        next.resetJointOffsets()
        calibration = next
    }

    /// Zero every offset for the joints in `group` (used by the per-finger reset button).
    func resetOffsets(in group: CalibrationData.JointGroup) {
        var next = calibration
        next.resetOffsets(in: group)
        calibration = next
    }

    func resetSession() {
        session = SessionReport()
        currentTaskIndex = 0
        taskInstruction = ""
        trackingStatus = "Waiting for hand tracking…"
        handUpdateIntervalMs = 0
    }

    func beginCalibration() {
        phase = .calibration
        immersiveOpen = true
    }

    func beginTraining() {
        let baselinePain = session.prePainNRS
        resetSession()
        session.startedAt = Date()
        session.prePainNRS = baselinePain
        phase = .training
        immersiveOpen = true
        currentTaskIndex = 0
    }

    /// Called from `TrainingHUD` when the user ends the session. Closes the
    /// immersive space, harvests objective motor metrics from the supplied
    /// `TaskManager`, and transitions to the report phase — the report view
    /// itself presents the clinical intake sheet on first appearance.
    func finishTraining(with tasks: TaskManager? = nil) {
        session.endedAt = Date()
        if let tasks {
            harvestMotorMetrics(from: tasks)
        }
        immersiveOpen = false
        phase = .report
        showingPostSessionIntake = true
    }

    /// Called from `PostSessionIntakeView` once the user finishes (or skips)
    /// the questionnaire. Persists the session to `SessionHistory` so it
    /// contributes to the trend chart on future report views.
    func submitPostSessionIntake() {
        showingPostSessionIntake = false
        SessionHistory.shared.append(session)
    }

    /// Read passive motor-sampling accumulators out of the `TaskManager`.
    private func harvestMotorMetrics(from tasks: TaskManager) {
        session.reachVolumeCm3 = tasks.reachVolumeCm3()
        session.motionSmoothness = tasks.motionSmoothness()
        session.perTaskDurationsSeconds = tasks.perTaskDurations()
    }

    func returnToOnboarding() {
        immersiveOpen = false
        showingPostSessionIntake = false
        phase = .onboarding
        resetSession()
    }
}
