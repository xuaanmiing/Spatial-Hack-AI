import Foundation

/// Clinical-grade framing constants used by the PhantomMirror session report.
///
/// References
/// ----------
/// - Ramachandran V.S., Rogers-Ramachandran D. "Synaesthesia in phantom limbs
///   induced with mirrors." Proc R Soc Lond B 263 (1996): 377-386.
/// - Hsu E., Cohen S.P. "Postamputation pain: epidemiology, mechanisms, and
///   treatment." J Pain Res 6 (2013): 121-136.
/// - Kilteni K., Groten R., Slater M. "The sense of embodiment in virtual
///   reality." Presence 21 (2012): 373-387.
enum ClinicalScales {

    // MARK: - ICD-10 Codes

    enum ICD10 {
        static let phantomWithPain = "G54.6"       // Phantom Limb Syndrome With Pain
        static let phantomWithoutPain = "G54.7"    // Phantom Limb Syndrome Without Pain
        static let title = "G54.6 · Phantom Limb Syndrome With Pain"
    }

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
        "Ramachandran V.S., Rogers-Ramachandran D. Mirror therapy for phantom limbs. Proc R Soc B 263:377-386 (1996).",
        "Hsu E., Cohen S.P. Postamputation pain review. J Pain Res 6:121-136 (2013).",
        "Kilteni K., Groten R., Slater M. Sense of embodiment in VR. Presence 21:373-387 (2012)."
    ]

    // MARK: - Helper computations

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
