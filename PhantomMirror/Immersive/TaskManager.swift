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
        case touchOrbs = 0
        case bimanual = 1
        case clapHands = 2
        case sliceHorizontal = 3
        case sliceVertical = 4

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .touchOrbs: return "Touch Orbs"
            case .bimanual: return "Bimanual Match"
            case .clapHands: return "Clap Hands"
            case .sliceHorizontal: return "Horizontal Slice"
            case .sliceVertical: return "Vertical Slice"
            }
        }

        var instruction: String {
            switch self {
            case .touchOrbs:
                return "Reach with the phantom hand and touch each glowing orb."
            case .bimanual:
                return "Pinch each cube with thumb + index + middle (intact = cyan, phantom = amber), then bring them together."
            case .clapHands:
                return "Clap your intact hand and phantom hand together 5 times."
            case .sliceHorizontal:
                return "Swipe your phantom hand sideways through the block to cut it horizontally."
            case .sliceVertical:
                return "Swipe your phantom hand up or down through the block to cut it vertically."
            }
        }
    }

    private(set) var current: TaskKind = .touchOrbs
    private(set) var isComplete = false
    private(set) var progressText: String = ""
    /// Increments whenever a task reaches completion (drives celebration FX).
    private(set) var celebrationTrigger: Int = 0
    private var phantomIsLeft = false
    /// Latest head pose used to place task props in front of the user (not at world origin).
    private var referenceHeadPose: simd_float4x4?
    weak var audio: AudioFeedback?

    // Touch orbs
    let orbRoot = Entity()
    private var orbs: [ModelEntity] = []
    private var orbBasePositions: [String: SIMD3<Float>] = [:]
    private var orbTouchedAt: [String: CFTimeInterval] = [:]
    private var orbsTouched = 0
    private let orbRadius: Float = 0.03
    private let handVolumeRadius: Float = 0.035
    private let orbVibrationDuration: CFTimeInterval = 0.28

    private static let contactBonePairs: [(HandSkeleton.JointName, HandSkeleton.JointName)] = [
        (.wrist, .forearmWrist),
        (.forearmWrist, .forearmArm),
        (.thumbKnuckle, .wrist),
        (.thumbIntermediateBase, .thumbKnuckle),
        (.thumbIntermediateTip, .thumbIntermediateBase),
        (.thumbTip, .thumbIntermediateTip),
        (.indexFingerMetacarpal, .wrist),
        (.indexFingerKnuckle, .indexFingerMetacarpal),
        (.indexFingerIntermediateBase, .indexFingerKnuckle),
        (.indexFingerIntermediateTip, .indexFingerIntermediateBase),
        (.indexFingerTip, .indexFingerIntermediateTip),
        (.middleFingerMetacarpal, .wrist),
        (.middleFingerKnuckle, .middleFingerMetacarpal),
        (.middleFingerIntermediateBase, .middleFingerKnuckle),
        (.middleFingerIntermediateTip, .middleFingerIntermediateBase),
        (.middleFingerTip, .middleFingerIntermediateTip),
        (.ringFingerMetacarpal, .wrist),
        (.ringFingerKnuckle, .ringFingerMetacarpal),
        (.ringFingerIntermediateBase, .ringFingerKnuckle),
        (.ringFingerIntermediateTip, .ringFingerIntermediateBase),
        (.ringFingerTip, .ringFingerIntermediateTip),
        (.littleFingerMetacarpal, .wrist),
        (.littleFingerKnuckle, .littleFingerMetacarpal),
        (.littleFingerIntermediateBase, .littleFingerKnuckle),
        (.littleFingerIntermediateTip, .littleFingerIntermediateBase),
        (.littleFingerTip, .littleFingerIntermediateTip)
    ]

    // Bimanual
    let cubeRoot = Entity()
    private var cyanCube: ModelEntity?
    private var amberCube: ModelEntity?
    private var cubesJoined = false
    private var cyanGrabbed = false
    private var amberGrabbed = false
    private let cubeHalfSize: Float = 0.04
    /// Loose contact radius so three-finger pinch is easy to trigger on device.
    private let fingertipContactRadius: Float = 0.055
    /// Once grabbed, keep holding until tips move farther away (hysteresis).
    private let fingertipHoldRadius: Float = 0.11
    private let cubeJoinDistance: Float = 0.10
    /// Each finger can touch with tip or near-tip joint.
    private static let pinchFingers: [[HandSkeleton.JointName]] = [
        [.thumbTip, .thumbIntermediateTip],
        [.indexFingerTip, .indexFingerIntermediateTip],
        [.middleFingerTip, .middleFingerIntermediateTip]
    ]

    // Clap hands
    private var clapCount = 0
    private var clapIsClosed = false
    private let clapTargetCount = 5
    private let clapDistanceThreshold: Float = 0.085
    /// Palms must separate past this before the next clap can register.
    private let clapReopenDistance: Float = 0.14

    // Slice blocks
    let sliceRoot = Entity()
    private var sliceBlock: ModelEntity?
    private var sliceHalfA: ModelEntity?
    private var sliceHalfB: ModelEntity?
    private var previousPalmCenter: SIMD3<Float>?
    private var previousSampleTime: CFTimeInterval?
    private var sliceBlockCenter = SIMD3<Float>.zero
    private let sliceBlockHalfSize: Float = 0.07
    private let sliceMinSpeed: Float = 0.22

    func configure(phantomIsLeft: Bool, headPose: simd_float4x4? = nil) {
        self.phantomIsLeft = phantomIsLeft
        if let headPose {
            referenceHeadPose = headPose
        }
    }

    func updateReferenceHeadPose(_ headPose: simd_float4x4) {
        referenceHeadPose = headPose
    }

    private func place(right: Float, up: Float, forward: Float) -> SIMD3<Float> {
        if let head = referenceHeadPose {
            return MirrorTransform.pointRelativeToHead(head, right: right, up: up, forward: forward)
        }
        // Fallback for preview without head tracking.
        return SIMD3(right, 1.25 + up, -forward)
    }

    /// Comfortable arm-reach band: centered in front of the user.
    private enum ReachableSpawn {
        static let forward: Float = 0.50
        /// Less below eye level so props stay in view without looking down.
        static let handHeight: Float = -0.18
    }

    /// Removes all spawned training props. Call when leaving training / immersive space
    /// so orbs/cubes/blocks don't linger into the next calibration session.
    func clearSceneProps() {
        clearOrbs()
        clearCubes()
        clearSliceBlock()
        previousPalmCenter = nil
        previousSampleTime = nil
    }

    func resetAll() {
        current = .touchOrbs
        isComplete = false
        orbsTouched = 0
        cubesJoined = false
        cyanGrabbed = false
        amberGrabbed = false
        clapCount = 0
        clapIsClosed = false
        previousPalmCenter = nil
        previousSampleTime = nil
        celebrationTrigger = 0
        progressText = "Orbs: 0 / 3"
        clearSceneProps()
    }

    func start(_ kind: TaskKind) {
        current = kind
        isComplete = false
        switch kind {
        case .touchOrbs:
            orbsTouched = 0
            progressText = "Orbs: 0 / 3"
            spawnOrbs()
            clearCubes()
            clearSliceBlock()
        case .bimanual:
            cubesJoined = false
            cyanGrabbed = false
            amberGrabbed = false
            progressText = "Cyan: open  ·  Amber: open"
            clearOrbs()
            clearSliceBlock()
            spawnCubes()
        case .clapHands:
            clapCount = 0
            clapIsClosed = false
            progressText = "Claps: 0 / \(clapTargetCount)"
            clearOrbs()
            clearCubes()
            clearSliceBlock()
        case .sliceHorizontal:
            previousPalmCenter = nil
            previousSampleTime = nil
            progressText = "Swipe sideways through the block"
            clearOrbs()
            clearCubes()
            spawnSliceBlock()
        case .sliceVertical:
            previousPalmCenter = nil
            previousSampleTime = nil
            progressText = "Swipe up/down through the block"
            clearOrbs()
            clearCubes()
            spawnSliceBlock()
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

    func updateTouchOrbs(phantomWorld: [HandSkeleton.JointName: simd_float4x4]) {
        guard current == .touchOrbs, !phantomWorld.isEmpty else { return }
        let now = CACurrentMediaTime()

        for orb in orbs where orb.isEnabled {
            if let touchedAt = orbTouchedAt[orb.name] {
                animateTouchedOrb(orb, touchedAt: touchedAt, now: now)
                continue
            }

            let center = orb.position(relativeTo: nil)
            if handVolumeIntersectsOrb(phantomWorld: phantomWorld, orbCenter: center) {
                orbTouchedAt[orb.name] = now
                orbsTouched += 1
                progressText = "Orbs: \(orbsTouched) / 3"
                orb.model?.materials = [UnlitMaterial(color: .systemYellow)]
                animateTouchedOrb(orb, touchedAt: now, now: now)
                audio?.play(.orbTouch)
                if orbsTouched >= 3 {
                    markComplete()
                }
            }
        }
    }

    private func animateTouchedOrb(_ orb: ModelEntity, touchedAt: CFTimeInterval, now: CFTimeInterval) {
        let elapsed = now - touchedAt
        guard elapsed < orbVibrationDuration else {
            orb.isEnabled = false
            return
        }

        let base = orbBasePositions[orb.name] ?? orb.position
        let decay = Float(1 - elapsed / orbVibrationDuration)
        let shake = sinf(Float(elapsed) * 95) * 0.012 * decay
        orb.position = base + SIMD3(shake, -shake * 0.45, shake * 0.25)
        orb.scale = SIMD3(repeating: 1 + 0.35 * decay)
    }

    private func handVolumeIntersectsOrb(
        phantomWorld: [HandSkeleton.JointName: simd_float4x4],
        orbCenter: SIMD3<Float>
    ) -> Bool {
        let threshold = orbRadius + handVolumeRadius

        for transform in phantomWorld.values {
            if simd_distance(transform.translation, orbCenter) <= threshold {
                return true
            }
        }

        for (child, parent) in Self.contactBonePairs {
            guard let a = phantomWorld[parent]?.translation,
                  let b = phantomWorld[child]?.translation else { continue }
            if distanceFromPoint(orbCenter, toSegmentFrom: a, to: b) <= threshold {
                return true
            }
        }

        return false
    }

    private func distanceFromPoint(
        _ point: SIMD3<Float>,
        toSegmentFrom a: SIMD3<Float>,
        to b: SIMD3<Float>
    ) -> Float {
        let ab = b - a
        let lengthSquared = simd_length_squared(ab)
        guard lengthSquared > 0.000001 else {
            return simd_distance(point, a)
        }

        let t = max(0, min(1, simd_dot(point - a, ab) / lengthSquared))
        let closest = a + ab * t
        return simd_distance(point, closest)
    }

    func updateBimanual(
        intactWorld: [HandSkeleton.JointName: simd_float4x4],
        phantomWorld: [HandSkeleton.JointName: simd_float4x4]
    ) {
        guard current == .bimanual,
              let cyan = cyanCube,
              let amber = amberCube,
              !cubesJoined else { return }

        let cyanCenter = cyan.position(relativeTo: nil)
        let amberCenter = amber.position(relativeTo: nil)

        let cyanContact = pinchContactCount(world: intactWorld, cubeCenter: cyanCenter, holding: cyanGrabbed)
        let amberContact = pinchContactCount(world: phantomWorld, cubeCenter: amberCenter, holding: amberGrabbed)

        if let grip = pinchGripCenter(world: intactWorld, cubeCenter: cyanCenter, holding: cyanGrabbed) {
            if !cyanGrabbed {
                cyanGrabbed = true
                audio?.play(.cubeGrab)
            }
            cyan.position = grip
        } else if cyanGrabbed {
            cyanGrabbed = false
        }

        if let grip = pinchGripCenter(world: phantomWorld, cubeCenter: amberCenter, holding: amberGrabbed) {
            if !amberGrabbed {
                amberGrabbed = true
                audio?.play(.cubeGrab)
            }
            amber.position = grip
        } else if amberGrabbed {
            amberGrabbed = false
        }

        progressText =
            "Cyan: \(cyanGrabbed ? "holding" : "\(cyanContact)/3")  ·  Amber: \(amberGrabbed ? "holding" : "\(amberContact)/3")"

        let separation = simd_distance(
            cyan.position(relativeTo: nil),
            amber.position(relativeTo: nil)
        )
        if cyanGrabbed && amberGrabbed && separation < cubeJoinDistance {
            cubesJoined = true
            markComplete()
            cyan.model?.materials = [SimpleMaterial(color: .systemGreen, isMetallic: false)]
            amber.model?.materials = [SimpleMaterial(color: .systemGreen, isMetallic: false)]
        }
    }

    /// Requires thumb, index, and middle all near the cube (tip or near-tip joint).
    private func pinchGripCenter(
        world: [HandSkeleton.JointName: simd_float4x4],
        cubeCenter: SIMD3<Float>,
        holding: Bool
    ) -> SIMD3<Float>? {
        let radius = holding ? fingertipHoldRadius : fingertipContactRadius
        var tips: [SIMD3<Float>] = []
        tips.reserveCapacity(Self.pinchFingers.count)

        for joints in Self.pinchFingers {
            guard let tip = closestFingerPoint(joints: joints, world: world, cubeCenter: cubeCenter),
                  fingertipTouchesCube(tip, cubeCenter: cubeCenter, radius: radius) else {
                return nil
            }
            tips.append(tip)
        }

        let sum = tips.reduce(SIMD3<Float>.zero, +)
        return sum / Float(tips.count)
    }

    private func pinchContactCount(
        world: [HandSkeleton.JointName: simd_float4x4],
        cubeCenter: SIMD3<Float>,
        holding: Bool
    ) -> Int {
        let radius = holding ? fingertipHoldRadius : fingertipContactRadius
        var count = 0
        for joints in Self.pinchFingers {
            if let tip = closestFingerPoint(joints: joints, world: world, cubeCenter: cubeCenter),
               fingertipTouchesCube(tip, cubeCenter: cubeCenter, radius: radius) {
                count += 1
            }
        }
        return count
    }

    private func closestFingerPoint(
        joints: [HandSkeleton.JointName],
        world: [HandSkeleton.JointName: simd_float4x4],
        cubeCenter: SIMD3<Float>
    ) -> SIMD3<Float>? {
        var best: SIMD3<Float>?
        var bestDistance = Float.greatestFiniteMagnitude
        for joint in joints {
            guard let tip = world[joint]?.translation else { continue }
            let distance = distanceToCubeSurface(tip, cubeCenter: cubeCenter)
            if distance < bestDistance {
                bestDistance = distance
                best = tip
            }
        }
        return best
    }

    private func fingertipTouchesCube(
        _ tip: SIMD3<Float>,
        cubeCenter: SIMD3<Float>,
        radius: Float
    ) -> Bool {
        distanceToCubeSurface(tip, cubeCenter: cubeCenter) <= radius
    }

    private func distanceToCubeSurface(_ tip: SIMD3<Float>, cubeCenter: SIMD3<Float>) -> Float {
        let local = tip - cubeCenter
        let closestOnCube = SIMD3(
            max(-cubeHalfSize, min(cubeHalfSize, local.x)),
            max(-cubeHalfSize, min(cubeHalfSize, local.y)),
            max(-cubeHalfSize, min(cubeHalfSize, local.z))
        )
        return simd_distance(local, closestOnCube)
    }

    func updateClapHands(
        intactWorld: [HandSkeleton.JointName: simd_float4x4],
        phantomWorld: [HandSkeleton.JointName: simd_float4x4]
    ) {
        guard current == .clapHands,
              !isComplete,
              let intactPalm = palmCenter(from: intactWorld),
              let phantomPalm = palmCenter(from: phantomWorld) else { return }

        let distance = simd_distance(intactPalm, phantomPalm)

        if clapIsClosed {
            if distance >= clapReopenDistance {
                clapIsClosed = false
            }
        } else if distance <= clapDistanceThreshold {
            clapIsClosed = true
            clapCount += 1
            audio?.play(.clap)
            progressText = "Claps: \(clapCount) / \(clapTargetCount)"
            if clapCount >= clapTargetCount {
                markComplete()
                return
            }
        }

        if !isComplete {
            progressText = String(
                format: "Claps: %d / %d  ·  %.0f cm",
                clapCount,
                clapTargetCount,
                distance * 100
            )
        }
    }

    func updateSliceBlocks(phantomWorld: [HandSkeleton.JointName: simd_float4x4]) {
        guard (current == .sliceHorizontal || current == .sliceVertical),
              !isComplete,
              let palm = palmCenter(from: phantomWorld) else { return }

        let now = CACurrentMediaTime()
        defer {
            previousPalmCenter = palm
            previousSampleTime = now
        }

        guard let previous = previousPalmCenter,
              let previousTime = previousSampleTime else { return }

        let dt = Float(max(0.001, now - previousTime))
        let velocity = (palm - previous) / dt
        let speed = simd_length(velocity)
        guard speed >= sliceMinSpeed else {
            progressText = current == .sliceHorizontal
                ? String(format: "Swipe sideways · %.0f cm/s", speed * 100)
                : String(format: "Swipe up/down · %.0f cm/s", speed * 100)
            return
        }

        let blockBounds = sliceBlockHalfSize * 1.35
        let local = palm - sliceBlockCenter
        let insideBlock = abs(local.x) <= blockBounds
            && abs(local.y) <= blockBounds
            && abs(local.z) <= blockBounds
        guard insideBlock else { return }

        let horizontalMotion = abs(velocity.x) + abs(velocity.z)
        let verticalMotion = abs(velocity.y)

        switch current {
        case .sliceHorizontal:
            guard horizontalMotion > verticalMotion * 1.05,
                  horizontalMotion > sliceMinSpeed * 0.75 else { return }
            applyHorizontalSlice()
            audio?.play(.slice)
            markComplete()
        case .sliceVertical:
            guard verticalMotion > horizontalMotion * 1.05,
                  verticalMotion > sliceMinSpeed * 0.75 else { return }
            applyVerticalSlice()
            audio?.play(.slice)
            markComplete()
        default:
            break
        }
    }

    private func palmCenter(from worldTransforms: [HandSkeleton.JointName: simd_float4x4]) -> SIMD3<Float>? {
        let palmJoints: [HandSkeleton.JointName] = [
            .wrist,
            .indexFingerMetacarpal,
            .middleFingerMetacarpal,
            .ringFingerMetacarpal,
            .littleFingerMetacarpal
        ]

        var sum = SIMD3<Float>.zero
        var count: Float = 0
        for joint in palmJoints {
            guard let transform = worldTransforms[joint] else { continue }
            sum += transform.translation
            count += 1
        }
        guard count > 0 else { return nil }
        return sum / count
    }

    // MARK: - Spawning

    private func spawnOrbs() {
        clearOrbs()
        // Spread across phantom-side reach space (near / high / far) so they don't overlap.
        let side: Float = phantomIsLeft ? -1 : 1
        let h = ReachableSpawn.handHeight
        let positions: [SIMD3<Float>] = [
            place(right: side * 0.10, up: h - 0.08, forward: 0.40),
            place(right: side * 0.30, up: h + 0.12, forward: 0.50),
            place(right: side * 0.18, up: h + 0.02, forward: 0.65)
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
            orbBasePositions[orb.name] = pos
        }
    }

    private func clearOrbs() {
        for orb in orbs { orb.removeFromParent() }
        orbs.removeAll()
        orbBasePositions.removeAll()
        orbTouchedAt.removeAll()
    }

    private func spawnCubes() {
        clearCubes()
        // Keep both cubes in easy reach, split left/right of center-front.
        let phantomX: Float = phantomIsLeft ? -0.12 : 0.12
        let intactX = -phantomX
        let cubeSize = cubeHalfSize * 2
        let cyan = ModelEntity(
            mesh: .generateBox(size: cubeSize, cornerRadius: 0.006),
            materials: [SimpleMaterial(color: .cyan, isMetallic: false)]
        )
        cyan.position = place(right: intactX, up: ReachableSpawn.handHeight, forward: ReachableSpawn.forward)
        cyan.name = "cyanCube"

        let amber = ModelEntity(
            mesh: .generateBox(size: cubeSize, cornerRadius: 0.006),
            materials: [SimpleMaterial(color: .systemOrange, isMetallic: false)]
        )
        amber.position = place(right: phantomX, up: ReachableSpawn.handHeight, forward: ReachableSpawn.forward)
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

    private func markComplete() {
        guard !isComplete else { return }
        isComplete = true
        progressText = "Task complete ✓"
        celebrationTrigger += 1
        audio?.play(.celebrate)
    }

    private func spawnSliceBlock() {
        clearSliceBlock()
        // Bias toward the phantom-hand side at arm reach.
        let side: Float = phantomIsLeft ? -1 : 1
        sliceBlockCenter = place(right: side * 0.18, up: ReachableSpawn.handHeight, forward: ReachableSpawn.forward)

        let block = ModelEntity(
            mesh: .generateBox(size: sliceBlockHalfSize * 2, cornerRadius: 0.004),
            materials: [SimpleMaterial(color: UIColor(red: 0.72, green: 0.55, blue: 0.95, alpha: 1), roughness: 0.25, isMetallic: false)]
        )
        block.position = sliceBlockCenter
        block.name = "sliceBlock"
        sliceRoot.addChild(block)
        sliceBlock = block
    }

    private func applyHorizontalSlice() {
        guard let block = sliceBlock else { return }
        let center = sliceBlockCenter
        let halfThickness = sliceBlockHalfSize * 0.5
        let materials = block.model?.materials ?? [SimpleMaterial(color: .systemPurple, isMetallic: false)]
        block.isEnabled = false

        let top = ModelEntity(
            mesh: .generateBox(size: SIMD3(sliceBlockHalfSize * 2, halfThickness, sliceBlockHalfSize * 2), cornerRadius: 0.004),
            materials: materials
        )
        top.position = center + SIMD3(0, halfThickness * 0.5, 0)
        top.name = "sliceTop"

        let bottom = ModelEntity(
            mesh: .generateBox(size: SIMD3(sliceBlockHalfSize * 2, halfThickness, sliceBlockHalfSize * 2), cornerRadius: 0.004),
            materials: materials
        )
        bottom.position = center + SIMD3(0, -halfThickness * 0.5, 0)
        bottom.name = "sliceBottom"

        sliceRoot.addChild(top)
        sliceRoot.addChild(bottom)
        sliceHalfA = top
        sliceHalfB = bottom
        animateSliceSeparation(a: top, b: bottom, axis: SIMD3(0, 1, 0), amount: 0.06)
    }

    private func applyVerticalSlice() {
        guard let block = sliceBlock else { return }
        let center = sliceBlockCenter
        let halfThickness = sliceBlockHalfSize * 0.5
        let materials = block.model?.materials ?? [SimpleMaterial(color: .systemPurple, isMetallic: false)]
        block.isEnabled = false

        let left = ModelEntity(
            mesh: .generateBox(size: SIMD3(halfThickness, sliceBlockHalfSize * 2, sliceBlockHalfSize * 2), cornerRadius: 0.004),
            materials: materials
        )
        left.position = center + SIMD3(-halfThickness * 0.5, 0, 0)
        left.name = "sliceLeft"

        let right = ModelEntity(
            mesh: .generateBox(size: SIMD3(halfThickness, sliceBlockHalfSize * 2, sliceBlockHalfSize * 2), cornerRadius: 0.004),
            materials: materials
        )
        right.position = center + SIMD3(halfThickness * 0.5, 0, 0)
        right.name = "sliceRight"

        sliceRoot.addChild(left)
        sliceRoot.addChild(right)
        sliceHalfA = left
        sliceHalfB = right
        animateSliceSeparation(a: left, b: right, axis: SIMD3(1, 0, 0), amount: 0.06)
    }

    private func animateSliceSeparation(
        a: ModelEntity,
        b: ModelEntity,
        axis: SIMD3<Float>,
        amount: Float
    ) {
        var aTransform = a.transform
        aTransform.translation = a.position + axis * amount
        a.move(to: aTransform, relativeTo: sliceRoot, duration: 0.22, timingFunction: .easeOut)

        var bTransform = b.transform
        bTransform.translation = b.position - axis * amount
        b.move(to: bTransform, relativeTo: sliceRoot, duration: 0.22, timingFunction: .easeOut)
    }

    private func clearSliceBlock() {
        sliceBlock?.removeFromParent()
        sliceHalfA?.removeFromParent()
        sliceHalfB?.removeFromParent()
        sliceBlock = nil
        sliceHalfA = nil
        sliceHalfB = nil
    }
}
