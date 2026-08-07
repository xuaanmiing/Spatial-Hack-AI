import Foundation
import RealityKit
import simd
import UIKit
import ARKit

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
    }

    func start(_ kind: TaskKind) {
        current = kind
        isComplete = false
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
            return false
        }
        start(all[idx + 1])
        return true
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
