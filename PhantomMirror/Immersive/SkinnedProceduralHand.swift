import Foundation
import RealityKit
import ARKit
import simd
import UIKit
import CoreGraphics

/// Procedural "skinned" hand made of PBR spheres (joints) and capsules
/// (bones) placed at the exact same world-space joint positions the blue
/// calibration skeleton (`VirtualHandVisualizer`) uses, so it visually
/// coincides with it.
///
/// Why not the USDZ rigged mesh?
///   * The bundled USDZ rest-pose axes don't match ARKit's wrist axes on
///     visionOS 2, which flipped the mesh upside-down when driven live.
///   * A procedural build only needs joint *positions* (not rotations) —
///     bone orientation is computed from parent→child direction — so the
///     upside-down bug can't occur.
///
/// The visual result is a warm-skin PBR hand: spheres taper from knuckles
/// to fingertips, capsules connect them, and a low-detail palm slab fills
/// the space between the metacarpals so it doesn't look like a stick figure.
@MainActor
final class SkinnedProceduralHand {

    // MARK: - Public API

    /// Root entity — add this into the RealityKit scene once.
    let root = Entity()

    init(name: String, tint: UIColor = SkinnedProceduralHand.defaultSkinTint) {
        root.name = name
        self.tint = tint
        self.material = Self.buildSkinMaterial(tint: tint)
        buildJointSpheres()
        buildBoneCapsules()
        buildPalmSlab()
        root.isEnabled = false
    }

    func setVisible(_ visible: Bool) {
        root.isEnabled = visible
    }

    /// Drive the whole hand from an ARKit-style world-transforms map.
    /// Only the **translations** of `worldTransforms` are used — bones orient
    /// themselves from parent→child direction, which is the fix for the
    /// upside-down USDZ issue.
    func update(
        worldTransforms transforms: [HandSkeleton.JointName: simd_float4x4],
        scale: Float = 1.0
    ) {
        // Apply an optional per-hand scale around the wrist so calibration can
        // grow / shrink the phantom without losing anatomical proportions.
        let displayed = scaled(transforms, scale: scale)

        // 1. Joints -> spheres at exact positions.
        for (joint, entity) in jointEntities {
            guard let m = displayed[joint] else {
                entity.isEnabled = false
                continue
            }
            entity.isEnabled = true
            entity.position = m.translation
            // No rotation copy — a sphere is rotation-invariant, and the
            // rotation is where the USDZ upside-down bug lived.
        }

        // 2. Bones -> capsules oriented by parent→child direction.
        for (key, bone) in boneEntities {
            guard let pair = Self.bonePairs[key],
                  let a = displayed[pair.parent]?.translation,
                  let b = displayed[pair.child]?.translation else {
                bone.entity.isEnabled = false
                continue
            }
            positionCapsule(bone: bone, from: a, to: b)
        }

        // 3. Palm slab -> flat capsule between wrist and middle-metacarpal.
        updatePalm(from: displayed)
    }

    /// Hide everything (used when tracking is lost).
    func hideAll() {
        for entity in jointEntities.values { entity.isEnabled = false }
        for bone in boneEntities.values { bone.entity.isEnabled = false }
        palmAnchor?.isEnabled = false
    }

    // MARK: - Config

    static let defaultSkinTint = UIColor(red: 0.90, green: 0.71, blue: 0.60, alpha: 1.0)

    /// Per-joint sphere radii tuned so knuckles read as knuckles and tips as
    /// tips. Radii are in meters and roughly match adult finger geometry.
    private static let jointRadius: [HandSkeleton.JointName: Float] = [
        .wrist:                             0.028,
        .forearmWrist:                      0.028,
        .forearmArm:                        0.034,

        .thumbKnuckle:                      0.014,
        .thumbIntermediateBase:             0.012,
        .thumbIntermediateTip:              0.010,
        .thumbTip:                          0.009,

        .indexFingerMetacarpal:             0.014,
        .indexFingerKnuckle:                0.013,
        .indexFingerIntermediateBase:       0.011,
        .indexFingerIntermediateTip:        0.010,
        .indexFingerTip:                    0.008,

        .middleFingerMetacarpal:            0.014,
        .middleFingerKnuckle:               0.013,
        .middleFingerIntermediateBase:      0.011,
        .middleFingerIntermediateTip:       0.010,
        .middleFingerTip:                   0.008,

        .ringFingerMetacarpal:              0.013,
        .ringFingerKnuckle:                 0.012,
        .ringFingerIntermediateBase:        0.011,
        .ringFingerIntermediateTip:         0.010,
        .ringFingerTip:                     0.008,

        .littleFingerMetacarpal:            0.012,
        .littleFingerKnuckle:               0.011,
        .littleFingerIntermediateBase:      0.010,
        .littleFingerIntermediateTip:       0.009,
        .littleFingerTip:                   0.008
    ]

    /// Bone (capsule) radii keyed by (child, parent). Slightly thinner than
    /// the joint sphere at each end so the joints look like knuckle bulges.
    private static let bonePairs: [String: (child: HandSkeleton.JointName,
                                            parent: HandSkeleton.JointName,
                                            radius: Float)] = {
        let pairs: [(HandSkeleton.JointName, HandSkeleton.JointName, Float)] = [
            (.forearmWrist, .wrist, 0.024),
            (.forearmArm,   .forearmWrist, 0.028),

            (.thumbKnuckle,             .wrist,                     0.013),
            (.thumbIntermediateBase,    .thumbKnuckle,              0.011),
            (.thumbIntermediateTip,     .thumbIntermediateBase,     0.009),
            (.thumbTip,                 .thumbIntermediateTip,      0.008),

            (.indexFingerMetacarpal,        .wrist,                        0.012),
            (.indexFingerKnuckle,           .indexFingerMetacarpal,        0.012),
            (.indexFingerIntermediateBase,  .indexFingerKnuckle,           0.010),
            (.indexFingerIntermediateTip,   .indexFingerIntermediateBase,  0.009),
            (.indexFingerTip,               .indexFingerIntermediateTip,   0.008),

            (.middleFingerMetacarpal,       .wrist,                         0.012),
            (.middleFingerKnuckle,          .middleFingerMetacarpal,        0.012),
            (.middleFingerIntermediateBase, .middleFingerKnuckle,           0.010),
            (.middleFingerIntermediateTip,  .middleFingerIntermediateBase,  0.009),
            (.middleFingerTip,              .middleFingerIntermediateTip,   0.008),

            (.ringFingerMetacarpal,         .wrist,                       0.011),
            (.ringFingerKnuckle,            .ringFingerMetacarpal,        0.011),
            (.ringFingerIntermediateBase,   .ringFingerKnuckle,           0.010),
            (.ringFingerIntermediateTip,    .ringFingerIntermediateBase,  0.009),
            (.ringFingerTip,                .ringFingerIntermediateTip,   0.008),

            (.littleFingerMetacarpal,        .wrist,                        0.010),
            (.littleFingerKnuckle,           .littleFingerMetacarpal,       0.010),
            (.littleFingerIntermediateBase,  .littleFingerKnuckle,          0.009),
            (.littleFingerIntermediateTip,   .littleFingerIntermediateBase, 0.008),
            (.littleFingerTip,               .littleFingerIntermediateTip,  0.007)
        ]
        var map: [String: (HandSkeleton.JointName, HandSkeleton.JointName, Float)] = [:]
        for (child, parent, radius) in pairs {
            map["\(child)->\(parent)"] = (child, parent, radius)
        }
        return map
    }()

    // MARK: - Storage

    private let tint: UIColor
    private let material: PhysicallyBasedMaterial

    private var jointEntities: [HandSkeleton.JointName: ModelEntity] = [:]

    /// Bone == an oriented cylinder + a cached mesh (so we can rebuild it if
    /// the bone gets stretched hard and the aspect ratio would otherwise look
    /// squashed — we scale in Y for length only).
    private struct Bone {
        let entity: ModelEntity
        let radius: Float
    }
    private var boneEntities: [String: Bone] = [:]

    /// Palm has two nodes: an outer entity that carries translation+rotation
    /// (rigid), and an inner ModelEntity that carries the non-uniform scale
    /// (a shear that Transform can't cleanly represent by itself).
    private var palmAnchor: Entity?
    private var palmEntity: ModelEntity?

    // MARK: - Build

    private func buildJointSpheres() {
        for joint in HandSkeleton.JointName.allCases {
            let radius = Self.jointRadius[joint] ?? 0.010
            let mesh = MeshResource.generateSphere(radius: radius)
            let e = ModelEntity(mesh: mesh, materials: [material])
            e.name = "skin-joint-\(joint)"
            e.isEnabled = false
            root.addChild(e)
            jointEntities[joint] = e
        }
    }

    private func buildBoneCapsules() {
        for (key, spec) in Self.bonePairs {
            // Unit-length cylinder — we scale Y each frame to match the bone
            // length while keeping radius constant. RealityKit doesn't ship a
            // capsule primitive, so we rely on the joint spheres as caps.
            let mesh = MeshResource.generateCylinder(height: 1.0, radius: spec.radius)
            let e = ModelEntity(mesh: mesh, materials: [material])
            e.name = "skin-bone-\(key)"
            e.isEnabled = false
            root.addChild(e)
            boneEntities[key] = Bone(entity: e, radius: spec.radius)
        }
    }

    private func buildPalmSlab() {
        // Two-node palm: anchor handles pose, model handles non-uniform scale.
        // Splitting them avoids RealityKit's Transform.polarDecompose baking
        // shear into the rotation for non-uniform-scaled ellipsoids.
        let anchor = Entity()
        anchor.name = "skin-palm-anchor"
        anchor.isEnabled = false
        root.addChild(anchor)
        palmAnchor = anchor

        let mesh = MeshResource.generateSphere(radius: 1.0)
        let e = ModelEntity(mesh: mesh, materials: [material])
        e.name = "skin-palm"
        anchor.addChild(e)
        palmEntity = e
    }

    // MARK: - Frame update helpers

    private func scaled(
        _ transforms: [HandSkeleton.JointName: simd_float4x4],
        scale: Float
    ) -> [HandSkeleton.JointName: simd_float4x4] {
        let clamped = max(0.01, abs(scale))
        guard abs(clamped - 1) > 0.0001,
              let pivot = transforms[.wrist]?.translation else {
            return transforms
        }
        return transforms.mapValues { t in
            var s = t
            let p = pivot + (t.translation - pivot) * clamped
            s.columns.3 = SIMD4(p.x, p.y, p.z, 1)
            return s
        }
    }

    private func positionCapsule(bone: Bone, from a: SIMD3<Float>, to b: SIMD3<Float>) {
        let dir = b - a
        let length = simd_length(dir)
        guard length > 0.001 else {
            bone.entity.isEnabled = false
            return
        }
        bone.entity.isEnabled = true

        // Cylinder authored along +Y; build a world transform whose Y axis
        // is `dir` and whose X/Z form an orthonormal frame around it.
        let y = dir / length
        let arbitrary: SIMD3<Float> = abs(y.y) < 0.99 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
        let x = simd_normalize(simd_cross(arbitrary, y))
        let z = simd_cross(x, y)
        let mid = (a + b) * 0.5
        // scale Y by `length` (unit cylinder → correct bone length); keep X,Z
        // at 1 so the authored radius is preserved.
        let matrix = simd_float4x4(columns: (
            SIMD4(x.x, x.y, x.z, 0),
            SIMD4(y.x * length, y.y * length, y.z * length, 0),
            SIMD4(z.x, z.y, z.z, 0),
            SIMD4(mid.x, mid.y, mid.z, 1)
        ))
        bone.entity.setTransformMatrix(matrix, relativeTo: nil)
    }

    /// Draw the palm as an oriented, flattened ellipsoid between the wrist
    /// and the middle-finger metacarpal. Width is estimated from the span
    /// between the index and little metacarpals so it grows with the hand.
    private func updatePalm(from t: [HandSkeleton.JointName: simd_float4x4]) {
        guard let anchor = palmAnchor, let palm = palmEntity else { return }
        guard let wrist = t[.wrist]?.translation,
              let midMeta = t[.middleFingerMetacarpal]?.translation,
              let indexMeta = t[.indexFingerMetacarpal]?.translation,
              let littleMeta = t[.littleFingerMetacarpal]?.translation else {
            anchor.isEnabled = false
            return
        }

        // The palm's long axis (Y in local space) points from wrist to the
        // knuckle line. Its width axis (X) is the vector across the palm
        // between index and little metacarpals. Depth (Z) is the perpendicular
        // — the palm is thin, so Z scale is small.
        let center = (wrist + midMeta) * 0.5
        let longAxis = midMeta - wrist
        let length = simd_length(longAxis)
        guard length > 0.01 else {
            anchor.isEnabled = false
            return
        }
        let y = longAxis / length

        var widthAxis = littleMeta - indexMeta
        // Project widthAxis onto the plane perpendicular to `y` so the palm
        // ellipsoid remains a valid orthonormal frame.
        widthAxis = widthAxis - y * simd_dot(widthAxis, y)
        var width = simd_length(widthAxis)
        if width < 0.02 { width = 0.06 } // Safety floor when metacarpals overlap.
        let x = width > 0.0001 ? widthAxis / width : SIMD3<Float>(1, 0, 0)
        let z = simd_cross(x, y)

        // A palm is a fat rounded slab, not a sphere.
        // Long axis ≈ wrist-to-knuckle distance; wide across the metacarpals;
        // very thin front-to-back.
        let halfLength = length * 0.55
        let halfWidth  = width * 0.55
        let halfDepth: Float = 0.014

        anchor.isEnabled = true

        // 1. Anchor: rigid pose (rotation + translation only).
        let rot = simd_float4x4(columns: (
            SIMD4(x.x, x.y, x.z, 0),
            SIMD4(y.x, y.y, y.z, 0),
            SIMD4(z.x, z.y, z.z, 0),
            SIMD4(center.x, center.y, center.z, 1)
        ))
        anchor.setTransformMatrix(rot, relativeTo: nil)

        // 2. Model: non-uniform scale in the anchor's local frame.
        palm.transform = Transform(scale: SIMD3(halfWidth, halfLength, halfDepth))
    }

    // MARK: - Material

    private static var cachedSkinNormalTexture: MaterialParameters.Texture?

    /// Build a warm-skin PBR material shared between every joint / bone /
    /// palm entity — one material means one draw-state, so drawing 27 spheres
    /// + 26 capsules + the palm stays cheap.
    private static func buildSkinMaterial(tint: UIColor) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()

        material.baseColor = .init(tint: tint)
        material.roughness = 0.62
        material.metallic = 0.0
        material.specular = 0.35

        // Thin oil-film clearcoat gives specular highlights on knuckles / nails.
        material.clearcoat = 0.15
        material.clearcoatRoughness = 0.35

        // Warm emissive lift keeps the limb legible in bright passthrough
        // without pushing it into "glowing hologram" territory.
        let warmEmissive = tint.blended(with: .white, fraction: 0.25) ?? tint
        material.emissiveColor = .init(color: warmEmissive)
        material.emissiveIntensity = 0.10

        // Fully opaque — mirror-box therapy needs the brain to accept the
        // phantom as a real limb.
        material.blending = .opaque

        if let normal = skinNormalTexture() {
            material.normal = .init(texture: normal)
        }
        return material
    }

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

    /// Two-octave value noise -> height field -> tangent-space normal map.
    private static func makeSkinNormalCGImage(size: Int) -> CGImage? {
        let dim = size
        let bytesPerPixel = 4
        let bytesPerRow = dim * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: dim * dim * bytesPerPixel)

        var seed: UInt32 = 0x9E3779B9
        func rand() -> Float {
            seed = seed &* 1664525 &+ 1013904223
            return Float(seed & 0x00FFFFFF) / Float(0x01000000)
        }

        let coarseGrid = 16
        let fineGrid = 64
        var coarse = [Float](repeating: 0, count: coarseGrid * coarseGrid)
        var fine = [Float](repeating: 0, count: fineGrid * fineGrid)
        for i in 0..<coarse.count { coarse[i] = rand() }
        for i in 0..<fine.count { fine[i] = rand() }

        func sample(_ grid: [Float], _ gridDim: Int, _ u: Float, _ v: Float) -> Float {
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

        let strength: Float = 1.4
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
}

// MARK: - UIColor blending helper (shared with ARKitHandModel's copy — file-private here so we don't collide)

private extension UIColor {
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
