import Foundation
import RealityKit
import ARKit
import simd
import UIKit
import Combine

@MainActor
@Observable
final class SkinRigAlignmentController {
    struct MappingRow: Identifiable {
        let skinIndex: Int
        let skinJointName: String
        let arkitJoint: HandSkeleton.JointName?

        var id: Int { skinIndex }

        var skinJointLabel: String {
            skinJointName.split(separator: "/").last.map(String.init) ?? skinJointName
        }
    }

    private struct LoadedRig {
        let root: Entity
        let models: [ModelEntity]
        let restJointTransforms: [[Transform]]
        let jointParentIndices: [[Int?]]
        let mappingRows: [MappingRow]
    }

    let root = Entity()

    private let modelAnchor = Entity()
    private let alignmentPivot = Entity()
    private let manualAdjustment = Entity()
    private let modelOffset = Entity()
    private let fixedCoordinateAxes: Entity
    private let debugSortGroup: ModelSortGroup
    private var leftRig: LoadedRig?
    private var rightRig: LoadedRig?
    private var activeIsLeft = true
    private var fixedAxesPlaced = false
    private var fixedReferenceWorld = matrix_identity_float4x4
    private var unboundModelReferenceWorld = matrix_identity_float4x4
    private var bindingModelFromWrist: simd_float4x4?
    private var referenceLocalRotations: [String: simd_quatf] = [:]
    private var lastTrackedLocalRotations: [String: simd_quatf] = [:]
    private var observedLiveLocalRotations: [String: simd_quatf] = [:]
    private var lastTrackedWorldTransforms: [HandSkeleton.JointName: simd_float4x4] = [:]
    private var skinFromARKitByModel: [[Int: simd_float4x4]] = []
    private var forearmRootFromARKitByModel: [simd_float4x4] = []
    private var previousHandControlRotation: simd_quatf?
    private var keepFrozenPoseWhenUnbound = false
    private var manipulationSubscriptions: [any Cancellable] = []

    var onManualAlignmentBegan: (() -> Void)?
    var onManualAlignmentCommitted: ((SIMD3<Float>, simd_quatf) -> Void)?

    private(set) var isLoaded = false
    private(set) var statusText = "Loading separate left and right hand assets..."
    private(set) var skinJointNames: [String] = []
    private(set) var mappingRows: [MappingRow] = []
    private(set) var mappedJointCount = 0
    private(set) var isBound = false

    var unmappedARKitJoints: [HandSkeleton.JointName] {
        let mapped = Set(mappingRows.compactMap(\.arkitJoint))
            .union([.forearmWrist, .forearmArm])
        return HandSkeleton.JointName.allCases.filter { !mapped.contains($0) }
    }

    var controlPointCount: Int { mappedJointCount + 2 }

    init(sortGroup: ModelSortGroup = ModelSortGroup(depthPass: .postPass)) {
        debugSortGroup = sortGroup
        fixedCoordinateAxes = Self.makeCoordinateAxes(length: 0.15)
        root.name = "skinRigAlignmentRoot"
        root.isEnabled = false
        modelAnchor.name = "skinRigModelAnchor"
        alignmentPivot.name = "skinRigAlignmentPivot"
        manualAdjustment.name = "skinRigManualAdjustment"
        modelOffset.name = "skinRigModelOffset"
        fixedCoordinateAxes.name = "fixedWorldCoordinateAxes"
        fixedCoordinateAxes.isEnabled = false
        root.addChild(modelAnchor)
        root.addChild(fixedCoordinateAxes)
        modelAnchor.addChild(alignmentPivot)
        alignmentPivot.addChild(manualAdjustment)
        manualAdjustment.addChild(modelOffset)
    }

    func loadModel() async {
        guard !isLoaded else { return }

        do {
            async let left = loadRig(resource: "FirstPersonHand_Left", isLeft: true)
            async let right = loadRig(resource: "FirstPersonHand_Right", isLeft: false)
            (leftRig, rightRig) = try await (left, right)
            configureDirectManipulation()
            isLoaded = true
            selectRig(isLeft: activeIsLeft)
        } catch {
            statusText = "Could not load the handed skin assets: \(error.localizedDescription)"
        }
    }

    func update(
        worldTransforms: [HandSkeleton.JointName: simd_float4x4],
        calibration: CalibrationData,
        visible: Bool,
        phantomIsLeft: Bool,
        isLiveTracked: Bool,
        autoBind: Bool,
        manualManipulationEnabled: Bool
    ) {
        selectRig(isLeft: phantomIsLeft)
        guard isLoaded, let wrist = worldTransforms[.wrist] else {
            root.isEnabled = false
            return
        }

        root.isEnabled = visible
        leftRig?.root.isEnabled = visible && calibration.showSkinRig && !phantomIsLeft
        rightRig?.root.isEnabled = visible && calibration.showSkinRig && phantomIsLeft

        if visible && !fixedAxesPlaced {
            fixedReferenceWorld = matrix_identity_float4x4
            fixedReferenceWorld.columns.3 = SIMD4(wrist.translation, 1)
            fixedCoordinateAxes.setTransformMatrix(fixedReferenceWorld, relativeTo: nil)
            unboundModelReferenceWorld = fixedReferenceWorld
            fixedAxesPlaced = true
        }
        fixedCoordinateAxes.isEnabled = visible && manualManipulationEnabled
        setManualManipulationEnabled(manualManipulationEnabled && visible)

        if isLiveTracked {
            rememberLiveRotations(from: worldTransforms)
        }

        let modelReferenceWorld: simd_float4x4
        if isBound, let bindingModelFromWrist {
            // Preserve the model's exact world pose at confirmation, then let
            // the live wrist drive that captured wrist-to-model relationship.
            modelReferenceWorld = wrist * bindingModelFromWrist
        } else {
            // Before binding, translation and rotation are expressed entirely in
            // the fixed world-aligned reference frame and never follow the hand.
            modelReferenceWorld = unboundModelReferenceWorld
        }
        modelAnchor.setTransformMatrix(modelReferenceWorld, relativeTo: nil)
        applyAlignment(calibration)

        if autoBind, isLiveTracked, !isBound {
            _ = confirmAlignment(referenceWorld: worldTransforms, isLiveTracked: true)
        }

        if isBound {
            driveSkin(from: worldTransforms)
        } else if !keepFrozenPoseWhenUnbound {
            restoreRestPose()
        }
    }

    @discardableResult
    func confirmAlignment(
        referenceWorld: [HandSkeleton.JointName: simd_float4x4],
        isLiveTracked: Bool
    ) -> Bool {
        guard isLiveTracked else {
            statusText = "Binding blocked: show the intact real hand to start live tracking."
            return false
        }
        guard isLoaded,
              fixedAxesPlaced,
              referenceWorld[.forearmWrist] != nil,
              referenceWorld[.forearmArm] != nil,
              let referenceWrist = referenceWorld[.wrist] else {
            statusText = "Hold the palm and forearm in view before confirming alignment."
            return false
        }

        var captured: [String: simd_quatf] = [:]
        var missing: [String] = []
        for row in mappingRows {
            guard let joint = row.arkitJoint else {
                missing.append(row.skinJointLabel)
                continue
            }
            let key = CalibrationData.jointKey(joint)
            guard let rotation = Self.localRotation(for: joint, in: referenceWorld)
                    ?? observedLiveLocalRotations[key] else {
                missing.append(CalibrationData.friendlyName(for: joint))
                continue
            }
            captured[key] = rotation
        }

        guard missing.isEmpty, captured.count == mappedJointCount else {
            referenceLocalRotations.removeAll()
            statusText = "Binding blocked: missing \(missing.joined(separator: ", ")). Keep the full hand tracked and try again."
            return false
        }

        referenceLocalRotations = captured
        lastTrackedLocalRotations = captured
        guard captureJointBindings(referenceWorld: referenceWorld) else {
            referenceLocalRotations.removeAll()
            lastTrackedLocalRotations.removeAll()
            statusText = "Binding blocked: the model joint coordinate frames are incomplete."
            return false
        }
        bindingModelFromWrist = simd_inverse(referenceWrist)
            * modelAnchor.transformMatrix(relativeTo: nil)
        isBound = true
        keepFrozenPoseWhenUnbound = false
        statusText = "Rigid binding confirmed for the \(activeIsLeft ? "left" : "right") hand. Wrist position is anchored and authored bone lengths are preserved."
        return true
    }

    func clearConfirmation(keepingCurrentPose: Bool = true) {
        if keepingCurrentPose, fixedAxesPlaced {
            unboundModelReferenceWorld = modelAnchor.transformMatrix(relativeTo: nil)
        } else {
            unboundModelReferenceWorld = fixedReferenceWorld
            restoreRestPose()
        }
        referenceLocalRotations.removeAll()
        lastTrackedLocalRotations.removeAll()
        skinFromARKitByModel.removeAll()
        forearmRootFromARKitByModel.removeAll()
        bindingModelFromWrist = nil
        isBound = false
        keepFrozenPoseWhenUnbound = keepingCurrentPose
        if isLoaded {
            statusText = "Alignment unlocked for the \(activeIsLeft ? "left" : "right") hand."
        }
    }

    func setVisible(_ visible: Bool) {
        root.isEnabled = visible
        // The coordinate reference belongs only to the skin alignment tool.
        fixedCoordinateAxes.isEnabled = false
    }

    func resetForNewTrackingSession() {
        fixedAxesPlaced = false
        fixedReferenceWorld = matrix_identity_float4x4
        unboundModelReferenceWorld = matrix_identity_float4x4
        bindingModelFromWrist = nil
        referenceLocalRotations.removeAll()
        lastTrackedLocalRotations.removeAll()
        observedLiveLocalRotations.removeAll()
        lastTrackedWorldTransforms.removeAll()
        skinFromARKitByModel.removeAll()
        forearmRootFromARKitByModel.removeAll()
        previousHandControlRotation = nil
        isBound = false
        keepFrozenPoseWhenUnbound = false
        restoreRestPose()
        setVisible(false)
        if isLoaded {
            statusText = "Ready for a new tracking session."
        }
    }

    private func loadRig(resource: String, isLeft: Bool) async throws -> LoadedRig {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "usdc") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "\(resource).usdc"])
        }

        let loaded = try await Entity(contentsOf: url)
        loaded.name = isLeft ? "leftSkinAsset" : "rightSkinAsset"

        let centerPivot = Entity()
        centerPivot.name = isLeft ? "leftHandCenterPivot" : "rightHandCenterPivot"
        centerPivot.isEnabled = false
        modelOffset.addChild(centerPivot)
        centerPivot.addChild(loaded)

        // RealityKit imports this asset around the source scene origin. Recenter
        // the visible hand so alignment rotation happens around the hand itself.
        let bounds = loaded.visualBounds(relativeTo: centerPivot)
        loaded.position -= bounds.center

        let models = Self.findSkinnedModels(in: loaded)
        guard let jointNames = models.first?.jointNames, !jointNames.isEmpty else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: "\(resource).usdc"])
        }

        let mappingRows = Self.buildMapping(for: jointNames, isLeft: isLeft)
        guard mappingRows.count == Self.requiredSkinJointCount,
              Self.mappingHierarchyIsValid(mappingRows, isLeft: isLeft),
              let highestIndex = mappingRows.map(\.skinIndex).max(),
              models.allSatisfy({ $0.jointTransforms.count > highestIndex }) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: "\(resource).usdc does not contain a complete 20-joint hand hierarchy."
            ])
        }

        models.forEach(configureSkinModel)
        return LoadedRig(
            root: centerPivot,
            models: models,
            restJointTransforms: models.map(\.jointTransforms),
            jointParentIndices: models.map { Self.buildParentIndices(for: $0.jointNames) },
            mappingRows: mappingRows
        )
    }

    private func selectRig(isLeft: Bool) {
        let sideChanged = mappingRows.isEmpty || activeIsLeft != isLeft
        activeIsLeft = isLeft
        // This source asset's X-axis handedness is opposite RealityKit's visual
        // handedness. Swap both visibility and rig driving as one unit.
        leftRig?.root.isEnabled = !isLeft
        rightRig?.root.isEnabled = isLeft

        guard sideChanged, let rig = activeRig else { return }
        fixedAxesPlaced = false
        fixedReferenceWorld = matrix_identity_float4x4
        unboundModelReferenceWorld = matrix_identity_float4x4
        bindingModelFromWrist = nil
        referenceLocalRotations.removeAll()
        lastTrackedLocalRotations.removeAll()
        observedLiveLocalRotations.removeAll()
        lastTrackedWorldTransforms.removeAll()
        skinFromARKitByModel.removeAll()
        forearmRootFromARKitByModel.removeAll()
        previousHandControlRotation = nil
        isBound = false
        keepFrozenPoseWhenUnbound = false
        mappingRows = rig.mappingRows
        skinJointNames = rig.mappingRows.map(\.skinJointName)
        mappedJointCount = rig.mappingRows.compactMap(\.arkitJoint).count
        statusText = "Loaded the \(isLeft ? "left" : "right") hand skin; \(mappedJointCount) joints mapped to ARKit."
    }

    private var activeRig: LoadedRig? {
        activeIsLeft ? rightRig : leftRig
    }

    private func applyAlignment(_ calibration: CalibrationData) {
        alignmentPivot.transform = Transform(
            scale: .one,
            rotation: calibration.skinRotationQuaternion,
            translation: calibration.resolvedSkinModelCenterOffset
        )
        modelOffset.transform = Transform(
            scale: SIMD3(repeating: max(0.001, calibration.skinScale)),
            rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)),
            translation: .zero
        )
    }

    private func restoreRestPose() {
        guard let rig = activeRig else { return }
        for (model, rest) in zip(rig.models, rig.restJointTransforms) where model.jointTransforms.count == rest.count {
            model.jointTransforms = rest
        }
    }

    private func driveSkin(from worldTransforms: [HandSkeleton.JointName: simd_float4x4]) {
        guard let rig = activeRig,
              skinFromARKitByModel.count == rig.models.count,
              forearmRootFromARKitByModel.count == rig.models.count else { return }

        for (joint, world) in worldTransforms {
            lastTrackedWorldTransforms[joint] = world
        }
        let forearmControlWorld = handControlFrame(in: worldTransforms)

        for modelIndex in rig.models.indices {
            let model = rig.models[modelIndex]
            let rest = rig.restJointTransforms[modelIndex]
            let parents = rig.jointParentIndices[modelIndex]
            let bindings = skinFromARKitByModel[modelIndex]
            guard rest.count == model.jointTransforms.count else { continue }
            var transforms = rest

            var desiredWorldBySkinIndex: [Int: simd_float4x4] = [:]
            for row in rig.mappingRows {
                guard let joint = row.arkitJoint,
                      let arkitWorld = lastTrackedWorldTransforms[joint],
                      let skinFromARKit = bindings[row.skinIndex] else { continue }
                desiredWorldBySkinIndex[row.skinIndex] = arkitWorld * skinFromARKit
            }

            alignRigidForearmAtWrist(
                transforms: &transforms,
                model: model,
                parentIndices: parents,
                worldTransforms: worldTransforms,
                forearmControlWorld: forearmControlWorld,
                forearmRootFromARKit: forearmRootFromARKitByModel[modelIndex]
            )

            // Mapping rows follow the USD hierarchy order. Resolve each joint
            // against the model parent's actual solved world transform (including
            // authored/model scale), then use that result for the next child.
            for row in rig.mappingRows {
                guard row.skinIndex < transforms.count,
                      let desiredWorld = desiredWorldBySkinIndex[row.skinIndex] else { continue }

                let solvedGlobals = Self.jointWorldMatrices(
                    model: model,
                    localTransforms: transforms,
                    parentIndices: parents
                )
                let parentWorld: simd_float4x4
                if let parentIndex = parents[row.skinIndex] {
                    parentWorld = solvedGlobals[parentIndex]
                } else {
                    parentWorld = model.transformMatrix(relativeTo: nil)
                }
                let desiredLocal = Transform(matrix: simd_inverse(parentWorld) * desiredWorld)
                // Keep every authored bone length and palm proportion. Only the
                // wrist root is position-anchored; descendants receive rotation.
                transforms[row.skinIndex].rotation = desiredLocal.rotation
            }
            model.jointTransforms = transforms
        }
    }

    private func alignRigidForearmAtWrist(
        transforms: inout [Transform],
        model: ModelEntity,
        parentIndices: [Int?],
        worldTransforms: [HandSkeleton.JointName: simd_float4x4],
        forearmControlWorld: simd_float4x4?,
        forearmRootFromARKit: simd_float4x4
    ) {
        guard let forearmControlWorld,
              let wristTarget = worldTransforms[.wrist] else { return }

        guard let (rootIndex, wristIndex) = Self.forearmJointIndices(in: model.jointNames),
              rootIndex < transforms.count,
              wristIndex < transforms.count,
              parentIndices[wristIndex] == rootIndex else { return }

        let globals = Self.jointWorldMatrices(
            model: model,
            localTransforms: transforms,
            parentIndices: parentIndices
        )
        let correctedRootWorld = forearmControlWorld * forearmRootFromARKit

        let rootParentWorld: simd_float4x4
        if let parentIndex = parentIndices[rootIndex] {
            rootParentWorld = globals[parentIndex]
        } else {
            rootParentWorld = model.transformMatrix(relativeTo: nil)
        }
        let desiredRootLocal = Transform(
            matrix: simd_inverse(rootParentWorld) * correctedRootWorld
        )
        transforms[rootIndex].rotation = desiredRootLocal.rotation

        // Translate the whole authored forearm so its wrist joint lands on the
        // tracked wrist. The root-to-wrist vector itself remains unchanged.
        let wristInRootParent4 = (
            simd_inverse(rootParentWorld) * SIMD4(wristTarget.translation, 1)
        )
        let wristInRootParent = SIMD3(
            wristInRootParent4.x,
            wristInRootParent4.y,
            wristInRootParent4.z
        )
        let rootWithoutTranslation = Transform(
            scale: transforms[rootIndex].scale,
            rotation: transforms[rootIndex].rotation,
            translation: .zero
        ).matrix
        let authoredRootToWrist4 = (
            rootWithoutTranslation * SIMD4(transforms[wristIndex].translation, 1)
        )
        let authoredRootToWrist = SIMD3(
            authoredRootToWrist4.x,
            authoredRootToWrist4.y,
            authoredRootToWrist4.z
        )
        transforms[rootIndex].translation = wristInRootParent - authoredRootToWrist
    }

    private static func jointIndex(named leafName: String, in names: [String]) -> Int? {
        names.firstIndex {
            ($0.split(separator: "/").last.map(String.init) ?? $0) == leafName
        }
    }

    private static func forearmJointIndices(in names: [String]) -> (Int, Int)? {
        if let root = jointIndex(named: "n19", in: names),
           let wrist = jointIndex(named: "n20", in: names) {
            return (root, wrist)
        }
        if let root = jointIndex(named: "n45", in: names),
           let wrist = jointIndex(named: "n46", in: names) {
            return (root, wrist)
        }
        return nil
    }

    private func captureJointBindings(
        referenceWorld: [HandSkeleton.JointName: simd_float4x4]
    ) -> Bool {
        guard let rig = activeRig else { return false }
        var allBindings: [[Int: simd_float4x4]] = []
        var forearmBindings: [simd_float4x4] = []
        guard let forearmControlWorld = handControlFrame(in: referenceWorld) else {
            return false
        }

        for modelIndex in rig.models.indices {
            let model = rig.models[modelIndex]
            let globals = Self.jointWorldMatrices(
                model: model,
                localTransforms: model.jointTransforms,
                parentIndices: rig.jointParentIndices[modelIndex]
            )
            var bindings: [Int: simd_float4x4] = [:]
            for row in rig.mappingRows {
                guard let joint = row.arkitJoint,
                      row.skinIndex < globals.count,
                      let arkitWorld = referenceWorld[joint]
                        ?? lastTrackedWorldTransforms[joint] else { return false }
                // Translation stays at zero for positional snapping. Rotation
                // stores the per-joint basis conversion between ARKit's axes and
                // the authored skin bone axes, preventing twisted fingers.
                bindings[row.skinIndex] = Self.rotationBasisBinding(
                    arkitWorld: arkitWorld,
                    skinWorld: globals[row.skinIndex]
                )
            }
            guard let (rootIndex, _) = Self.forearmJointIndices(in: model.jointNames),
                  rootIndex < globals.count,
                  referenceWorld[.forearmArm] != nil
                    || lastTrackedWorldTransforms[.forearmArm] != nil else { return false }
            forearmBindings.append(Self.rotationBasisBinding(
                arkitWorld: forearmControlWorld,
                skinWorld: globals[rootIndex]
            ))
            allBindings.append(bindings)
        }

        skinFromARKitByModel = allBindings
        forearmRootFromARKitByModel = forearmBindings
        return true
    }

    private static func rotationBasisBinding(
        arkitWorld: simd_float4x4,
        skinWorld: simd_float4x4
    ) -> simd_float4x4 {
        let arkitRotation = simd_normalize(Transform(matrix: arkitWorld).rotation)
        let skinRotation = simd_normalize(Transform(matrix: skinWorld).rotation)
        let basis = simd_normalize(arkitRotation.inverse * skinRotation)
        return simd_float4x4(basis)
    }

    private func rememberLiveRotations(
        from worldTransforms: [HandSkeleton.JointName: simd_float4x4]
    ) {
        for (joint, world) in worldTransforms {
            lastTrackedWorldTransforms[joint] = world
        }
        for row in mappingRows {
            guard let joint = row.arkitJoint,
                  let rotation = Self.localRotation(for: joint, in: worldTransforms) else { continue }
            observedLiveLocalRotations[CalibrationData.jointKey(joint)] = rotation
        }
    }

    private static func buildParentIndices(for names: [String]) -> [Int?] {
        let normalized = names.map { $0.split(separator: "/").joined(separator: "/") }
        let indexByPath = Dictionary(uniqueKeysWithValues: normalized.enumerated().map { ($0.element, $0.offset) })
        return normalized.map { path in
            let components = path.split(separator: "/")
            guard components.count > 1 else { return nil }
            return indexByPath[components.dropLast().joined(separator: "/")]
        }
    }

    private static func jointWorldMatrices(
        model: ModelEntity,
        localTransforms: [Transform],
        parentIndices: [Int?]
    ) -> [simd_float4x4] {
        let modelWorld = model.transformMatrix(relativeTo: nil)
        var result = Array(repeating: matrix_identity_float4x4, count: localTransforms.count)
        for index in localTransforms.indices {
            let parentWorld: simd_float4x4
            if let parent = parentIndices[index], parent < index {
                parentWorld = result[parent]
            } else {
                parentWorld = modelWorld
            }
            result[index] = parentWorld * localTransforms[index].matrix
        }
        return result
    }

    private func configureSkinModel(_ model: ModelEntity) {
        var material = PhysicallyBasedMaterial()
        material.baseColor.tint = UIColor(red: 0.82, green: 0.60, blue: 0.52, alpha: 1)
        material.roughness = 0.78
        material.metallic = 0.0
        material.specular = 0.22
        material.emissiveColor.color = UIColor(red: 0.12, green: 0.07, blue: 0.06, alpha: 1)
        material.emissiveIntensity = 0.12
        material.blending = .transparent(opacity: 0.96)
        let materialCount = max(model.model?.materials.count ?? 1, 1)
        model.model?.materials = Array(repeating: material, count: materialCount)
        model.components.set(ModelSortGroupComponent(group: debugSortGroup, order: 0))
    }

    private func configureDirectManipulation() {
        guard #available(visionOS 26.0, *) else { return }
        configureModernDirectManipulation()
    }

    @available(visionOS 26.0, *)
    private func configureModernDirectManipulation() {
        let bounds = modelOffset.visualBounds(relativeTo: manualAdjustment)
        let size = SIMD3<Float>(
            max(bounds.extents.x, 0.18),
            max(bounds.extents.y, 0.28),
            max(bounds.extents.z, 0.10)
        )
        ManipulationComponent.configureEntity(
            manualAdjustment,
            allowedInputTypes: .all,
            collisionShapes: [.generateBox(size: size)]
        )

        var manipulation = manualAdjustment.components[ManipulationComponent.self]
            ?? ManipulationComponent()
        manipulation.releaseBehavior = .stay
        manipulation.audioConfiguration = .none
        manipulation.dynamics.translationBehavior = .unconstrained
        manipulation.dynamics.primaryRotationBehavior = .unconstrained
        manipulation.dynamics.secondaryRotationBehavior = .unconstrained
        manipulation.dynamics.scalingBehavior = .none
        manipulation.dynamics.inertia = .zero
        manualAdjustment.components.set(manipulation)

        guard let scene = manualAdjustment.scene else { return }
        manipulationSubscriptions = [
            scene.subscribe(to: ManipulationEvents.WillBegin.self, on: manualAdjustment) { [weak self] _ in
                guard let self else { return }
                self.clearConfirmation()
                self.onManualAlignmentBegan?()
            },
            scene.subscribe(to: ManipulationEvents.WillEnd.self, on: manualAdjustment) { [weak self] _ in
                self?.commitManualAdjustment()
            }
        ]
    }

    private func setManualManipulationEnabled(_ enabled: Bool) {
        guard var input = manualAdjustment.components[InputTargetComponent.self] else { return }
        input.isEnabled = enabled
        manualAdjustment.components.set(input)
    }

    private func commitManualAdjustment() {
        let combined = Transform(
            matrix: alignmentPivot.transform.matrix * manualAdjustment.transform.matrix
        )
        manualAdjustment.transform = Transform()
        onManualAlignmentCommitted?(combined.translation, simd_normalize(combined.rotation))
    }

    private static func makeCoordinateAxes(length: Float) -> Entity {
        let axes = Entity()
        axes.name = "handCenterCoordinateAxes"

        let radius: Float = 0.002

        axes.addChild(makeAxis(
            name: "X axis",
            color: .systemRed,
            direction: SIMD3(1, 0, 0),
            length: length,
            radius: radius
        ))
        axes.addChild(makeAxis(
            name: "Y axis",
            color: .systemGreen,
            direction: SIMD3(0, 1, 0),
            length: length,
            radius: radius
        ))
        axes.addChild(makeAxis(
            name: "Z axis",
            color: .systemBlue,
            direction: SIMD3(0, 0, 1),
            length: length,
            radius: radius
        ))

        let origin = ModelEntity(
            mesh: .generateSphere(radius: radius * 2.2),
            materials: [UnlitMaterial(color: .white)]
        )
        origin.name = "hand center"
        axes.addChild(origin)
        return axes
    }

    private static func makeAxis(
        name: String,
        color: UIColor,
        direction: SIMD3<Float>,
        length: Float,
        radius: Float
    ) -> Entity {
        let axis = Entity()
        axis.name = name

        let shaft = ModelEntity(
            mesh: .generateCylinder(height: length, radius: radius),
            materials: [UnlitMaterial(color: color)]
        )
        shaft.position = direction * (length * 0.5)
        shaft.orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: direction)
        axis.addChild(shaft)

        let tip = ModelEntity(
            mesh: .generateSphere(radius: radius * 2),
            materials: [UnlitMaterial(color: color)]
        )
        tip.position = direction * length
        axis.addChild(tip)
        return axis
    }

    private static func findSkinnedModels(in entity: Entity) -> [ModelEntity] {
        var result: [ModelEntity] = []
        if let model = entity as? ModelEntity, !model.jointNames.isEmpty {
            result.append(model)
        }
        for child in entity.children {
            result.append(contentsOf: findSkinnedModels(in: child))
        }
        return result
    }

    private static func localRotation(
        for joint: HandSkeleton.JointName,
        in world: [HandSkeleton.JointName: simd_float4x4]
    ) -> simd_quatf? {
        guard let jointWorld = world[joint] else { return nil }
        guard let parent = arkitParent[joint], let parentWorld = world[parent] else {
            return simd_quatf(jointWorld)
        }
        return simd_quatf(simd_inverse(parentWorld) * jointWorld)
    }

    private func handControlFrame(
        in world: [HandSkeleton.JointName: simd_float4x4]
    ) -> simd_float4x4? {
        guard var frame = Self.rawHandControlFrame(in: world) else { return nil }
        let candidate = simd_normalize(simd_quatf(frame))

        if let previous = previousHandControlRotation {
            var alternativeFrame = frame
            alternativeFrame.columns.0 = -alternativeFrame.columns.0
            alternativeFrame.columns.2 = -alternativeFrame.columns.2
            let alternative = simd_normalize(simd_quatf(alternativeFrame))

            let candidateAngle = Self.rotationAngle(from: previous, to: candidate)
            let alternativeAngle = Self.rotationAngle(from: previous, to: alternative)
            let selected = alternativeAngle < candidateAngle ? alternative : candidate
            let angle = min(candidateAngle, alternativeAngle)
            let maxStep: Float = 12 * .pi / 180
            let amount = angle > maxStep ? maxStep / angle : 1
            let stabilized = simd_normalize(
                simd_slerp(previous, selected, amount)
            )
            previousHandControlRotation = stabilized
            let translation = frame.columns.3
            frame = simd_float4x4(stabilized)
            frame.columns.3 = translation
        } else {
            previousHandControlRotation = candidate
        }
        return frame
    }

    private static func rawHandControlFrame(
        in world: [HandSkeleton.JointName: simd_float4x4]
    ) -> simd_float4x4? {
        guard let wrist = world[.wrist],
              let forearmArm = world[.forearmArm] else { return nil }
        var forearmAxis = wrist.translation - forearmArm.translation
        guard simd_length_squared(forearmAxis) > 0.000001 else { return wrist }
        forearmAxis = simd_normalize(forearmAxis)
        let handAxis = forearmAxis

        var across: SIMD3<Float>
        if let index = world[.indexFingerMetacarpal],
           let little = world[.littleFingerMetacarpal] {
            across = little.translation - index.translation
        } else {
            across = SIMD3<Float>(wrist.columns.0.x, wrist.columns.0.y, wrist.columns.0.z)
        }
        across -= handAxis * simd_dot(across, handAxis)
        guard simd_length_squared(across) > 0.000001 else { return wrist }
        across = simd_normalize(across)

        var normal = simd_normalize(simd_cross(across, handAxis))
        let wristNormal = simd_normalize(
            SIMD3<Float>(wrist.columns.2.x, wrist.columns.2.y, wrist.columns.2.z)
        )
        if simd_dot(normal, wristNormal) < 0 {
            normal = -normal
            across = -across
        }
        across = simd_normalize(simd_cross(handAxis, normal))

        return simd_float4x4(columns: (
            SIMD4(across, 0),
            SIMD4(handAxis, 0),
            SIMD4(normal, 0),
            forearmArm.columns.3
        ))
    }

    private static func rotationAngle(from lhs: simd_quatf, to rhs: simd_quatf) -> Float {
        let cosine = min(1, abs(simd_dot(lhs.vector, rhs.vector)))
        return 2 * acos(cosine)
    }

    private static func buildMapping(for names: [String], isLeft: Bool) -> [MappingRow] {
        let mapping = isLeft ? leftSkinToARKit : rightSkinToARKit
        return names.enumerated().compactMap { index, fullName in
            let leaf = fullName.split(separator: "/").last.map(String.init) ?? fullName
            guard let joint = mapping[leaf] else { return nil }
            return MappingRow(skinIndex: index, skinJointName: fullName, arkitJoint: joint)
        }
    }

    private static func mappingHierarchyIsValid(
        _ rows: [MappingRow],
        isLeft: Bool
    ) -> Bool {
        let mapping = isLeft ? leftSkinToARKit : rightSkinToARKit
        for row in rows {
            guard let joint = row.arkitJoint, joint != .wrist else { continue }
            let components = row.skinJointName.split(separator: "/")
            guard components.count > 1 else { return false }
            let parentSkinName = String(components[components.count - 2])
            guard mapping[parentSkinName] == arkitParent[joint] else { return false }
        }
        return true
    }

    private static let requiredSkinJointCount = 20

    private static let leftSkinToARKit: [String: HandSkeleton.JointName] = [
        "n20": .wrist,
        "n36": .thumbKnuckle, "n37": .thumbIntermediateBase, "n38": .thumbIntermediateTip,
        "n40": .indexFingerMetacarpal, "n41": .indexFingerKnuckle, "n42": .indexFingerIntermediateBase, "n43": .indexFingerIntermediateTip,
        "n26": .middleFingerMetacarpal, "n27": .middleFingerKnuckle, "n28": .middleFingerIntermediateBase, "n29": .middleFingerIntermediateTip,
        "n31": .ringFingerMetacarpal, "n32": .ringFingerKnuckle, "n33": .ringFingerIntermediateBase, "n34": .ringFingerIntermediateTip,
        "n21": .littleFingerMetacarpal, "n22": .littleFingerKnuckle, "n23": .littleFingerIntermediateBase, "n24": .littleFingerIntermediateTip,
    ]

    private static let rightSkinToARKit: [String: HandSkeleton.JointName] = [
        "n46": .wrist,
        "n67": .thumbKnuckle, "n68": .thumbIntermediateBase, "n69": .thumbIntermediateTip,
        "n52": .indexFingerMetacarpal, "n53": .indexFingerKnuckle, "n54": .indexFingerIntermediateBase, "n55": .indexFingerIntermediateTip,
        "n62": .middleFingerMetacarpal, "n63": .middleFingerKnuckle, "n64": .middleFingerIntermediateBase, "n65": .middleFingerIntermediateTip,
        "n57": .ringFingerMetacarpal, "n58": .ringFingerKnuckle, "n59": .ringFingerIntermediateBase, "n60": .ringFingerIntermediateTip,
        "n47": .littleFingerMetacarpal, "n48": .littleFingerKnuckle, "n49": .littleFingerIntermediateBase, "n50": .littleFingerIntermediateTip,
    ]

    private static let arkitParent: [HandSkeleton.JointName: HandSkeleton.JointName] = [
        .thumbKnuckle: .wrist,
        .thumbIntermediateBase: .thumbKnuckle,
        .thumbIntermediateTip: .thumbIntermediateBase,
        .thumbTip: .thumbIntermediateTip,
        .indexFingerMetacarpal: .wrist,
        .indexFingerKnuckle: .indexFingerMetacarpal,
        .indexFingerIntermediateBase: .indexFingerKnuckle,
        .indexFingerIntermediateTip: .indexFingerIntermediateBase,
        .indexFingerTip: .indexFingerIntermediateTip,
        .middleFingerMetacarpal: .wrist,
        .middleFingerKnuckle: .middleFingerMetacarpal,
        .middleFingerIntermediateBase: .middleFingerKnuckle,
        .middleFingerIntermediateTip: .middleFingerIntermediateBase,
        .middleFingerTip: .middleFingerIntermediateTip,
        .ringFingerMetacarpal: .wrist,
        .ringFingerKnuckle: .ringFingerMetacarpal,
        .ringFingerIntermediateBase: .ringFingerKnuckle,
        .ringFingerIntermediateTip: .ringFingerIntermediateBase,
        .ringFingerTip: .ringFingerIntermediateTip,
        .littleFingerMetacarpal: .wrist,
        .littleFingerKnuckle: .littleFingerMetacarpal,
        .littleFingerIntermediateBase: .littleFingerKnuckle,
        .littleFingerIntermediateTip: .littleFingerIntermediateBase,
        .littleFingerTip: .littleFingerIntermediateTip,
        .forearmWrist: .wrist,
        .forearmArm: .forearmWrist,
    ]
}
