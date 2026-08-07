import Foundation
import RealityKit
import ARKit
import simd
import UIKit

/// Loads and drives `RightHand_ARKit27.usdz` (27 joints = HandSkeleton.JointName order).
@MainActor
final class ARKitHandModel {
    private(set) var root = Entity()
    private(set) var model: ModelEntity?
    private(set) var isLoaded = false
    private(set) var loadError: String?
    private(set) var jointCount: Int = 0

    let name: String

    /// Bright unlit skin so the hand stays visible in Vision Pro passthrough.
    private static let visibleMaterial = UnlitMaterial(
        color: UIColor(red: 1.0, green: 0.72, blue: 0.55, alpha: 1.0)
    )

    init(name: String) {
        self.name = name
        root.name = name
    }

    func loadFromBundle() async {
        guard !isLoaded else { return }

        do {
            let entity: Entity
            if let url = Bundle.main.url(forResource: "RightHand_ARKit27", withExtension: "usdz") {
                entity = try await Entity(contentsOf: url)
            } else if let url = Bundle.main.url(forResource: "RightHand_ARKit27", withExtension: "usdc") {
                entity = try await Entity(contentsOf: url)
            } else {
                entity = try await Entity(named: "RightHand_ARKit27")
            }

            // Keep the full SkelRoot hierarchy — do NOT re-parent the mesh alone
            // or RealityKit can drop jointTransforms / skin binding.
            entity.name = "\(name)-asset"
            root.addChild(entity)

            let modelEntity = Self.findSkinnedModel(in: entity)
            if let modelEntity {
                Self.applyVisibleMaterials(to: modelEntity)
                model = modelEntity
                jointCount = modelEntity.jointNames.count
            } else {
                Self.applyVisibleMaterialsRecursively(to: entity)
                model = nil
                jointCount = 0
                loadError = "USDZ loaded but no skinned ModelEntity (joints unavailable)"
            }

            if jointCount == 0, loadError == nil {
                loadError = "Model has 0 jointTransforms"
            }

            isLoaded = true
            root.isEnabled = false
        } catch {
            loadError = String(describing: error)
            isLoaded = false
        }
    }

    func setVisible(_ visible: Bool) {
        root.isEnabled = visible
    }

    /// Place wrist in world and apply per-joint parent-relative poses.
    /// - Parameter mirrorMeshX: flip mesh in X (use for showing a left hand with a right-handed USDZ).
    func apply(
        wristWorld: simd_float4x4,
        jointLocals: [HandSkeleton.JointName: simd_float4x4],
        scale: Float = 1.0,
        mirrorMeshX: Bool = false
    ) {
        root.isEnabled = true
        // Set pose via Transform so scale isn't clobbered incorrectly.
        var t = Transform(matrix: wristWorld)
        let s = abs(scale)
        t.scale = SIMD3(mirrorMeshX ? -s : s, s, s)
        root.transform = t

        guard let model else { return }
        var transforms = model.jointTransforms
        let count = min(transforms.count, model.jointNames.count)
        guard count > 0 else { return }

        let transformsByName = Dictionary(
            uniqueKeysWithValues: jointLocals.map {
                (String(describing: $0.key), $0.value)
            }
        )
        for i in 0..<count {
            let modelJointName = model.jointNames[i]
            let shortName = modelJointName.split(separator: "/").last.map(String.init) ?? modelJointName
            guard let local = transformsByName[shortName] else { continue }
            transforms[i] = Transform(matrix: local)
        }
        model.jointTransforms = transforms
    }

    func applyRestPose(wristWorld: simd_float4x4, scale: Float = 1.0, mirrorMeshX: Bool = false) {
        root.isEnabled = true
        var t = Transform(matrix: wristWorld)
        let s = abs(scale)
        t.scale = SIMD3(mirrorMeshX ? -s : s, s, s)
        root.transform = t
    }

    private static func findSkinnedModel(in entity: Entity) -> ModelEntity? {
        if let model = entity as? ModelEntity, !model.jointNames.isEmpty {
            return model
        }
        for child in entity.children {
            if let found = findSkinnedModel(in: child) {
                return found
            }
        }
        // Prefer any ModelEntity even without joints (static mesh fallback).
        if let model = entity as? ModelEntity {
            return model
        }
        for child in entity.children {
            if let model = child as? ModelEntity {
                return model
            }
            if let found = findAnyModel(in: child) {
                return found
            }
        }
        return nil
    }

    private static func findAnyModel(in entity: Entity) -> ModelEntity? {
        if let model = entity as? ModelEntity { return model }
        for child in entity.children {
            if let found = findAnyModel(in: child) { return found }
        }
        return nil
    }

    private static func applyVisibleMaterials(to model: ModelEntity) {
        let count = max(model.model?.materials.count ?? 1, 1)
        model.model?.materials = Array(repeating: visibleMaterial, count: count)
    }

    private static func applyVisibleMaterialsRecursively(to entity: Entity) {
        if let model = entity as? ModelEntity {
            applyVisibleMaterials(to: model)
        }
        for child in entity.children {
            applyVisibleMaterialsRecursively(to: child)
        }
    }
}
