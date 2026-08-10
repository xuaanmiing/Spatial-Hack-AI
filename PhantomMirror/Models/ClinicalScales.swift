import Foundation

/// Clinical-grade assessment scales adapted for the PhantomMirror session report.
///
/// References
/// ----------
/// - Melzack R. "The Short-Form McGill Pain Questionnaire." Pain 30 (1987): 191-197.
/// - Bouhassira D. et al. "Comparison of pain syndromes associated with nervous
///   or somatic lesions and development of a new neuropathic pain diagnostic
///   questionnaire (DN4)." Pain 114 (2005): 29-36.
/// - Ramachandran V.S., Rogers-Ramachandran D. "Synaesthesia in phantom limbs
///   induced with mirrors." Proc R Soc Lond B 263 (1996): 377-386.
/// - Hsu E., Cohen S.P. "Postamputation pain: epidemiology, mechanisms, and
///   treatment." J Pain Res 6 (2013): 121-136.
/// - Chandler C.C. et al. "Targeted Brain Rehabilitation for phantom limb pain
///   in the upper extremity amputee population." J Hand Ther (2026).
/// - Lendaro E. et al. "Phantom Motor Execution as a treatment for phantom
///   limb pain: multicenter, double-blind RCT." BMJ Open (2018).
/// - Kilteni K., Groten R., Slater M. "The sense of embodiment in virtual
///   reality." Presence 21 (2012): 373-387.
enum ClinicalScales {

    // MARK: - ICD-10 Codes

    enum ICD10 {
        static let phantomWithPain = "G54.6"       // Phantom Limb Syndrome With Pain
        static let phantomWithoutPain = "G54.7"    // Phantom Limb Syndrome Without Pain
        static let title = "G54.6 · Phantom Limb Syndrome With Pain"
    }

    // MARK: - Short-Form McGill Pain Questionnaire (SF-MPQ)

    /// The 11 sensory descriptors from the SF-MPQ. Each rated 0-3.
    /// Maximum sensory sub-score = 33.
    static let sfMPQSensoryDescriptors: [String] = [
        "Throbbing",
        "Shooting",
        "Stabbing",
        "Sharp",
        "Cramping",
        "Gnawing",
        "Hot-burning",
        "Aching",
        "Heavy",
        "Tender",
        "Splitting"
    ]

    /// The 4 affective descriptors from the SF-MPQ. Each rated 0-3.
    /// Maximum affective sub-score = 12.
    static let sfMPQAffectiveDescriptors: [String] = [
        "Tiring-exhausting",
        "Sickening",
        "Fearful",
        "Punishing-cruel"
    ]

    static let sfMPQMaxSensory = 33
    static let sfMPQMaxAffective = 12
    static let sfMPQMaxTotal = 45

    // MARK: - Present Pain Intensity (PPI) verbal anchors — 0..5

    static let ppiAnchors: [String] = [
        "No pain",
        "Mild",
        "Discomforting",
        "Distressing",
        "Horrible",
        "Excruciating"
    ]

    // MARK: - DN4 Neuropathic Pain Screen

    /// The 4 patient-interview items of the DN4 questionnaire that can be
    /// self-reported (the full DN4 also has a clinician exam portion).
    /// Each Yes = 1 point. Score ≥ 4/10 is considered neuropathic-positive.
    static let dn4Questions: [String] = [
        "Does the pain have a burning quality?",
        "Painful cold sensation in the phantom / stump?",
        "Electric shocks in the affected area?",
        "Tingling, pins & needles, numbness or itching?"
    ]

    static let dn4PositiveThreshold = 4

    // MARK: - Phantom phenomena checklist (Hsu & Cohen 2013 categorization)

    static let phantomPhenomenaOptions: [String] = [
        "Telescoping (limb feels shorter over time)",
        "Kinetic sensations (perceived movement)",
        "Kinesthetic (perceived position / posture)",
        "Exteroceptive (touch, temperature, itch)"
    ]

    // MARK: - Latency thresholds for embodiment

    /// Motion-to-photon latency below which the sensorimotor coupling is
    /// generally sub-perceptual — supports the mirror-therapy illusion.
    /// Kilteni et al. summarize embodiment thresholds around 20–25 ms.
    static let subPerceptualLatencyMs: Double = 20.0
    static let acceptableLatencyMs: Double = 40.0

    // MARK: - Minimally Clinically Important Difference (MCID)

    /// A ≥30% reduction in NRS pain intensity is widely regarded as the
    /// minimum clinically meaningful improvement in chronic pain.
    static let mcidNRSReductionFraction: Double = 0.30

    // MARK: - Formatted reference list for the report footer

    static let referencesForReportFooter: [String] = [
        "Melzack R. Short-Form McGill Pain Questionnaire. Pain 30:191-197 (1987).",
        "Bouhassira D. et al. DN4 neuropathic pain screen. Pain 114:29-36 (2005).",
        "Ramachandran V.S., Rogers-Ramachandran D. Mirror therapy for phantom limbs. Proc R Soc B 263:377-386 (1996).",
        "Hsu E., Cohen S.P. Postamputation pain review. J Pain Res 6:121-136 (2013).",
        "Chandler C.C. et al. VR-based Targeted Brain Rehabilitation for PLP. J Hand Ther (2026).",
        "Lendaro E. et al. Phantom Motor Execution multicenter RCT (2018)."
    ]
}

// MARK: - SF-MPQ intensity descriptor

/// A single SF-MPQ descriptor selected during the intake, with its intensity.
struct SFMPQItem: Codable, Equatable, Hashable {
    enum Intensity: Int, Codable, CaseIterable, Identifiable {
        case none = 0
        case mild = 1
        case moderate = 2
        case severe = 3

        var id: Int { rawValue }

        var label: String {
            switch self {
            case .none: return "None"
            case .mild: return "Mild"
            case .moderate: return "Moderate"
            case .severe: return "Severe"
            }
        }
    }

    var descriptor: String
    var intensity: Intensity
}

// MARK: - Helper computations

extension ClinicalScales {

    /// Computes SF-MPQ sensory sub-score (0..33) from selected items.
    static func sensorySubscore(from items: [SFMPQItem]) -> Int {
        items
            .filter { sfMPQSensoryDescriptors.contains($0.descriptor) }
            .reduce(0) { $0 + $1.intensity.rawValue }
    }

    /// Computes SF-MPQ affective sub-score (0..12) from selected items.
    static func affectiveSubscore(from items: [SFMPQItem]) -> Int {
        items
            .filter { sfMPQAffectiveDescriptors.contains($0.descriptor) }
            .reduce(0) { $0 + $1.intensity.rawValue }
    }

    /// Returns the PPI verbal anchor for a 0..5 index.
    static func ppiLabel(for value: Int) -> String {
        let clamped = max(0, min(ppiAnchors.count - 1, value))
        return ppiAnchors[clamped]
    }

    /// Classifies system latency into a clinical-sounding embodiment category.
    static func latencyCategory(ms: Double) -> (label: String, isSubPerceptual: Bool) {
        if ms <= 0 { return ("Not measured", false) }
        if ms < subPerceptualLatencyMs {
            return ("Sub-perceptual (<20 ms)", true)
        } else if ms < acceptableLatencyMs {
            return ("Within tolerance", false)
        } else {
            return ("Above embodiment threshold", false)
        }
    }
}
