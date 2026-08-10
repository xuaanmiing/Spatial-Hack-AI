import Foundation
import SwiftUI
import simd
import ARKit

@MainActor
@Observable
final class AppState {
    private static let savedCalibrationKey = "PhantomMirror.savedCalibration.v3"
    private static let savedMissingSideKey = "PhantomMirror.savedMissingSide.v1"

    enum Phase: String {
        case welcome
        case onboarding
        case calibration
        case training
        case playground
        case report
    }

    enum CalibrationTab: String, CaseIterable, Identifiable {
        case pose
        case skin
        case joints

        var id: String { rawValue }

        var title: String {
            switch self {
            case .pose: return "Pose"
            case .skin: return "Skin Rig"
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

    var phase: Phase = .welcome
    var missingSide: MissingSide = .right {
        didSet {
            UserDefaults.standard.set(missingSide.rawValue, forKey: Self.savedMissingSideKey)
        }
    }
    var calibration = CalibrationData() {
        didSet {
            var saved = calibration
            // A binding reference belongs to one ARKit session and cannot be
            // restored safely, but all visual alignment values can be.
            saved.skinAlignmentConfirmed = false
            if let data = try? JSONEncoder().encode(saved) {
                UserDefaults.standard.set(data, forKey: Self.savedCalibrationKey)
            }
        }
    }
    var session = SessionReport()
    var immersiveOpen = false
    private(set) var immersiveSessionID = 0
    /// Optional demo overlay of the intact side. Classic mirror therapy shows only the phantom.
    var showVirtualIntactHand = false
    /// When false, real hands stay visible and composite above virtual props.
    var hideRealUpperLimbs = false

    /// Calibration UI: whole-hand pose vs per-joint debug offsets.
    var calibrationTab: CalibrationTab = .pose
    /// Currently selected joint in the joint-debug list.
    var selectedJoint: HandSkeleton.JointName = .wrist
    /// Joint nudge step in meters (UI can change this).
    var jointOffsetStep: Float = CalibrationData.jointOffsetStep
    var skinTranslationStep: Float = 0.10
    var skinRotationStepDegrees: Float = 5

    /// Live status for HUD.
    var trackingStatus: String = "Waiting for hand tracking…"
    var handUpdateIntervalMs: Double = 0
    var currentTaskIndex: Int = 0
    var taskInstruction: String = ""

    init() {
        let defaults = UserDefaults.standard
        if let rawSide = defaults.string(forKey: Self.savedMissingSideKey),
           let restoredSide = MissingSide(rawValue: rawSide) {
            missingSide = restoredSide
        }
        if let data = defaults.data(forKey: Self.savedCalibrationKey),
           var restored = try? JSONDecoder().decode(CalibrationData.self, from: data) {
            restored.migrateSkinTranslationPresetIfNeeded()
            restored.skinAlignmentConfirmed = false
            calibration = restored
        }
    }

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

    func resetSkinAlignment() {
        var next = calibration
        next.resetSkinAlignment()
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
        requestImmersiveOpen()
    }

    func beginTraining() {
        let baselinePain = session.prePainNRS
        resetSession()
        session.startedAt = Date()
        session.prePainNRS = baselinePain
        session.totalTasks = TaskManager.TaskKind.allCases.count
        phase = .training
        requestImmersiveOpen()
        currentTaskIndex = 0
    }

    func finishTraining() {
        session.endedAt = Date()
        phase = .report
        immersiveOpen = false
    }

    /// Free-play brick builder — separate from the training session sequence.
    func beginPlayground() {
        taskInstruction = ""
        trackingStatus = "Opening brick playground…"
        phase = .playground
        requestImmersiveOpen()
    }

    func endPlayground() {
        immersiveOpen = false
        phase = .onboarding
        taskInstruction = ""
        trackingStatus = "Waiting for hand tracking…"
    }

    func returnToOnboarding() {
        phase = .onboarding
        immersiveOpen = false
        resetSession()
    }

    private func requestImmersiveOpen() {
        if !immersiveOpen {
            immersiveSessionID += 1
            var next = calibration
            next.skinAlignmentConfirmed = false
            calibration = next
        }
        immersiveOpen = true
    }
}
