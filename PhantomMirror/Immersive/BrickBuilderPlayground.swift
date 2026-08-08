import Foundation
import RealityKit
import ARKit
import UIKit
import QuartzCore

/// Standalone playground: uses brick nodes from Life_Size_Basic_Lego_Set.usdz.
/// Kept out of the training TaskManager so sessions stay unchanged.
@MainActor
@Observable
final class BrickBuilderPlayground {
    let title = "Brick Builder"
    let instruction =
        "Look at a brick model on the right and pinch. It will fly to the phantom hand; pinch again above another brick to release and connect it."

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
    private var grabStartedAt: CFTimeInterval?
    private var grabStartPosition = SIMD3<Float>.zero

    /// The supplied asset is enlarged 4x for comfortable Vision Pro interaction.
    private static let modelScale: Float = 4.0
    private static let studPitch: Float = 0.0079 * modelScale
    private static let snapAngleTolerance: Float = 35 * .pi / 180
    private static let snapVerticalTolerance: Float = 0.16

    private let platformPosition = SIMD3<Float>(0, 0.80, -0.73)
    private let flightDuration: CFTimeInterval = 0.22

    func loadBrickModels() async {
        guard !isAssetLoaded else { return }
        buildSceneIfNeeded()

        guard let url = Bundle.main.url(
            forResource: "Life_Size_Basic_Lego_Set",
            withExtension: "usdz"
        ) else {
            progressText = "Brick USDZ is missing from the app bundle"
            return
        }

        do {
            let loaded = try await Entity(contentsOf: url)
            guard let rootNode = Self.findEntity(named: "RootNode", in: loaded) else {
                progressText = "The brick model has no RootNode"
                return
            }

            var assets: [BrickAsset] = []
            for source in rootNode.children {
                let visual = source.clone(recursive: true)
                // The Sketchfab hierarchy stores these pieces Z-up. Normalize each
                // independent node to visionOS Y-up and remove its scene layout offset.
                visual.transform = Transform(
                    scale: SIMD3<Float>(repeating: Self.modelScale),
                    rotation: simd_quatf(angle: -.pi * 0.5, axis: SIMD3<Float>(1, 0, 0)),
                    translation: .zero
                )

                let measuringRoot = Entity()
                measuringRoot.addChild(visual)
                let initialBounds = measuringRoot.visualBounds(relativeTo: measuringRoot)
                visual.position -= initialBounds.center
                let centeredBounds = measuringRoot.visualBounds(relativeTo: measuringRoot)
                let bodyTopY: Float
                if let bodyModel = Self.findBodyModel(
                    matching: source.name,
                    in: visual
                ) {
                    let bodyBounds = bodyModel.visualBounds(relativeTo: measuringRoot)
                    bodyTopY = bodyBounds.center.y + bodyBounds.extents.y * 0.5
                } else {
                    // Conservative fallback for this asset: its shell is about
                    // 86% of the total stud-inclusive height.
                    bodyTopY = centeredBounds.extents.y * 0.5
                        - centeredBounds.extents.y * 0.14
                }
                visual.removeFromParent()

                let size = SIMD3<Float>(
                    max(centeredBounds.extents.x, 0.006),
                    max(centeredBounds.extents.y, 0.006),
                    max(centeredBounds.extents.z, 0.006)
                )
                let columns = max(1, Int(round(size.x / Self.studPitch)))
                let rows = max(1, Int(round(size.z / Self.studPitch)))
                assets.append(
                    BrickAsset(
                        name: source.name,
                        template: visual,
                        size: size,
                        columns: columns,
                        rows: rows,
                        bodyTopY: bodyTopY
                    )
                )
            }

            brickAssets = assets
            isAssetLoaded = !assets.isEmpty
            rebuildPalette()
            if isActive {
                resetScene()
            } else {
                progressText = isAssetLoaded
                    ? "Brick playground ready"
                    : "No independent bricks were found in the USDZ"
            }
        } catch {
            progressText = "Unable to load brick USDZ: \(error.localizedDescription)"
        }
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
        progressText = "Look at an original brick model on the right"
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

        paletteRoot.name = "originalModelPalette"
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

        var x = -size.x * 0.5
        while x <= size.x * 0.5 + Self.studPitch * 0.25 {
            let line = ModelEntity(
                mesh: .generateBox(
                    width: lineWidth,
                    height: lineHeight,
                    depth: size.z
                ),
                materials: [lineMaterial]
            )
            line.position = SIMD3(x, topY, 0)
            gridRoot.addChild(line)
            x += Self.studPitch
        }

        var z = -size.z * 0.5
        while z <= size.z * 0.5 + Self.studPitch * 0.25 {
            let line = ModelEntity(
                mesh: .generateBox(
                    width: size.x,
                    height: lineHeight,
                    depth: lineWidth
                ),
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
        progressText = "Original model is flying to the phantom hand"
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
        progressText = "Released — aligning the model's studs while it falls"
        updatePendingSnap()
    }

    private func updatePendingSnap() {
        guard let upper = pendingSnapBrick else { return }
        if trySnap(upper) {
            pendingSnapBrick = nil
            progressText = "Connected ✓ — select another model on the right"
        } else if CACurrentMediaTime() >= pendingSnapDeadline {
            pendingSnapBrick = nil
            progressText = "Placed on table — select another model on the right"
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
                    let snappedX = round(localDelta.x / Self.studPitch) * Self.studPitch
                    let snappedZ = round(localDelta.z / Self.studPitch) * Self.studPitch
                    let rotatedQuarter = !Int(abs(quarterTurns)).isMultiple(of: 2)
                    let upperWidth = rotatedQuarter ? upperAsset.size.z : upperAsset.size.x
                    let upperDepth = rotatedQuarter ? upperAsset.size.x : upperAsset.size.z

                    let overlapMinX = max(
                        -lowerAsset.size.x * 0.5,
                        snappedX - upperWidth * 0.5
                    )
                    let overlapMaxX = min(
                        lowerAsset.size.x * 0.5,
                        snappedX + upperWidth * 0.5
                    )
                    let overlapMinZ = max(
                        -lowerAsset.size.z * 0.5,
                        snappedZ - upperDepth * 0.5
                    )
                    let overlapMaxZ = min(
                        lowerAsset.size.z * 0.5,
                        snappedZ + upperDepth * 0.5
                    )
                    let overlapWidth = overlapMaxX - overlapMinX
                    let overlapDepth = overlapMaxZ - overlapMinZ
                    guard overlapWidth >= Self.studPitch * 0.55,
                          overlapDepth >= Self.studPitch * 0.55 else { continue }

                    let localTarget = SIMD3<Float>(
                        snappedX,
                        lowerAsset.bodyTopY + upperAsset.size.y * 0.5,
                        snappedZ
                    )
                    let target = lowerPosition + lowerRotation.act(localTarget)
                    let localPreviewCenter = SIMD3<Float>(
                        (overlapMinX + overlapMaxX) * 0.5,
                        lowerAsset.bodyTopY + 0.003,
                        (overlapMinZ + overlapMaxZ) * 0.5
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
                        previewSize: SIMD3(overlapWidth, 0.006, overlapDepth),
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

    private static func findEntity(named name: String, in entity: Entity) -> Entity? {
        if entity.name == name { return entity }
        for child in entity.children {
            if let found = findEntity(named: name, in: child) { return found }
        }
        return nil
    }

    private static func findBodyModel(
        matching sourceName: String,
        in entity: Entity
    ) -> ModelEntity? {
        if let model = entity as? ModelEntity,
           model.name.hasPrefix(sourceName + "_") {
            return model
        }
        for child in entity.children {
            if let found = findBodyModel(matching: sourceName, in: child) {
                return found
            }
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
