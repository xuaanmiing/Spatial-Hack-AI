import Foundation
import RealityKit
import ARKit
import simd
import UIKit
import CoreGraphics

/// Loads a rigged hand/forearm USDZ and drives it from an ARKit `HandSkeleton`.
///
/// Joints are matched by **name**, not by array index: different assets author their
/// skeletons in different orders (Apple's own gloves disagree with each other), so an
/// index-based mapping silently swaps fingers.
///
/// The material applied to the mesh is a natural-skin `PhysicallyBasedMaterial`
/// with a procedurally-generated tangent-space normal map, so the phantom hand
/// reads as human skin rather than a plastic mannequin under Vision Pro
/// passthrough lighting.
@MainActor
final class ARKitHandModel {
    /// Asset names tried in order; first one present in the bundle wins.
    /// HandArm_Right is preferred: it is a rigged hand + short forearm glove
    /// that matches the therapy brief (we do not render elbow/upper arm).
    private static let candidateAssets = ["HandArm_Right", "RightHand_ARKit27"]

    /// Shared, lazily-built procedural skin normal map. Generating a small
    /// tileable noise texture at runtime avoids shipping baked textures while
    /// still giving the PBR shader something for specular highlights to sit
    /// on — the difference between "plastic mannequin" and "skin" in
    /// passthrough lighting.
    private static var cachedSkinNormalTexture: MaterialParameters.Texture?

    private(set) var root = Entity()
    private(set) var model: ModelEntity?
    private(set) var isLoaded = false
    private(set) var loadError: String?
    private(set) var assetName: String?

    /// modelJointIndex -> ARKit joint that drives it.
    private var jointMap: [(index: Int, name: HandSkeleton.JointName)] = []
    var jointCount: Int { jointMap.count }

    /// Authored rest pose captured at load — translations are reapplied each frame so
    /// debug joint offsets never accumulate.
    private var restJointTransforms: [Transform] = []

    /// Apple's sample drives every joint including the wrist. If the hand ends up
    /// rotated on device, set this to false to keep the asset's authored wrist rest pose.
    var drivesWristRotation = true

    let name: String
    private let tint: UIColor

    /// Warm mid-tone skin (Fitzpatrick ~III) — reads convincingly in Vision
    /// Pro passthrough against most lighting. Alpha is 1.0 because mirror-box
    /// therapy is more effective when the brain accepts the phantom as a real
    /// (opaque) limb rather than a see-through hologram.
    static let defaultSkinTint = UIColor(red: 0.88, green: 0.68, blue: 0.58, alpha: 1.0)

    init(name: String, tint: UIColor = ARKitHandModel.defaultSkinTint) {
        self.name = name
        self.tint = tint
        root.name = name
    }

    func loadFromBundle() async {
        guard !isLoaded else { return }

        var lastError: String?
        for asset in Self.candidateAssets {
            guard let url = Self.bundleURL(for: asset) else {
                lastError = "\(asset) not in bundle"
                continue
            }
            do {
                let entity = try await Entity(contentsOf: url)
                // Keep the whole SkelRoot hierarchy. Re-parenting just the mesh
                // makes RealityKit drop the skin binding and jointTransforms.
                entity.name = "\(name)-asset"
                root.addChild(entity)

                if let skinned = Self.findSkinnedModel(in: entity) {
                    model = skinned
                    jointMap = Self.buildJointMap(for: skinned.jointNames)
                    restJointTransforms = skinned.jointTransforms
                    applyMaterial(to: skinned)
                } else {
                    model = nil
                    jointMap = []
                    restJointTransforms = []
                    loadError = "no skinned mesh in \(asset)"
                    Self.forEachModel(in: entity) { applyMaterial(to: $0) }
                }

                assetName = asset
                isLoaded = true
                root.isEnabled = false
                if jointMap.isEmpty, loadError == nil {
                    loadError = "0 joints matched in \(asset)"
                }
                return
            } catch {
                lastError = "\(asset): \(error.localizedDescription)"
            }
        }

        loadError = lastError ?? "no hand asset found"
        isLoaded = false
    }

    func setVisible(_ visible: Bool) {
        root.isEnabled = visible
    }

    /// Pose the model from a tracked hand.
    /// - Parameters:
    ///   - mirrored: reflect joint rotations across the sagittal plane (drives the phantom side).
    ///   - mirrorMeshX: flip the mesh in X, for showing this right-handed asset as a left hand.
    ///   - jointOffsets: parent-local translation nudges (meters) for debug / retargeting.
    func apply(
        skeleton: HandSkeleton,
        wristWorld: simd_float4x4,
        mirrored: Bool,
        scale: Float = 1.0,
        mirrorMeshX: Bool = false,
        jointOffsets: [HandSkeleton.JointName: SIMD3<Float>] = [:]
    ) {
        place(wristWorld: wristWorld, scale: scale, mirrorMeshX: mirrorMeshX)

        guard let model, !jointMap.isEmpty else { return }
        var transforms = restJointTransforms.isEmpty ? model.jointTransforms : restJointTransforms
        // Rest snapshot can go stale if RealityKit rebuilt the skeleton; fall back to
        // the live jointTransforms array so we always match the model's expected count.
        if transforms.count != model.jointTransforms.count {
            transforms = model.jointTransforms
        }
        for entry in jointMap where entry.index < transforms.count {
            if entry.name == .wrist && !drivesWristRotation {
                let base = restTranslation(at: entry.index, fallback: transforms[entry.index].translation)
                transforms[entry.index].translation = base + (jointOffsets[entry.name] ?? .zero)
                continue
            }
            var local = skeleton.joint(entry.name).parentFromJointTransform
            if mirrored {
                local = MirrorTransform.mirrorLocalJoint(local)
            }
            // Rotation from ARKit; translation from the asset rest pose (+ optional debug offset).
            let base = restTranslation(at: entry.index, fallback: transforms[entry.index].translation)
            transforms[entry.index].rotation = simd_quatf(local)
            transforms[entry.index].translation = base + (jointOffsets[entry.name] ?? .zero)
        }
        model.jointTransforms = transforms
    }

    /// Show the authored rest pose at a given wrist placement (simulator / preview).
    func applyRestPose(
        wristWorld: simd_float4x4,
        scale: Float = 1.0,
        mirrorMeshX: Bool = false,
        jointOffsets: [HandSkeleton.JointName: SIMD3<Float>] = [:]
    ) {
        place(wristWorld: wristWorld, scale: scale, mirrorMeshX: mirrorMeshX)
        guard let model, !restJointTransforms.isEmpty else { return }
        var transforms = restJointTransforms
        for entry in jointMap where entry.index < transforms.count {
            let base = restTranslation(at: entry.index, fallback: transforms[entry.index].translation)
            transforms[entry.index].translation = base + (jointOffsets[entry.name] ?? .zero)
        }
        model.jointTransforms = transforms
    }

    private func restTranslation(at index: Int, fallback: SIMD3<Float>) -> SIMD3<Float> {
        guard index < restJointTransforms.count else { return fallback }
        return restJointTransforms[index].translation
    }

    private func place(wristWorld: simd_float4x4, scale: Float, mirrorMeshX: Bool) {
        root.isEnabled = true
        var t = Transform(matrix: wristWorld)
        let s = abs(scale)
        t.scale = SIMD3(mirrorMeshX ? -s : s, s, s)
        root.transform = t
    }

    /// Build a natural-skin PBR material for the rigged hand mesh.
    ///
    /// Skin is a dielectric with weak subsurface scattering. RealityKit's
    /// `PhysicallyBasedMaterial` doesn't expose true SSS on visionOS 2, so we
    /// approximate it with:
    ///   * a warm base color (baked skin tone),
    ///   * a mid-high roughness that still lets light catch on knuckles,
    ///   * a very thin clearcoat for the oily sheen on fingertips and nails,
    ///   * a subtle procedural normal map for micro-detail (pores / creases)
    ///     so the mesh doesn't read as a smooth mannequin, and
    ///   * a small warm emissive lift so the limb stays legible against
    ///     bright Vision Pro passthrough even in a dim room. The lift is far
    ///     below the "glowing hologram" threshold so the hand still reads as
    ///     flesh, not as an obviously-virtual overlay.
    private func applyMaterial(to model: ModelEntity) {
        var material = PhysicallyBasedMaterial()

        material.baseColor = .init(tint: tint)
        material.roughness = 0.62
        material.metallic = 0.0
        material.specular = 0.35

        // Thin oil-film clearcoat gives specular highlights on knuckles / nails.
        material.clearcoat = 0.15
        material.clearcoatRoughness = 0.35

        // Bake in a warm ambient tint so the hand doesn't turn gray under
        // Vision Pro's environment-probe estimate when the user is in a
        // cool-lit room.
        let warmEmissive = tint.blended(with: .white, fraction: 0.25) ?? tint
        material.emissiveColor = .init(color: warmEmissive)
        material.emissiveIntensity = 0.08

        // Fully opaque — the therapy brief calls for the phantom limb to be
        // perceived as real; transparency weakens the mirror-box illusion.
        material.blending = .opaque

        // Procedural pore/crease normal map. Optional — if generation fails
        // we still ship a good-looking skin material, just slightly flatter.
        if let normal = Self.skinNormalTexture() {
            material.normal = .init(texture: normal)
        }

        let count = max(model.model?.materials.count ?? 1, 1)
        model.model?.materials = Array(repeating: material, count: count)
    }

    // MARK: - Procedural skin normal map

    /// Returns a shared 256×256 tileable normal map that gives the skin
    /// material micro-surface detail. Generated once per process; nil on
    /// failure (rare).
    private static func skinNormalTexture() -> MaterialParameters.Texture? {
        if let cached = cachedSkinNormalTexture { return cached }
        guard let cg = makeSkinNormalCGImage(size: 256) else { return nil }
        do {
            let options = TextureResource.CreateOptions(semantic: .normal)
            let resource = try TextureResource.generate(
                from: cg,
                withName: "PhantomMirror.SkinNormal",
                options: options
            )
            let tex = MaterialParameters.Texture(resource)
            cachedSkinNormalTexture = tex
            return tex
        } catch {
            return nil
        }
    }

    /// Two-octave value noise -> height field -> normal map.
    /// Pure Core Graphics so it runs on device without Metal shader setup.
    private static func makeSkinNormalCGImage(size: Int) -> CGImage? {
        let dim = size
        let bytesPerPixel = 4
        let bytesPerRow = dim * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: dim * dim * bytesPerPixel)

        // Deterministic PRNG so the pattern is stable between runs.
        var seed: UInt32 = 0x9E3779B9
        func rand() -> Float {
            seed = seed &* 1664525 &+ 1013904223
            return Float(seed & 0x00FFFFFF) / Float(0x01000000)
        }

        // Coarse and fine noise grids for two-octave detail.
        let coarseGrid = 16
        let fineGrid = 64
        var coarse = [Float](repeating: 0, count: coarseGrid * coarseGrid)
        var fine = [Float](repeating: 0, count: fineGrid * fineGrid)
        for i in 0..<coarse.count { coarse[i] = rand() }
        for i in 0..<fine.count { fine[i] = rand() }

        func sample(_ grid: [Float], _ gridDim: Int, _ u: Float, _ v: Float) -> Float {
            // Bilinear filter with wrap.
            let x = u * Float(gridDim)
            let y = v * Float(gridDim)
            let x0 = Int(floor(x)) % gridDim
            let y0 = Int(floor(y)) % gridDim
            let x1 = (x0 + 1) % gridDim
            let y1 = (y0 + 1) % gridDim
            let fx = x - floor(x)
            let fy = y - floor(y)
            let a = grid[y0 * gridDim + x0]
            let b = grid[y0 * gridDim + x1]
            let c = grid[y1 * gridDim + x0]
            let d = grid[y1 * gridDim + x1]
            return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
        }

        func heightAt(_ u: Float, _ v: Float) -> Float {
            let c = sample(coarse, coarseGrid, u, v)
            let f = sample(fine, fineGrid, u, v)
            return c * 0.65 + f * 0.35
        }

        let strength: Float = 1.6 // How pronounced the pores are.
        let step: Float = 1.0 / Float(dim)

        for y in 0..<dim {
            for x in 0..<dim {
                let u = Float(x) / Float(dim)
                let v = Float(y) / Float(dim)
                let hL = heightAt((u - step + 1).truncatingRemainder(dividingBy: 1), v)
                let hR = heightAt((u + step).truncatingRemainder(dividingBy: 1), v)
                let hD = heightAt(u, (v - step + 1).truncatingRemainder(dividingBy: 1))
                let hU = heightAt(u, (v + step).truncatingRemainder(dividingBy: 1))
                let dx = (hR - hL) * strength
                let dy = (hU - hD) * strength
                var nx = -dx
                var ny = -dy
                var nz: Float = 1.0
                let len = (nx * nx + ny * ny + nz * nz).squareRoot()
                nx /= len; ny /= len; nz /= len
                // Encode to 0..255. RealityKit expects tangent-space normals.
                let idx = (y * dim + x) * bytesPerPixel
                pixels[idx + 0] = UInt8(max(0, min(255, Int((nx * 0.5 + 0.5) * 255))))
                pixels[idx + 1] = UInt8(max(0, min(255, Int((ny * 0.5 + 0.5) * 255))))
                pixels[idx + 2] = UInt8(max(0, min(255, Int((nz * 0.5 + 0.5) * 255))))
                pixels[idx + 3] = 255
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let ctx = CGContext(
            data: &pixels,
            width: dim,
            height: dim,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }
        return ctx.makeImage()
    }

    private static func bundleURL(for asset: String) -> URL? {
        for ext in ["usdz", "usdc", "usda"] {
            if let url = Bundle.main.url(forResource: asset, withExtension: ext) {
                return url
            }
        }
        return nil
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
        return nil
    }

    private static func forEachModel(in entity: Entity, _ body: (ModelEntity) -> Void) {
        if let model = entity as? ModelEntity { body(model) }
        for child in entity.children { forEachModel(in: child, body) }
    }

    // MARK: - Joint name matching

    /// Matches both ARKit-style names ("indexFingerKnuckle") and Apple's glove rig
    /// names ("right_handIndex_1_joint"), so any of our assets can drive the same code.
    private static func buildJointMap(for jointNames: [String]) -> [(index: Int, name: HandSkeleton.JointName)] {
        var map: [(Int, HandSkeleton.JointName)] = []
        var used = Set<String>()

        for (index, raw) in jointNames.enumerated() {
            let leaf = raw.split(separator: "/").last.map(String.init) ?? raw
            guard let joint = jointName(from: leaf) else { continue }
            // First match wins, so a stray duplicate can't hijack a finger.
            let key = String(describing: joint)
            if used.contains(key) { continue }
            used.insert(key)
            map.append((index, joint))
        }
        return map
    }

    private static func jointName(from leaf: String) -> HandSkeleton.JointName? {
        // Exact ARKit case name (our procedural asset).
        for joint in HandSkeleton.JointName.allCases where String(describing: joint) == leaf {
            return joint
        }

        let s = leaf.lowercased()

        if s.contains("twist") { return .forearmWrist }
        if s.contains("forearm") { return .forearmArm }

        let finger: (metacarpal: HandSkeleton.JointName,
                     knuckle: HandSkeleton.JointName,
                     base: HandSkeleton.JointName,
                     tip1: HandSkeleton.JointName,
                     tip: HandSkeleton.JointName)?

        if s.contains("thumb") {
            // Thumb has one fewer segment; handled separately below.
            if s.contains("start") { return .thumbKnuckle }
            if s.contains("end") { return .thumbTip }
            if s.contains("_1") { return .thumbIntermediateBase }
            if s.contains("_2") { return .thumbIntermediateTip }
            return nil
        } else if s.contains("index") {
            finger = (.indexFingerMetacarpal, .indexFingerKnuckle, .indexFingerIntermediateBase,
                      .indexFingerIntermediateTip, .indexFingerTip)
        } else if s.contains("mid") {
            finger = (.middleFingerMetacarpal, .middleFingerKnuckle, .middleFingerIntermediateBase,
                      .middleFingerIntermediateTip, .middleFingerTip)
        } else if s.contains("ring") {
            finger = (.ringFingerMetacarpal, .ringFingerKnuckle, .ringFingerIntermediateBase,
                      .ringFingerIntermediateTip, .ringFingerTip)
        } else if s.contains("pinky") || s.contains("little") {
            finger = (.littleFingerMetacarpal, .littleFingerKnuckle, .littleFingerIntermediateBase,
                      .littleFingerIntermediateTip, .littleFingerTip)
        } else {
            finger = nil
        }

        if let f = finger {
            if s.contains("start") { return f.metacarpal }
            if s.contains("end") { return f.tip }
            if s.contains("_1") { return f.knuckle }
            if s.contains("_2") { return f.base }
            if s.contains("_3") { return f.tip1 }
            return nil
        }

        if s.contains("hand") || s.contains("wrist") { return .wrist }
        return nil
    }
}

// MARK: - UIColor blending helper

private extension UIColor {
    /// Linear blend of two colors. Used to warm the emissive lift without
    /// shifting the base hue.
    func blended(with other: UIColor, fraction: CGFloat) -> UIColor? {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        guard getRed(&r1, green: &g1, blue: &b1, alpha: &a1),
              other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2) else {
            return nil
        }
        let f = max(0, min(1, fraction))
        return UIColor(
            red: r1 * (1 - f) + r2 * f,
            green: g1 * (1 - f) + g2 * f,
            blue: b1 * (1 - f) + b2 * f,
            alpha: a1 * (1 - f) + a2 * f
        )
    }
}
