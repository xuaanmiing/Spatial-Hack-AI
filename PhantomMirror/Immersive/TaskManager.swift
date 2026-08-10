import Foundation
import RealityKit
import simd
import UIKit
import ARKit
import QuartzCore

@MainActor
@Observable
final class TaskManager {
    enum TaskKind: Int, CaseIterable, Identifiable {
        case openClose = 0
        case touchOrbs = 1
        case bimanual = 2

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .openClose: return "Open / Close"
            case .touchOrbs: return "Touch Orbs"
            case .bimanual: return "Bimanual Match"
            }
        }

        var instruction: String {
            switch self {
            case .openClose:
                return "Slowly open and close your intact hand. Watch the phantom hand mirror you."
            case .touchOrbs:
                return "Reach with the phantom hand and touch each glowing orb."
            case .bimanual:
                return "Use both hands: intact hand for the cyan cube, phantom hand for the amber cube — bring them together."
            }
        }
    }

    private(set) var current: TaskKind = .openClose
    private(set) var isComplete = false
    private(set) var progressText: String = ""
    private var phantomIsLeft = false

    // MARK: - Motor engagement sampling (passive)
    //
    // These are populated from phantom-hand palm samples emitted by
    // `ImmersiveView.processFrame`. They exist purely for the clinical
    // Motor Engagement section of the session report and do not influence
    // any task logic.

    /// Wall-clock time when each task began (indexed by TaskKind.rawValue).
    private var taskStartTimes: [Int: CFTimeInterval] = [:]
    /// Wall-clock time when each task completed (indexed by TaskKind.rawValue).
    private var taskEndTimes: [Int: CFTimeInterval] = [:]

    /// Axis-aligned bounding box of every sampled phantom-palm position.
    private var reachMin: SIMD3<Float>?
    private var reachMax: SIMD3<Float>?

    /// Ring buffer of recent phantom-palm samples for finite-difference
    /// derivatives (jerk).
    private struct PalmSample {
        let position: SIMD3<Float>
        let time: CFTimeInterval
    }
    private var palmSamples: [PalmSample] = []
    private let maxPalmSamples = 6

    /// Rolling average of jerk magnitude in m/s³. Lower = smoother motion.
    private var jerkSum: Double = 0
    private var jerkCount: Int = 0

    // Open/Close
    private var openCloseCycles = 0
    private var wasOpen = true
    private let openThreshold: Float = 0.11
    private let closeThreshold: Float = 0.06
    private let cyclesNeeded = 4

    // Touch orbs
    let orbRoot = Entity()
    private var orbs: [ModelEntity] = []
    private var orbsTouched = 0

    // Bimanual
    let cubeRoot = Entity()
    private var cyanCube: ModelEntity?
    private var amberCube: ModelEntity?
    private var cubesJoined = false

    func configure(phantomIsLeft: Bool) {
        self.phantomIsLeft = phantomIsLeft
    }

    func resetAll() {
        current = .openClose
        isComplete = false
        openCloseCycles = 0
        wasOpen = true
        orbsTouched = 0
        cubesJoined = false
        progressText = "Cycles: 0 / \(cyclesNeeded)"
        clearOrbs()
        clearCubes()
        resetMotorSampling()
    }

    func start(_ kind: TaskKind) {
        // Close out the previous task's timer if still open.
        markCurrentTaskEndedIfNeeded()

        current = kind
        isComplete = false
        taskStartTimes[kind.rawValue] = CACurrentMediaTime()
        switch kind {
        case .openClose:
            openCloseCycles = 0
            wasOpen = true
            progressText = "Cycles: 0 / \(cyclesNeeded)"
            clearOrbs()
            clearCubes()
        case .touchOrbs:
            orbsTouched = 0
            progressText = "Orbs: 0 / 3"
            spawnOrbs()
            clearCubes()
        case .bimanual:
            cubesJoined = false
            progressText = "Bring cubes together"
            clearOrbs()
            spawnCubes()
        }
    }

    func advanceIfPossible() -> Bool {
        let all = TaskKind.allCases
        guard let idx = all.firstIndex(of: current), idx + 1 < all.count else {
            isComplete = true
            markCurrentTaskEndedIfNeeded()
            return false
        }
        start(all[idx + 1])
        return true
    }

    // MARK: - Motor engagement sampling API

    /// Feed a single phantom-palm world position; called from the immersive
    /// per-frame loop. Updates the reach bounding box and jerk running mean.
    func recordPhantomPalmSample(_ position: SIMD3<Float>, at time: CFTimeInterval) {
        // Bounding box.
        if var lo = reachMin, var hi = reachMax {
            lo = SIMD3(min(lo.x, position.x), min(lo.y, position.y), min(lo.z, position.z))
            hi = SIMD3(max(hi.x, position.x), max(hi.y, position.y), max(hi.z, position.z))
            reachMin = lo
            reachMax = hi
        } else {
            reachMin = position
            reachMax = position
        }

        // Ring buffer for finite differences (need >=4 samples for jerk).
        palmSamples.append(PalmSample(position: position, time: time))
        if palmSamples.count > maxPalmSamples {
            palmSamples.removeFirst(palmSamples.count - maxPalmSamples)
        }

        guard palmSamples.count >= 4 else { return }
        let s = palmSamples.suffix(4)
        let a = s[s.startIndex]
        let b = s[s.index(after: s.startIndex)]
        let c = s[s.index(s.startIndex, offsetBy: 2)]
        let d = s[s.index(s.startIndex, offsetBy: 3)]

        let dt1 = Float(max(0.001, b.time - a.time))
        let dt2 = Float(max(0.001, c.time - b.time))
        let dt3 = Float(max(0.001, d.time - c.time))

        let v1 = (b.position - a.position) / dt1
        let v2 = (c.position - b.position) / dt2
        let v3 = (d.position - c.position) / dt3

        let acc1 = (v2 - v1) / dt2
        let acc2 = (v3 - v2) / dt3
        let jerk = simd_length((acc2 - acc1) / dt3)

        // Guard against nonsensical spikes from tracking glitches.
        if jerk.isFinite && jerk < 1000 {
            jerkSum += Double(jerk)
            jerkCount += 1
        }
    }

    /// Reach volume (cm³) of every sampled palm position — used by the report.
    func reachVolumeCm3() -> Double {
        guard let lo = reachMin, let hi = reachMax else { return 0 }
        let dx = Double(max(0, hi.x - lo.x)) * 100.0
        let dy = Double(max(0, hi.y - lo.y)) * 100.0
        let dz = Double(max(0, hi.z - lo.z)) * 100.0
        return dx * dy * dz
    }

    /// Motion smoothness 0..1 derived from mean jerk. A typical smooth
    /// reaching movement produces jerk on the order of a few m/s³ ; jerks
    /// >30 m/s³ dominate involuntary or highly non-smooth motion.
    func motionSmoothness() -> Double {
        guard jerkCount > 0 else { return 0 }
        let meanJerk = jerkSum / Double(jerkCount)
        // Sigmoid-ish map: 0 m/s³ → 1.0, 30 m/s³ → ~0.15.
        return max(0.0, min(1.0, 1.0 / (1.0 + meanJerk / 6.0)))
    }

    /// Per-task durations (seconds) in task-index order. Zero for tasks that
    /// never started; end-time falls back to `now` for tasks still open.
    func perTaskDurations() -> [Double] {
        let now = CACurrentMediaTime()
        return TaskKind.allCases.map { kind in
            guard let start = taskStartTimes[kind.rawValue] else { return 0 }
            let end = taskEndTimes[kind.rawValue] ?? now
            return max(0, end - start)
        }
    }

    /// Zero every motor-sampling accumulator (called from `resetAll`).
    private func resetMotorSampling() {
        taskStartTimes.removeAll()
        taskEndTimes.removeAll()
        reachMin = nil
        reachMax = nil
        palmSamples.removeAll()
        jerkSum = 0
        jerkCount = 0
    }

    private func markCurrentTaskEndedIfNeeded() {
        let key = current.rawValue
        if taskStartTimes[key] != nil && taskEndTimes[key] == nil {
            taskEndTimes[key] = CACurrentMediaTime()
        }
    }

    // MARK: - Updates

    func updateOpenClose(openness: Float?) {
        guard current == .openClose, let openness else { return }
        if wasOpen && openness < closeThreshold {
            wasOpen = false
        } else if !wasOpen && openness > openThreshold {
            wasOpen = true
            openCloseCycles += 1
            progressText = "Cycles: \(openCloseCycles) / \(cyclesNeeded)"
            if openCloseCycles >= cyclesNeeded {
                isComplete = true
                progressText = "Task complete ✓"
                markCurrentTaskEndedIfNeeded()
            }
        }
    }

    func updateTouchOrbs(phantomIndexTip: SIMD3<Float>?) {
        guard current == .touchOrbs, let tip = phantomIndexTip else { return }
        for orb in orbs where orb.isEnabled {
            let dist = simd_distance(tip, orb.position(relativeTo: nil))
            if dist < 0.04 {
                orb.isEnabled = false
                orbsTouched += 1
                progressText = "Orbs: \(orbsTouched) / 3"
                if orbsTouched >= 3 {
                    isComplete = true
                    progressText = "Task complete ✓"
                    markCurrentTaskEndedIfNeeded()
                }
            }
        }
    }

    func updateBimanual(intactTip: SIMD3<Float>?, phantomTip: SIMD3<Float>?) {
        guard current == .bimanual,
              let cyan = cyanCube,
              let amber = amberCube,
              !cubesJoined else { return }

        if let intact = intactTip {
            let d = simd_distance(intact, cyan.position(relativeTo: nil))
            if d < 0.05 {
                cyan.position = intact
            }
        }
        if let phantom = phantomTip {
            let d = simd_distance(phantom, amber.position(relativeTo: nil))
            if d < 0.05 {
                amber.position = phantom
            }
        }

        let separation = simd_distance(
            cyan.position(relativeTo: nil),
            amber.position(relativeTo: nil)
        )
        if separation < 0.06 {
            cubesJoined = true
            isComplete = true
            progressText = "Task complete ✓"
            markCurrentTaskEndedIfNeeded()
            cyan.model?.materials = [SimpleMaterial(color: .systemGreen, isMetallic: false)]
            amber.model?.materials = [SimpleMaterial(color: .systemGreen, isMetallic: false)]
        }
    }

    // MARK: - Spawning

    private func spawnOrbs() {
        clearOrbs()
        let side: Float = phantomIsLeft ? -1 : 1
        let positions: [SIMD3<Float>] = [
            SIMD3(side * 0.15, 1.2, -0.45),
            SIMD3(side * 0.28, 1.35, -0.35),
            SIMD3(side * 0.08, 1.45, -0.55)
        ]
        for (i, pos) in positions.enumerated() {
            let mat = SimpleMaterial(color: .systemOrange, roughness: 0.2, isMetallic: false)
            let orb = ModelEntity(
                mesh: .generateSphere(radius: 0.03),
                materials: [mat]
            )
            orb.name = "orb-\(i)"
            orb.position = pos
            orbRoot.addChild(orb)
            orbs.append(orb)
        }
    }

    private func clearOrbs() {
        for orb in orbs { orb.removeFromParent() }
        orbs.removeAll()
    }

    private func spawnCubes() {
        clearCubes()
        let phantomX: Float = phantomIsLeft ? -0.18 : 0.18
        let intactX = -phantomX
        let cyan = ModelEntity(
            mesh: .generateBox(size: 0.05, cornerRadius: 0.005),
            materials: [SimpleMaterial(color: .cyan, isMetallic: false)]
        )
        cyan.position = SIMD3(intactX, 1.2, -0.4)
        cyan.name = "cyanCube"

        let amber = ModelEntity(
            mesh: .generateBox(size: 0.05, cornerRadius: 0.005),
            materials: [SimpleMaterial(color: .systemOrange, isMetallic: false)]
        )
        amber.position = SIMD3(phantomX, 1.2, -0.4)
        amber.name = "amberCube"

        cubeRoot.addChild(cyan)
        cubeRoot.addChild(amber)
        cyanCube = cyan
        amberCube = amber
    }

    private func clearCubes() {
        cyanCube?.removeFromParent()
        amberCube?.removeFromParent()
        cyanCube = nil
        amberCube = nil
    }
}
