import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

struct SessionReport: Codable, Equatable {
    var startedAt: Date?
    var endedAt: Date?
    var prePainNRS: Int = 0
    var postPainNRS: Int = 0

    var framesTracked: Int = 0
    var framesLost: Int = 0
    var tasksCompleted: Int = 0
    var totalTasks: Int = 5
    var averageHandUpdateIntervalMs: Double = 0
    var clinicalNote: String = ""
    var clinicalNoteUsesOnDeviceModel = false

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
}

enum ClinicalNoteGenerator {
    struct Result {
        let text: String
        let usedOnDeviceModel: Bool
    }

    static func generate(from report: SessionReport) async -> Result {
        let fallback = fallbackText(for: report)

        #if canImport(FoundationModels)
        if #available(visionOS 26.0, *) {
            let model = SystemLanguageModel.default
            guard model.availability == .available,
                  model.supportsLocale(Locale(identifier: "en_US")) else {
                return Result(text: fallback, usedOnDeviceModel: false)
            }

            let instructions = """
            Write one concise training report for a Clinical Note card in neutral English.
            Use 4 to 6 complete sentences and 90 to 130 words, with no heading or bullet list.
            First summarize completion, duration, tracking, latency, and pain ratings.
            Then praise one or two strengths only when supported by the measurements.
            End with one or two practical next-session focus areas, such as steadier pacing,
            completing remaining activities, or keeping the tracked hand in sensor view.
            Keep suggestions operational and encouraging. Do not diagnose, prescribe treatment,
            infer causes, promise outcomes, label patient compliance, or invent information.
            """
            let prompt = """
            Duration: \(Int(report.durationSeconds.rounded())) seconds
            Activities completed: \(report.tasksCompleted) of \(report.totalTasks)
            Tracking availability: \(Int((report.trackingSuccessRate * 100).rounded())) percent
            Average hand-update interval: \(Int(report.averageHandUpdateIntervalMs.rounded())) milliseconds
            Tracking interruptions: \(report.framesLost)
            Pre-session pain rating: \(report.prePainNRS) of 10
            Post-session pain rating: \(report.postPainNRS) of 10
            """

            do {
                let session = LanguageModelSession(model: model, instructions: instructions)
                let response = try await session.respond(to: prompt)
                let note = cleaned(response.content)
                if !note.isEmpty {
                    return Result(text: note, usedOnDeviceModel: true)
                }
            } catch {
                // The report must remain available even when the system model is busy.
            }
        }
        #endif

        return Result(text: fallback, usedOnDeviceModel: false)
    }

    static func fallbackText(for report: SessionReport) -> String {
        let duration = Int(report.durationSeconds.rounded())
        let tracking = Int((report.trackingSuccessRate * 100).rounded())
        let latency = Int(report.averageHandUpdateIntervalMs.rounded())
        let completedAll = report.totalTasks > 0
            && report.tasksCompleted >= report.totalTasks

        var sentences = [
            "The session lasted \(duration) seconds, with \(report.tasksCompleted) of \(report.totalTasks) planned activities completed.",
            "Hand tracking was available for \(tracking)% of recorded updates, with a \(latency) ms average update interval and \(report.framesLost) recorded interruptions."
        ]

        if completedAll && tracking >= 90 {
            sentences.append("Completing the full activity set while maintaining stable tracking was a clear strength in this session.")
        } else if completedAll {
            sentences.append("Completion of the full activity set was a positive result despite periods of tracking interruption.")
        } else if tracking >= 90 {
            sentences.append("Stable hand visibility was a positive foundation for continued practice.")
        } else {
            sentences.append("The recorded activity provides a useful baseline for improving continuity in the next session.")
        }

        if report.postPainNRS < report.prePainNRS {
            sentences.append("Reported pain was lower after the session, changing from \(report.prePainNRS)/10 to \(report.postPainNRS)/10.")
        } else if report.postPainNRS > report.prePainNRS {
            sentences.append("Reported pain increased from \(report.prePainNRS)/10 before the session to \(report.postPainNRS)/10 afterward and should be noted when planning the next session.")
        } else {
            sentences.append("Reported pain was unchanged at \(report.prePainNRS)/10 before and after the session.")
        }

        if tracking < 90 {
            sentences.append("For the next session, focus on keeping the tracked hand within sensor view and using steady, controlled movements to reduce interruptions.")
        } else if !completedAll {
            sentences.append("For the next session, maintain the same tracking consistency while progressing through the remaining activities at a steady pace.")
        } else {
            sentences.append("The next goal is to preserve this completion and tracking consistency while making each movement smooth and deliberate.")
        }

        return sentences.joined(separator: " ")
    }

    private static func cleaned(_ text: String) -> String {
        let singleLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        return String(singleLine.prefix(1_200))
    }
}
