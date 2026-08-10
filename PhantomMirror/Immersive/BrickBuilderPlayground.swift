import Foundation
import RealityKit
import ARKit
import UIKit
import QuartzCore

/// Standalone playground built from lightweight procedural LEGO-style bricks.
/// Kept out of the training TaskManager so sessions stay unchanged.
@MainActor
@Observable
final class BrickBuilderPlayground {
    let title = "Brick Builder"
    let instruction =
        "Look at a brick on the right and pinch. It will fly to the phantom hand; pinch again above another brick to release and connect it."

    private struct BrickAsset {
        let name: String
        let template: Entity
        let size: SIMD3<Float>
        let columns: Int
        let rows: Int
        /// Top surface of the solid brick shell, relative to the centered wrapper.
        /// Studs extend above this surface and enter the next brick's underside.
        let bodyTopY: Float
    }

    private struct BrickSpec {
        let name: String
        let columns: Int
        let rows: Int
        let isPlate: Bool
        let color: UIColor
    }

    private struct SnapCandidate {
        let upperMember: ModelEntity
        let lowerMember: ModelEntity
        let distance: Float
        let targetPosition: SIMD3<Float>
        let targetYaw: Float
        let previewCenter: SIMD3<Float>
        let previewSize: SIMD3<Float>
        let previewYaw: Float
    }

    private struct StudGridSnap {
        let centerDelta: SIMD2<Float>
        let overlapCenter: SIMD2<Float>
        let overlapSize: SIMD2<Float>
    }

    private(set) var isActive = false
    private(set) var isHoldingBrick = false
    private(set) var progressText = "Loading brick models…"

    let gameRoot = Entity()

    private var platform: ModelEntity?
    private let paletteRoot = Entity()
    private var palettePanel: ModelEntity?
    private var paletteItems: [ModelEntity] = []
    private var snapPreview: ModelEntity?
    private var brickAssets: [BrickAsset] = []
    private var paletteAssetIndices: [ObjectIdentifier: Int] = [:]
    private var placedAssetIndices: [ObjectIdentifier: Int] = [:]
    private var placedBricks: [ModelEntity] = []
    private var assemblyRoots: [ModelEntity] = []
    private var assemblyMembers: [ObjectIdentifier: [ModelEntity]] = [:]
    private var assemblyByMember: [ObjectIdentifier: ModelEntity] = [:]
    private var heldBrick: ModelEntity?
    private var pendingSnapBrick: ModelEntity?
    private var pendingSnapDeadline: CFTimeInterval = 0
    private var isSceneBuilt = false
    private var isAssetLoaded = false
    private var isLoadingAssets = false
    private var grabStartedAt: CFTimeInterval?
    private var grabStartPosition = SIMD3<Float>.zero

    /// Four-times LEGO dimensions for comfortable Vision Pro interaction.
    private static let modelScale: Float = 4.0
    private static let studPitch: Float = 0.0079 * modelScale
    private static let studRadius: Float = 0.0024 * modelScale
    private static let studHeight: Float = 0.0017 * modelScale
    private static let brickBodyHeight: Float = 0.0096 * modelScale
    private static let plateBodyHeight: Float = 0.0032 * modelScale
    private static let shellClearance: Float = 0.0002 * modelScale
    private static let snapAngleTolerance: Float = 35 * .pi / 180
    private static let snapVerticalTolerance: Float = 0.16

    private let platformPosition = SIMD3<Float>(0, 0.80, -0.73)
    private let flightDuration: CFTimeInterval = 0.22

    func loadBrickModels() async {
        guard !isAssetLoaded, !isLoadingAssets else { return }
        isLoadingAssets = true
        defer { isLoadingAssets = false }
        buildSceneIfNeeded()

        brickAssets = makeProceduralBrickAssets()
        isAssetLoaded = !brickAssets.isEmpty
        rebuildPalette()
        if isActive {
            resetScene()
        } else {
            progressText = "Brick playground ready"
        }
    }

    private func makeProceduralBrickAssets() -> [BrickAsset] {
        let red = UIColor(red: 0.82, green: 0.08, blue: 0.07, alpha: 1)
        let blue = UIColor(red: 0.04, green: 0.30, blue: 0.82, alpha: 1)
        let specs: [BrickSpec] = [
            .init(name: "Main_Cube_010", columns: 8, rows: 2, isPlate: false, color: red),
            .init(name: "Main_Cube_009", columns: 6, rows: 2, isPlate: false, color: red),
            .init(name: "Main_Cube", columns: 4, rows: 2, isPlate: false, color: red),
            .init(name: "Main_Cube_001", columns: 3, rows: 2, isPlate: false, color: red),
            .init(name: "Main_Cube_002", columns: 2, rows: 2, isPlate: false, color: red),
            .init(name: "Main_Cube_008", columns: 2, rows: 2, isPlate: false, color: blue),
            .init(name: "Main_Cube_007", columns: 6, rows: 2, isPlate: true, color: red),
            .init(name: "Main_Cube_006", columns: 4, rows: 2, isPlate: true, color: blue),
            .init(name: "Main_Cube_005", columns: 3, rows: 2, isPlate: true, color: blue),
            .init(name: "Main_Cube_003", columns: 2, rows: 2, isPlate: true, color: blue),
            .init(name: "Main_Cube_004", columns: 1, rows: 2, isPlate: true, color: blue)
        ]
        let studMesh = MeshResource.generateCylinder(
            height: Self.studHeight,
            radius: Self.studRadius
        )
        return specs.map { makeProceduralBrick(spec: $0, studMesh: studMesh) }
    }

    private func makeProceduralBrick(
        spec: BrickSpec,
        studMesh: MeshResource
    ) -> BrickAsset {
        let bodyHeight = spec.isPlate
            ? Self.plateBodyHeight
            : Self.brickBodyHeight
        let totalHeight = bodyHeight + Self.studHeight
        let width = Float(spec.columns) * Self.studPitch - Self.shellClearance
        let depth = Float(spec.rows) * Self.studPitch - Self.shellClearance
        let bottomY = -totalHeight * 0.5
        let bodyTopY = bottomY + bodyHeight
        let material = SimpleMaterial(
            color: spec.color,
            roughness: 0.48,
            isMetallic: false
        )

        let template = Entity()
        template.name = "\(spec.name)-procedural"
        let body = ModelEntity(
            mesh: .generateBox(
                width: width,
                height: bodyHeight,
                depth: depth,
                cornerRadius: 0.0014
            ),
            materials: [material]
        )
        body.name = "\(spec.name)-body"
        body.position.y = bottomY + bodyHeight * 0.5
        template.addChild(body)

        for column in 0..<spec.columns {
            for row in 0..<spec.rows {
                let stud = ModelEntity(mesh: studMesh, materials: [material])
                stud.name = "stud-\(column)-\(row)"
                stud.position = SIMD3(
                    (Float(column) - Float(spec.columns - 1) * 0.5) * Self.studPitch,
                    bodyTopY + Self.studHeight * 0.5,
                    (Float(row) - Float(spec.rows - 1) * 0.5) * Self.studPitch
                )
                template.addChild(stud)
            }
        }

        return BrickAsset(
            name: spec.name,
            template: template,
            size: SIMD3(width, totalHeight, depth),
            columns: spec.columns,
            rows: spec.rows,
            bodyTopY: bodyTopY
        )
    }

    /// Enter the playground: show the table/palette and place a starter brick.
    func activate() {
        buildSceneIfNeeded()
        isActive = true
        resetScene()
    }

    /// Leave the playground without affecting training props.
    func deactivate() {
        isActive = false
        clearScene()
        gameRoot.isEnabled = false
        progressText = isAssetLoaded ? "Brick playground ready" : "Loading brick models…"
    }

    func clearScene() {
        isHoldingBrick = false
        heldBrick = nil
        pendingSnapBrick = nil
        grabStartedAt = nil
        snapPreview?.isEnabled = false

        for assembly in assemblyRoots { assembly.removeFromParent() }
        assemblyRoots.removeAll()
        assemblyMembers.removeAll()
        assemblyByMember.removeAll()
        for brick in placedBricks { brick.removeFromParent() }
        placedBricks.removeAll()
        placedAssetIndices.removeAll()
    }

    func resetScene() {
        buildSceneIfNeeded()
        clearScene()
        gameRoot.isEnabled = true

        guard isAssetLoaded, !brickAssets.isEmpty else {
            progressText = "Loading brick models…"
            return
        }

        let defaultIndex = brickAssets.firstIndex { $0.name == "Main_Cube" } ?? 0
        let defaultBrick = makeBrick(assetIndex: defaultIndex, paletteItem: false)
        let platformTop = platformPosition.y + 0.0125
        defaultBrick.position = SIMD3(
            0,
            platformTop + brickAssets[defaultIndex].size.y * 0.5 + 0.012,
            platformPosition.z
        )
        gameRoot.addChild(defaultBrick)
        placedBricks.append(defaultBrick)
        placedAssetIndices[ObjectIdentifier(defaultBrick)] = defaultIndex
        setSelectionHoverEnabled(true)
        progressText = "Look at a brick on the right"
    }

    func handleSpatialTap(on selectedEntity: Entity) {
        guard isActive else { return }
        if isHoldingBrick {
            releaseBrick()
            return
        }

        guard let selectedRoot = selectableRoot(containing: selectedEntity) else { return }
        let identifier = ObjectIdentifier(selectedRoot)

        if let assetIndex = paletteAssetIndices[identifier] {
            let spawned = makeBrick(assetIndex: assetIndex, paletteItem: false)
            spawned.setPosition(selectedRoot.position(relativeTo: nil), relativeTo: nil)
            spawned.setOrientation(selectedRoot.orientation(relativeTo: nil), relativeTo: nil)
            spawned.scale = .one
            gameRoot.addChild(spawned)
            placedBricks.append(spawned)
            placedAssetIndices[ObjectIdentifier(spawned)] = assetIndex
            grabBrick(spawned)
        } else if assemblyMembers[identifier] != nil {
            grabBrick(selectedRoot)
        } else if placedAssetIndices[identifier] != nil {
            grabBrick(selectedRoot)
        }
    }

    func updateBrickInteraction(
        phantomWorld: [HandSkeleton.JointName: simd_float4x4]
    ) {
        guard isActive else { return }
        if isHoldingBrick,
           let heldBrick,
           let thumb = phantomWorld[.thumbTip]?.translation,
           let index = phantomWorld[.indexFingerTip]?.translation {
            let target = (thumb + index) * 0.5

            if let started = grabStartedAt {
                let progress = min(
                    max(Float((CACurrentMediaTime() - started) / flightDuration), 0),
                    1
                )
                let eased = 1 - pow(1 - progress, 3)
                heldBrick.setPosition(
                    simd_mix(
                        grabStartPosition,
                        target,
                        SIMD3<Float>(repeating: eased)
                    ),
                    relativeTo: nil
                )
                if progress >= 1 {
                    grabStartedAt = nil
                    progressText = "Held by phantom hand — pinch again to release"
                }
            } else {
                heldBrick.setPosition(target, relativeTo: nil)
            }
            updateSnapPreview(for: heldBrick)
        } else {
            snapPreview?.isEnabled = false
            updatePendingSnap()
        }
    }

    private func buildSceneIfNeeded() {
        guard !isSceneBuilt else { return }
        gameRoot.name = "brickGameRoot"
        gameRoot.isEnabled = false

        // Keep the old center, but provide a four-times-larger building area.
        let platformSize = SIMD3<Float>(0.68 * 4, 0.025, 0.52 * 4)
        let platformShape = ShapeResource.generateBox(size: platformSize)
        let platform = ModelEntity(
            mesh: .generateBox(
                width: platformSize.x,
                height: platformSize.y,
                depth: platformSize.z,
                cornerRadius: 0.012
            ),
            materials: [
                SimpleMaterial(
                    color: UIColor(red: 0.24, green: 0.27, blue: 0.31, alpha: 0.75),
                    roughness: 0.82,
                    isMetallic: false
                )
            ]
        )
        platform.name = "physicalPlatform"
        platform.position = platformPosition
        platform.components.set(CollisionComponent(shapes: [platformShape]))
        platform.components.set(InputTargetComponent())
        platform.components.set(
            PhysicsBodyComponent(
                shapes: [platformShape],
                mass: 0,
                material: .generate(friction: 0.88, restitution: 0.06),
                mode: .static
            )
        )
        gameRoot.addChild(platform)
        self.platform = platform
        addBaseplateGrid(to: platform, size: platformSize)

        let preview = ModelEntity(
            mesh: .generateBox(size: 1, cornerRadius: 0.001),
            materials: [
                UnlitMaterial(color: UIColor.systemGreen.withAlphaComponent(0.62))
            ]
        )
        preview.name = "studOverlapPreview"
        preview.isEnabled = false
        gameRoot.addChild(preview)
        snapPreview = preview

        paletteRoot.name = "proceduralBrickPalette"
        gameRoot.addChild(paletteRoot)
        let panelSize = SIMD3<Float>(0.44, 0.72, 0.018)
        let panel = ModelEntity(
            mesh: .generateBox(
                width: panelSize.x,
                height: panelSize.y,
                depth: panelSize.z,
                cornerRadius: 0.018
            ),
            materials: [
                SimpleMaterial(
                    color: UIColor(red: 0.09, green: 0.11, blue: 0.15, alpha: 0.76),
                    roughness: 0.65,
                    isMetallic: false
                )
            ]
        )
        panel.name = "palettePanel"
        panel.position = SIMD3(0.55, 1.17, -0.73)
        panel.components.set(CollisionComponent(shapes: [.generateBox(size: panelSize)]))
        panel.components.set(InputTargetComponent())
        paletteRoot.addChild(panel)
        palettePanel = panel
        isSceneBuilt = true
    }

    /// A single large LEGO-style baseplate. The grid is visual-only and shares
    /// the platform's one continuous collision body, avoiding thousands of
    /// individual physics shapes while retaining stud-scale alignment cues.
    private func addBaseplateGrid(to platform: ModelEntity, size: SIMD3<Float>) {
        let gridRoot = Entity()
        gridRoot.name = "1024x1024BaseplateSurface"
        let lineMaterial = UnlitMaterial(
            color: UIColor(red: 0.42, green: 0.46, blue: 0.50, alpha: 0.28)
        )
        let lineWidth: Float = 0.00075
        let lineHeight: Float = 0.0012
        let topY = size.y * 0.5 + lineHeight * 0.5
        let xLineMesh = MeshResource.generateBox(
            width: lineWidth,
            height: lineHeight,
            depth: size.z
        )
        let zLineMesh = MeshResource.generateBox(
            width: size.x,
            height: lineHeight,
            depth: lineWidth
        )

        var x = -size.x * 0.5
        while x <= size.x * 0.5 + Self.studPitch * 0.25 {
            let line = ModelEntity(
                mesh: xLineMesh,
                materials: [lineMaterial]
            )
            line.position = SIMD3(x, topY, 0)
            gridRoot.addChild(line)
            x += Self.studPitch
        }

        var z = -size.z * 0.5
        while z <= size.z * 0.5 + Self.studPitch * 0.25 {
            let line = ModelEntity(
                mesh: zLineMesh,
                materials: [lineMaterial]
            )
            line.position = SIMD3(0, topY, z)
            gridRoot.addChild(line)
            z += Self.studPitch
        }
        platform.addChild(gridRoot)
    }

    private func rebuildPalette() {
        for item in paletteItems { item.removeFromParent() }
        paletteItems.removeAll()
        paletteAssetIndices.removeAll()

        guard !brickAssets.isEmpty else { return }

        let columns = 3
        let xPositions: [Float] = [0.40, 0.55, 0.70]
        let topY: Float = 1.41
        let rowSpacing: Float = 0.16

        for assetIndex in brickAssets.indices {
            let column = assetIndex % columns
            let row = assetIndex / columns
            let item = makeBrick(assetIndex: assetIndex, paletteItem: true)
            item.name = "palette-\(brickAssets[assetIndex].name)"
            item.position = SIMD3(
                xPositions[column],
                topY - Float(row) * rowSpacing,
                -0.705
            )
            // Twice the previous wall-preview size. Spawned copies remain full-size.
            item.scale = SIMD3<Float>(repeating: 0.46)
            paletteRoot.addChild(item)
            paletteItems.append(item)
            paletteAssetIndices[ObjectIdentifier(item)] = assetIndex
        }
    }

    private func makeBrick(assetIndex: Int, paletteItem: Bool) -> ModelEntity {
        let asset = brickAssets[assetIndex]
        let wrapper = ModelEntity()
        wrapper.name = paletteItem ? "paletteBrick" : "interactiveBrick"
        wrapper.addChild(asset.template.clone(recursive: true))

        let shape = ShapeResource.generateBox(size: asset.size)
        wrapper.components.set(CollisionComponent(shapes: [shape]))
        wrapper.components.set(InputTargetComponent())
        configureSingleHover(wrapper)

        if !paletteItem {
            wrapper.components.set(
                PhysicsBodyComponent(
                    shapes: [shape],
                    mass: max(0.05, Float(asset.columns * asset.rows) * 0.012),
                    material: .generate(friction: 0.76, restitution: 0.08),
                    mode: .dynamic
                )
            )
            wrapper.components.set(PhysicsMotionComponent())
        }
        return wrapper
    }

    private func grabBrick(_ brick: ModelEntity) {
        pendingSnapBrick = nil
        snapPreview?.isEnabled = false
        heldBrick = brick
        setPhysicsMode(.kinematic, for: brick)
        brick.components.set(PhysicsMotionComponent())
        grabStartPosition = brick.position(relativeTo: nil)
        grabStartedAt = CACurrentMediaTime()
        isHoldingBrick = true
        setSelectionHoverEnabled(false)
        progressText = "Brick is flying to the phantom hand"
    }

    private func releaseBrick() {
        guard let heldBrick else { return }
        snapPreview?.isEnabled = false
        grabStartedAt = nil
        isHoldingBrick = false
        self.heldBrick = nil
        setSelectionHoverEnabled(true)
        heldBrick.components.set(PhysicsMotionComponent())
        setPhysicsMode(.dynamic, for: heldBrick)

        pendingSnapBrick = heldBrick
        pendingSnapDeadline = CACurrentMediaTime() + 1.0
        progressText = "Released — aligning the stud grids while it falls"
        updatePendingSnap()
    }

    private func updatePendingSnap() {
        guard let upper = pendingSnapBrick else { return }
        if trySnap(upper) {
            pendingSnapBrick = nil
            progressText = "Connected ✓ — select another brick on the right"
        } else if CACurrentMediaTime() >= pendingSnapDeadline {
            pendingSnapBrick = nil
            progressText = "Placed on table — select another brick on the right"
        }
    }

    /// Shows the actual horizontal overlap area while the phantom hand moves a
    /// brick near another one. This is only guidance; release performs the snap.
    private func updateSnapPreview(for movingRoot: ModelEntity) {
        guard let preview = snapPreview,
              let best = bestSnapCandidate(for: movingRoot) else {
            snapPreview?.isEnabled = false
            return
        }
        preview.isEnabled = true
        preview.setPosition(best.previewCenter, relativeTo: nil)
        preview.setOrientation(
            simd_quatf(angle: best.previewYaw, axis: SIMD3<Float>(0, 1, 0)),
            relativeTo: nil
        )
        preview.scale = best.previewSize
    }

    private func trySnap(_ movingRoot: ModelEntity) -> Bool {
        guard let best = bestSnapCandidate(for: movingRoot) else { return false }
        align(
            movingRoot,
            using: best.upperMember,
            to: best.targetPosition,
            yaw: best.targetYaw
        )
        movingRoot.components.set(PhysicsMotionComponent())
        createOrMergeAssembly(connecting: movingRoot, to: best.lowerMember)
        return true
    }

    /// Finds a connection between the lowest exposed layer of the object in
    /// hand and the highest exposed layer of every stationary object. This
    /// works for brick-to-brick, brick-to-assembly, and assembly-to-assembly.
    private func bestSnapCandidate(for movingRoot: ModelEntity) -> SnapCandidate? {
        let movingMembers = membersBelongingWith(movingRoot)
        let movingIDs = Set(movingMembers.map(ObjectIdentifier.init))
        guard !movingMembers.isEmpty else { return nil }

        let movingBottom = movingMembers.compactMap { member -> Float? in
            guard let index = placedAssetIndices[ObjectIdentifier(member)] else { return nil }
            return member.position(relativeTo: nil).y - brickAssets[index].size.y * 0.5
        }.min() ?? -.greatestFiniteMagnitude

        // Only bottom-layer bricks can make first contact with the target.
        let exposedUpperMembers = movingMembers.filter { member in
            guard let index = placedAssetIndices[ObjectIdentifier(member)] else { return false }
            let bottom = member.position(relativeTo: nil).y - brickAssets[index].size.y * 0.5
            return abs(bottom - movingBottom) <= Self.studPitch * 0.45
        }

        var visitedTargets = Set<ObjectIdentifier>()
        var best: SnapCandidate?

        for seed in placedBricks where !movingIDs.contains(ObjectIdentifier(seed)) {
            let targetRoot = assemblyByMember[ObjectIdentifier(seed)] ?? seed
            let targetID = ObjectIdentifier(targetRoot)
            guard visitedTargets.insert(targetID).inserted else { continue }

            let targetMembers = membersBelongingWith(targetRoot)
                .filter { !movingIDs.contains(ObjectIdentifier($0)) }
            let highestTop = targetMembers.compactMap { member -> Float? in
                guard let index = placedAssetIndices[ObjectIdentifier(member)] else { return nil }
                return member.position(relativeTo: nil).y + brickAssets[index].bodyTopY
            }.max() ?? -.greatestFiniteMagnitude

            // A new assembly is always placed on the currently highest stud plane.
            let exposedLowerMembers = targetMembers.filter { member in
                guard let index = placedAssetIndices[ObjectIdentifier(member)] else { return false }
                let top = member.position(relativeTo: nil).y + brickAssets[index].bodyTopY
                return abs(top - highestTop) <= Self.studPitch * 0.45
            }

            for upper in exposedUpperMembers {
                guard let upperIndex = placedAssetIndices[ObjectIdentifier(upper)] else { continue }
                let upperAsset = brickAssets[upperIndex]
                let upperPosition = upper.position(relativeTo: nil)
                let upperYaw = yaw(of: upper.orientation(relativeTo: nil))

                for lower in exposedLowerMembers {
                    guard let lowerIndex = placedAssetIndices[ObjectIdentifier(lower)] else { continue }
                    let lowerAsset = brickAssets[lowerIndex]
                    let lowerPosition = lower.position(relativeTo: nil)
                    let lowerTop = lowerPosition.y + lowerAsset.bodyTopY
                    let upperBottom = upperPosition.y - upperAsset.size.y * 0.5
                    let verticalGap = abs(upperBottom - lowerTop)
                    guard upperPosition.y >= lowerPosition.y,
                          verticalGap <= Self.snapVerticalTolerance else { continue }

                    let lowerYaw = yaw(of: lower.orientation(relativeTo: nil))
                    let relativeYaw = normalizedAngle(upperYaw - lowerYaw)
                    let quarterTurns = round(relativeYaw / (.pi * 0.5))
                    let snappedRelativeYaw = quarterTurns * (.pi * 0.5)
                    guard abs(normalizedAngle(relativeYaw - snappedRelativeYaw))
                            <= Self.snapAngleTolerance else { continue }

                    let lowerRotation = simd_quatf(
                        angle: lowerYaw,
                        axis: SIMD3<Float>(0, 1, 0)
                    )
                    let localDelta = lowerRotation.inverse.act(upperPosition - lowerPosition)
                    guard let gridSnap = Self.bestStudGridOverlap(
                        currentDelta: SIMD2(localDelta.x, localDelta.z),
                        movingColumns: upperAsset.columns,
                        movingRows: upperAsset.rows,
                        stationaryColumns: lowerAsset.columns,
                        stationaryRows: lowerAsset.rows,
                        quarterTurns: Int(quarterTurns)
                    ) else { continue }

                    let localTarget = SIMD3<Float>(
                        gridSnap.centerDelta.x,
                        lowerAsset.bodyTopY + upperAsset.size.y * 0.5,
                        gridSnap.centerDelta.y
                    )
                    let target = lowerPosition + lowerRotation.act(localTarget)
                    let localPreviewCenter = SIMD3<Float>(
                        gridSnap.overlapCenter.x,
                        lowerAsset.bodyTopY + 0.003,
                        gridSnap.overlapCenter.y
                    )
                    let previewCenter = lowerPosition
                        + lowerRotation.act(localPreviewCenter)
                    let horizontalDistance = simd_distance(
                        SIMD2(upperPosition.x, upperPosition.z),
                        SIMD2(target.x, target.z)
                    )
                    let distance = verticalGap + horizontalDistance

                    let candidate = SnapCandidate(
                        upperMember: upper,
                        lowerMember: lower,
                        distance: distance,
                        targetPosition: target,
                        targetYaw: lowerYaw + snappedRelativeYaw,
                        previewCenter: previewCenter,
                        previewSize: SIMD3(
                            gridSnap.overlapSize.x,
                            0.006,
                            gridSnap.overlapSize.y
                        ),
                        previewYaw: lowerYaw
                    )
                    if best == nil || candidate.distance < best!.distance {
                        best = candidate
                    }
                }
            }
        }
        return best
    }

    /// Treat each stud and its surrounding square as one discrete cell. The
    /// nearest valid snap is found by aligning actual cells, then measuring the
    /// cells that overlap; brick-center parity never enters the calculation.
    private static func bestStudGridOverlap(
        currentDelta: SIMD2<Float>,
        movingColumns: Int,
        movingRows: Int,
        stationaryColumns: Int,
        stationaryRows: Int,
        quarterTurns: Int
    ) -> StudGridSnap? {
        let stationary = studCellCenters(
            columns: stationaryColumns,
            rows: stationaryRows
        )
        let rotation = simd_quatf(
            angle: Float(quarterTurns) * .pi * 0.5,
            axis: SIMD3<Float>(0, 1, 0)
        )
        let moving = studCellCenters(columns: movingColumns, rows: movingRows).map {
            let rotated = rotation.act(SIMD3<Float>($0.x, 0, $0.y))
            return SIMD2(rotated.x, rotated.z)
        }
        guard !moving.isEmpty, !stationary.isEmpty else { return nil }

        var bestDelta: SIMD2<Float>?
        var bestOverlap: [SIMD2<Float>] = []
        var bestDistanceSquared = Float.greatestFiniteMagnitude
        let matchToleranceSquared = pow(studPitch * 0.04, 2)

        for movingCell in moving {
            for stationaryCell in stationary {
                let candidateDelta = stationaryCell - movingCell
                let overlap = moving.compactMap { cell -> SIMD2<Float>? in
                    let placed = cell + candidateDelta
                    return stationary.contains {
                        simd_length_squared($0 - placed) <= matchToleranceSquared
                    } ? placed : nil
                }
                guard !overlap.isEmpty else { continue }

                let distanceSquared = simd_length_squared(candidateDelta - currentDelta)
                let isCloser = distanceSquared < bestDistanceSquared - 0.000001
                let isEqualButLarger = abs(distanceSquared - bestDistanceSquared) <= 0.000001
                    && overlap.count > bestOverlap.count
                if isCloser || isEqualButLarger {
                    bestDelta = candidateDelta
                    bestOverlap = overlap
                    bestDistanceSquared = distanceSquared
                }
            }
        }

        guard let bestDelta, !bestOverlap.isEmpty else { return nil }
        let minX = bestOverlap.map(\.x).min() ?? 0
        let maxX = bestOverlap.map(\.x).max() ?? 0
        let minZ = bestOverlap.map(\.y).min() ?? 0
        let maxZ = bestOverlap.map(\.y).max() ?? 0
        return StudGridSnap(
            centerDelta: bestDelta,
            overlapCenter: SIMD2((minX + maxX) * 0.5, (minZ + maxZ) * 0.5),
            overlapSize: SIMD2(
                maxX - minX + studPitch,
                maxZ - minZ + studPitch
            )
        )
    }

    private static func studCellCenters(
        columns: Int,
        rows: Int
    ) -> [SIMD2<Float>] {
        var centers: [SIMD2<Float>] = []
        centers.reserveCapacity(columns * rows)
        for column in 0..<columns {
            for row in 0..<rows {
                centers.append(
                    SIMD2(
                        (Float(column) - Float(columns - 1) * 0.5) * studPitch,
                        (Float(row) - Float(rows - 1) * 0.5) * studPitch
                    )
                )
            }
        }
        return centers
    }

    /// Moves the whole held assembly while making the selected member land at
    /// the exact stud-aligned transform. Internal member spacing is preserved.
    private func align(
        _ movingRoot: ModelEntity,
        using upperMember: ModelEntity,
        to targetPosition: SIMD3<Float>,
        yaw targetYaw: Float
    ) {
        let memberLocal = upperMember.transformMatrix(relativeTo: movingRoot)
        var desiredMemberWorld = matrix_identity_float4x4
        desiredMemberWorld = Transform(
            scale: .one,
            rotation: simd_quatf(angle: targetYaw, axis: SIMD3<Float>(0, 1, 0)),
            translation: targetPosition
        ).matrix
        movingRoot.setTransformMatrix(
            desiredMemberWorld * memberLocal.inverse,
            relativeTo: nil
        )
    }

    /// Converts snapped bricks into one parent entity with one compound physics
    /// body. Future gaze, highlight, pickup, motion, and release target this root.
    private func createOrMergeAssembly(
        connecting upper: ModelEntity,
        to lower: ModelEntity
    ) {
        var members: [ModelEntity] = []
        var seen = Set<ObjectIdentifier>()

        for brick in membersBelongingWith(upper) + membersBelongingWith(lower) {
            let identifier = ObjectIdentifier(brick)
            if seen.insert(identifier).inserted {
                members.append(brick)
            }
        }
        guard members.count >= 2 else { return }

        var oldRoots: [ModelEntity] = []
        var oldRootIDs = Set<ObjectIdentifier>()
        for member in members {
            if let oldRoot = assemblyByMember[ObjectIdentifier(member)] {
                let identifier = ObjectIdentifier(oldRoot)
                if oldRootIDs.insert(identifier).inserted {
                    oldRoots.append(oldRoot)
                }
            }
        }

        let worldTransforms = Dictionary(
            uniqueKeysWithValues: members.map {
                (ObjectIdentifier($0), $0.transformMatrix(relativeTo: nil))
            }
        )
        let pivot = members.reduce(SIMD3<Float>.zero) {
            $0 + $1.position(relativeTo: nil)
        } / Float(members.count)

        let assembly = ModelEntity()
        assembly.name = "connectedBrickAssembly"
        assembly.position = pivot
        gameRoot.addChild(assembly)

        for member in members {
            let identifier = ObjectIdentifier(member)
            member.removeFromParent()
            assembly.addChild(member)
            if let world = worldTransforms[identifier] {
                member.setTransformMatrix(world, relativeTo: nil)
            }
            member.components.remove(InputTargetComponent.self)
            member.components.remove(CollisionComponent.self)
            member.components.remove(PhysicsBodyComponent.self)
            member.components.remove(PhysicsMotionComponent.self)
        }

        for oldRoot in oldRoots {
            let identifier = ObjectIdentifier(oldRoot)
            oldRoot.removeFromParent()
            assemblyMembers.removeValue(forKey: identifier)
            assemblyRoots.removeAll { $0 === oldRoot }
        }

        var shapes: [ShapeResource] = []
        var totalMass: Float = 0
        for member in members {
            guard let assetIndex = placedAssetIndices[ObjectIdentifier(member)] else { continue }
            let asset = brickAssets[assetIndex]
            let shape = ShapeResource.generateBox(size: asset.size).offsetBy(
                rotation: member.orientation(relativeTo: assembly),
                translation: member.position(relativeTo: assembly)
            )
            shapes.append(shape)
            totalMass += max(0.05, Float(asset.columns * asset.rows) * 0.012)
            assemblyByMember[ObjectIdentifier(member)] = assembly
        }

        assembly.components.set(CollisionComponent(shapes: shapes))
        assembly.components.set(InputTargetComponent())
        configureAssemblyHover(assembly)
        assembly.components.set(
            PhysicsBodyComponent(
                shapes: shapes,
                mass: max(totalMass, 0.1),
                material: .generate(friction: 0.78, restitution: 0.06),
                mode: .kinematic
            )
        )
        assembly.components.set(PhysicsMotionComponent())

        assemblyRoots.append(assembly)
        assemblyMembers[ObjectIdentifier(assembly)] = members
    }

    private func membersBelongingWith(_ brick: ModelEntity) -> [ModelEntity] {
        if let members = assemblyMembers[ObjectIdentifier(brick)] {
            return members
        }
        if let root = assemblyByMember[ObjectIdentifier(brick)],
           let members = assemblyMembers[ObjectIdentifier(root)] {
            return members
        }
        return [brick]
    }

    private func configureSingleHover(_ entity: ModelEntity) {
        let style = HoverEffectComponent.HighlightHoverEffectStyle(
            color: .systemGreen,
            strength: 2.2,
            opacityFunction: .mask
        )
        entity.components.set(HoverEffectComponent(.highlight(style)))
    }

    /// While a brick or assembly is attached to the phantom hand, no other
    /// selectable object should react to gaze. Restore all effects on release.
    private func setSelectionHoverEnabled(_ enabled: Bool) {
        if !enabled {
            for item in paletteItems { Self.removeHoverRecursively(from: item) }
            for brick in placedBricks { Self.removeHoverRecursively(from: brick) }
            for assembly in assemblyRoots { Self.removeHoverRecursively(from: assembly) }
            return
        }

        for item in paletteItems { configureSingleHover(item) }
        for brick in placedBricks where assemblyByMember[ObjectIdentifier(brick)] == nil {
            configureSingleHover(brick)
        }
        for assembly in assemblyRoots { configureAssemblyHover(assembly) }
    }

    private static func removeHoverRecursively(from entity: Entity) {
        entity.components.remove(HoverEffectComponent.self)
        for child in entity.children { removeHoverRecursively(from: child) }
    }

    private func configureAssemblyHover(_ assembly: ModelEntity) {
        let style = HoverEffectComponent.HighlightHoverEffectStyle(
            color: .systemGreen,
            strength: 2.3,
            opacityFunction: .mask
        )
        if #available(visionOS 26.0, *) {
            let groupID = HoverEffectComponent.GroupID()
            Self.applyGroupedHover(
                to: assembly,
                style: style,
                groupID: groupID
            )
        } else {
            assembly.components.set(HoverEffectComponent(.highlight(style)))
        }
    }

    @available(visionOS 26.0, *)
    private static func applyGroupedHover(
        to entity: Entity,
        style: HoverEffectComponent.HighlightHoverEffectStyle,
        groupID: HoverEffectComponent.GroupID
    ) {
        entity.components.set(
            HoverEffectComponent(.highlight(style, groupID: groupID))
        )
        for child in entity.children {
            applyGroupedHover(to: child, style: style, groupID: groupID)
        }
    }

    private func setPhysicsMode(_ mode: PhysicsBodyMode, for brick: ModelEntity) {
        guard var body = brick.components[PhysicsBodyComponent.self] else { return }
        body.mode = mode
        brick.components.set(body)
    }

    private func selectableRoot(containing entity: Entity) -> ModelEntity? {
        var candidate: Entity? = entity
        while let current = candidate {
            if let model = current as? ModelEntity {
                let identifier = ObjectIdentifier(model)
                if assemblyMembers[identifier] != nil {
                    return model
                }
                if let assembly = assemblyByMember[identifier] {
                    return assembly
                }
                if paletteAssetIndices[identifier] != nil || placedAssetIndices[identifier] != nil {
                    return model
                }
            }
            candidate = current.parent
        }
        return nil
    }

    private func yaw(of rotation: simd_quatf) -> Float {
        let forward = rotation.act(SIMD3<Float>(0, 0, 1))
        return atan2(forward.x, forward.z)
    }

    private func normalizedAngle(_ angle: Float) -> Float {
        var result = angle
        while result > .pi { result -= 2 * .pi }
        while result < -.pi { result += 2 * .pi }
        return result
    }
}
