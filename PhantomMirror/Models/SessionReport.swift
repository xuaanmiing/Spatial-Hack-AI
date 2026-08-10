import Foundation

/// Session-level record for one training session.
///
/// The struct is fully `Codable` so it can be persisted to disk (see
/// `SessionHistory`) and rehydrated for the trend chart on `ReportView`.
///
/// Every clinical field is optional-defaulted so older saved sessions decode
/// without loss when the schema is extended.
struct SessionReport: Codable, Equatable, Identifiable {

    // MARK: - Identity

    var id: UUID = UUID()

    // MARK: - Timing

    var startedAt: Date?
    var endedAt: Date?

    // MARK: - Pain intensity (NRS 0..10)

    /// Baseline pain before the session (recorded during onboarding).
    var prePainNRS: Int = 0
    /// Post-session pain, recorded during the intake sheet.
    var postPainNRS: Int = 0

    /// Patient-reported pain-relief rating (0..10) collected in the single
    /// post-session question. 0 = no relief, 10 = complete relief.
    var painReliefRating: Int = 0

    // MARK: - Engineering / tracking

    var framesTracked: Int = 0
    var framesLost: Int = 0
    var tasksCompleted: Int = 0
    var totalTasks: Int = 3
    var averageHandUpdateIntervalMs: Double = 0

    // MARK: - Objective motor metrics (computed from ARKit trajectories)

    /// Per-task completion time in seconds. Zero-length entry means the task
    /// was started but not marked complete.
    var perTaskDurationsSeconds: [Double] = []
    /// Phantom-hand reach volume in cubic centimetres — bounding-box size of
    /// all sampled palm positions during the training portion of the session.
    var reachVolumeCm3: Double = 0
    /// Motion smoothness 0..1 derived from average jerk of phantom palm.
    /// Higher = smoother.
    var motionSmoothness: Double = 0

    // MARK: - Intake status

    /// True once the post-session intake sheet has been submitted.
    /// Report view can degrade gracefully when this is false.
    var intakeCompleted: Bool = false

    // MARK: - Derived helpers

    var durationSeconds: TimeInterval {
        guard let start = startedAt else { return 0 }
        let end = endedAt ?? Date()
        return max(0, end.timeIntervalSince(start))
    }

    var trackingSuccessRate: Double {
        let total = framesTracked + framesLost
        guard total > 0 else { return 0 }
        return Double(framesTracked) / Double(total)
    }

    /// Change in current NRS pain between pre and post-session (negative =
    /// improvement). Derived from `painReliefRating` when the pre-session
    /// baseline was set, otherwise 0.
    var nrsDelta: Int { postPainNRS - prePainNRS }

    /// Percentage change in NRS pain (0.0 baseline returns 0).
    var nrsDeltaFraction: Double {
        guard prePainNRS > 0 else { return 0 }
        return Double(postPainNRS - prePainNRS) / Double(prePainNRS)
    }

    /// True when the session met the ≥30% NRS-reduction MCID threshold.
    var meetsMCID: Bool {
        prePainNRS > 0 && (-nrsDeltaFraction) >= ClinicalScales.mcidNRSReductionFraction
    }

    /// Average per-task completion time (seconds) — 0 if no tasks recorded.
    var averageTaskDurationSeconds: Double {
        let nonzero = perTaskDurationsSeconds.filter { $0 > 0 }
        guard !nonzero.isEmpty else { return 0 }
        return nonzero.reduce(0, +) / Double(nonzero.count)
    }

    /// Composite motor engagement score 0..100 combining reach volume,
    /// smoothness, task completion rate and tracking quality. Designed so
    /// that a fully engaged session with clean tracking lands in the high
    /// 70s / low 80s.
    var motorEngagementScore: Int {
        // Reach volume: 30k cm³ ≈ full 60 cm-cube of exploration.
        let volumeComponent = min(1.0, reachVolumeCm3 / 30_000.0)
        let smoothnessComponent = max(0.0, min(1.0, motionSmoothness))
        let taskComponent = totalTasks > 0
            ? min(1.0, Double(tasksCompleted) / Double(totalTasks))
            : 0
        let trackingComponent = min(1.0, trackingSuccessRate)

        let weighted =
            volumeComponent * 0.25 +
            smoothnessComponent * 0.25 +
            taskComponent * 0.30 +
            trackingComponent * 0.20

        return Int((weighted * 100).rounded())
    }
}
