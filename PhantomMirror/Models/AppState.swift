import Foundation
import SwiftUI
import simd

@MainActor
@Observable
final class AppState {
    enum Phase: String {
        case onboarding
        case calibration
        case training
        case report
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
    var showVirtualIntactHand = true
    var hideRealUpperLimbs = true

    /// Live status for HUD.
    var trackingStatus: String = "Waiting for hand tracking…"
    var handUpdateIntervalMs: Double = 0
    var currentTaskIndex: Int = 0
    var taskInstruction: String = ""

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

    func finishTraining() {
        session.endedAt = Date()
        immersiveOpen = false
        phase = .report
    }

    func returnToOnboarding() {
        immersiveOpen = false
        phase = .onboarding
        resetSession()
    }
}
