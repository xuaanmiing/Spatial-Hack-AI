import Foundation

struct SessionReport: Codable, Equatable {
    var startedAt: Date?
    var endedAt: Date?
    var prePainNRS: Int = 0
    var postPainNRS: Int = 0

    var framesTracked: Int = 0
    var framesLost: Int = 0
    var tasksCompleted: Int = 0
    var totalTasks: Int = 3
    var averageLatencyMs: Double = 0

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
