import Foundation
import RealityKit
import ARKit
import simd
import UIKit
import CoreGraphics

/// A skinned hand rendered from `PhantomMirror/Resources/hand.usdc`, driven at
/// runtime by the same `[HandSkeleton.JointName: simd_float4x4]` world-joint
/// map that the blue calibration skeleton uses. The mesh's vertices are
/// re-skinned (Linear Blend Skinning) each frame against the ARKit joints, so
/// every knuckle / fingertip on the mesh follows its corresponding calibrated
/// ARKit joint — the mesh overlaps the calibration by construction and doesn't
/// wander off to the wrong axis like the rigged USDZ did.
///
/// Pipeline
/// --------
///   1.  loadFromBundle() reads hand.usdc, finds the ModelEntity, extracts
///       vertex positions + normals + triangle indices, and hides the
///       original entity (we replace its mesh in-place each frame).
///   2.  detectCanonicalFrame() analyses the local-space AABB to figure out
///       which axis is "along the fingers" (longest extent) and which is
///       "palm normal" (shortest extent). No assumption on the authoring
///       software is required.
///   3.  buildRestSkeleton() places 27 rest-pose anchor points *inside*
///       the mesh AABB — wrist at the base of the finger axis, metacarpals
///       and finger joints stepping along it. The thumb sits on the thumb
///       side, detected from asymmetric mass in the width axis.
///   4.  buildJointWeights() gives every vertex up to `maxInfluences` (=4)
///       weights over rest anchors, weighted by inverse squared distance and
///       normalised.
///   5.  update(...) is called every frame. For each ARKit joint we compute
///       a rigid transform (rest → world), apply weighted-blend to each
///       vertex, then upload the new positions via `MeshResource.replace`.
@MainActor
final class UsdcSkinnedHand {

    // MARK: - Public API

    /// Root entity — add this into the scene once.
    let root = Entity()

    /// Loaded? Only true after `loadFromBundle()` completes successfully AND
    /// the mesh has enough vertices to actually run LBS.
    private(set) var isLoaded = false
    private(set) var loadError: String?

    init(name: String, tint: UIColor = UsdcSkinnedHand.defaultSkinTint) {
        root.name = name
        self.tint = tint
        self.material = Self.buildSkinMaterial(tint: tint)
    }

    /// Load `hand.usdc` from the app bundle. Idempotent.
    func loadFromBundle() async {
        guard !isLoaded, loadError == nil else { return }
        guard let url = Bundle.main.url(forResource: "hand", withExtension: "usdc")
              ?? Bundle.main.url(forResource: "hand", withExtension: "usdz") else {
            loadError = "hand.usdc not in bundle"
            return
        }
        do {
            let asset = try await Entity(contentsOf: url)
            asset.name = "\(root.name)-asset"

            guard let modelEntity = Self.findFirstMesh(in: asset) else {
                loadError = "no ModelEntity in hand.usdc"
                return
            }
            self.sourceModel = modelEntity
            self.modelEntity = modelEntity
            self.originalMesh = modelEntity.model?.mesh

            // Apply skin material (drops any usdc-authored materials).
            modelEntity.model?.materials = Array(
                repeating: material,
                count: max(modelEntity.model?.materials.count ?? 1, 1)
            )

            root.addChild(asset)
            root.isEnabled = false

            // The vertex buffer we write each frame contains WORLD-space
            // positions. For those to render at the intended world positions,
            // every transform between `root` (added at world origin by the
            // scene) and `modelEntity` must be identity — otherwise the
            // authored USDC transforms would apply on top of our LBS output.
            var node: Entity? = modelEntity
            while let n = node, n !== root {
                n.transform = Transform()
                node = n.parent
            }

            // Extract positions + normals + indices from the mesh so we can
            // rebuild them each frame.
            guard let mesh = modelEntity.model?.mesh else {
                loadError = "ModelEntity has no mesh"
                return
            }
            let contents = mesh.contents

            var flatRestPositions: [SIMD3<Float>] = []
            var flatRestNormals: [SIMD3<Float>] = []
            // Save each part's vertex range so we can re-emit them in order.
            var partRanges: [(modelID: String, partID: String, range: Range<Int>)] = []

            for model in contents.models {
                for part in model.parts {
                    let positions = part.positions.elements
                    let normals = part.normals?.elements
                        ?? Array(repeating: SIMD3<Float>(0, 1, 0), count: positions.count)
                    let start = flatRestPositions.count
                    flatRestPositions.append(contentsOf: positions)
                    flatRestNormals.append(contentsOf: normals)
                    let end = flatRestPositions.count
                    partRanges.append((model.id, part.id, start..<end))
                }
            }

            guard flatRestPositions.count > 20 else {
                loadError = "mesh has < 20 vertices (\(flatRestPositions.count))"
                return
            }

            self.restPositions = flatRestPositions
            self.restNormals = flatRestNormals
            self.partRanges = partRanges
            self.mutableContents = contents

            // Rest-pose analysis + weight table.
            let frame = Self.detectCanonicalFrame(positions: flatRestPositions)
            self.canonicalFrame = frame
            let skeleton = Self.buildRestSkeleton(
                positions: flatRestPositions,
                frame: frame
            )
            self.restJointPositions = skeleton
            self.vertexWeights = Self.buildJointWeights(
                positions: flatRestPositions,
                jointPositions: skeleton
            )

            // Live-update the mesh once so the skinned pose is initialised.
            self.workingPositions = flatRestPositions

            isLoaded = true
        } catch {
            loadError = error.localizedDescription
        }
    }

    func setVisible(_ visible: Bool) {
        root.isEnabled = visible && isLoaded
    }

    /// Drive the mesh from the same world-transforms map that the blue
    /// skeleton uses. Only translations are read.
    func update(
        worldTransforms transforms: [HandSkeleton.JointName: simd_float4x4],
        scale: Float = 1.0
    ) {
        guard isLoaded,
              let modelEntity,
              let mesh = modelEntity.model?.mesh,
              !restJointPositions.isEmpty,
              !vertexWeights.isEmpty else { return }

        // Anchor everything in the wrist's world position. If the wrist is
        // missing (tracking dropout) we bail — the last frame's mesh stays.
        guard let wristWorld = transforms[.wrist]?.translation else { return }

        // Build the world position for each rest-anchor. If an ARKit joint is
        // missing this frame, we fall back to the rest position offset from
        // the wrist so the mesh doesn't collapse.
        var jointWorld = [SIMD3<Float>](repeating: .zero, count: Self.jointOrder.count)
        for (i, joint) in Self.jointOrder.enumerated() {
            if let t = transforms[joint]?.translation {
                jointWorld[i] = t
            } else {
                // Rest anchor is expressed in the mesh's LOCAL frame around
                // wrist=origin. Fallback: place it at the same offset from
                // the tracked wrist.
                let restLocal = restJointPositions[i] - restJointPositions[wristIndex]
                jointWorld[i] = wristWorld + restLocal
            }
        }

        // Compute per-joint rigid delta = world - rest (translation only).
        // Rotation is derived from the vector to each joint's PARENT so the
        // finger segments stay straight between their endpoints.
        // For simplicity we use *translation-only* LBS here: each vertex
        // moves to the weighted sum of (rest_vertex - rest_joint + world_joint).
        // This preserves local mesh shape near each joint and only translates
        // groups of vertices — enough for a visually-correct skinning where
        // knuckle groups sit on the ARKit knuckles.
        //
        // A future upgrade could compute a full 4x4 per joint using the
        // parent->child direction; translation-only is chosen here because
        // it's stable and never introduces the up-side-down bug.
        let s = max(0.01, abs(scale))
        let count = restPositions.count

        // Reuse the working buffer to avoid allocating 5k SIMD3s every frame.
        if workingPositions.count != count {
            workingPositions = [SIMD3<Float>](repeating: .zero, count: count)
        }
        workingPositions.withUnsafeMutableBufferPointer { dst in
            for v in 0..<count {
                let restV = restPositions[v]
                let w = vertexWeights[v]
                var acc = SIMD3<Float>(0, 0, 0)
                for i in 0..<w.count {
                    let jIdx = Int(w[i].jointIndex)
                    let wt = w[i].weight
                    // Translation-only LBS:
                    //   world_v = world_joint + s * (rest_v - rest_joint)
                    let restJ = restJointPositions[jIdx]
                    let worldJ = jointWorld[jIdx]
                    let contribution = worldJ + (restV - restJ) * s
                    acc += contribution * wt
                }
                dst[v] = acc
            }
        }

        // Push into MeshResource. The collections' subscripts are get-only,
        // so we round-trip: fetch model, fetch part, overwrite positions,
        // put the mutated part back via `update`, then put the model back.
        for (modelID, partID, range) in partRanges {
            guard var model = mutableContents.models[modelID],
                  var part = model.parts[partID] else { continue }
            let slice = Array(workingPositions[range])
            part.positions = MeshBuffer<SIMD3<Float>>(slice)
            _ = model.parts.update(part)
            _ = mutableContents.models.update(model)
        }
        do {
            try mesh.replace(with: mutableContents)
        } catch {
            // Silently swallow — replacing the mesh can fail if the buffer
            // ownership becomes stale; the last-good frame stays on screen.
        }
    }

    // MARK: - Storage

    static let defaultSkinTint = UIColor(red: 0.90, green: 0.71, blue: 0.60, alpha: 1.0)

    private let tint: UIColor
    private let material: PhysicallyBasedMaterial

    private var sourceModel: ModelEntity?
    private(set) var modelEntity: ModelEntity?
    private var originalMesh: MeshResource?

    /// Rest positions in the mesh's local frame (right after load).
    private var restPositions: [SIMD3<Float>] = []
    private var restNormals: [SIMD3<Float>] = []
    private var partRanges: [(modelID: String, partID: String, range: Range<Int>)] = []
    private var mutableContents = MeshResource.Contents()

    /// Reusable working buffer for the skinned positions (avoids per-frame allocs).
    private var workingPositions: [SIMD3<Float>] = []

    /// The 27 rest-pose anchor points inside the mesh's local frame.
    private var restJointPositions: [SIMD3<Float>] = []
    /// Precomputed per-vertex blend weights.
    private var vertexWeights: [[JointWeight]] = []

    /// Canonical frame detected from the AABB (finger axis, palm normal, thumb side).
    private var canonicalFrame = CanonicalFrame()

    // MARK: - Joint order

    /// The 27 ARKit joints that participate in skinning, in a fixed order so
    /// we can index into arrays. Order matters because `vertexWeights` stores
    /// indices into this list.
    static let jointOrder: [HandSkeleton.JointName] = [
        .wrist,
        .forearmWrist, .forearmArm,

        .thumbKnuckle, .thumbIntermediateBase, .thumbIntermediateTip, .thumbTip,

        .indexFingerMetacarpal, .indexFingerKnuckle,
        .indexFingerIntermediateBase, .indexFingerIntermediateTip, .indexFingerTip,

        .middleFingerMetacarpal, .middleFingerKnuckle,
        .middleFingerIntermediateBase, .middleFingerIntermediateTip, .middleFingerTip,

        .ringFingerMetacarpal, .ringFingerKnuckle,
        .ringFingerIntermediateBase, .ringFingerIntermediateTip, .ringFingerTip,

        .littleFingerMetacarpal, .littleFingerKnuckle,
        .littleFingerIntermediateBase, .littleFingerIntermediateTip, .littleFingerTip
    ]

    private var wristIndex: Int { 0 }

    // MARK: - Support types

    private struct JointWeight {
        let jointIndex: UInt8
        let weight: Float
    }

    private struct CanonicalFrame {
        /// Unit vector along the fingers, in the mesh's local frame.
        var fingerAxis: SIMD3<Float> = SIMD3(0, 1, 0)
        /// Unit vector across the palm (thumb -> pinky), positive toward pinky.
        var widthAxis: SIMD3<Float> = SIMD3(1, 0, 0)
        /// Unit vector out of the back of the palm.
        var palmNormal: SIMD3<Float> = SIMD3(0, 0, 1)
        /// Center of the wrist plane in local space.
        var wristCenter: SIMD3<Float> = .zero
        /// Center of the fingertip plane in local space.
        var fingertipCenter: SIMD3<Float> = SIMD3(0, 0.16, 0)
        /// Half-width of the palm across the width axis.
        var halfWidth: Float = 0.05
    }

    // MARK: - Load helpers

    private static func findFirstMesh(in entity: Entity) -> ModelEntity? {
        if let m = entity as? ModelEntity, m.model != nil { return m }
        for child in entity.children {
            if let found = findFirstMesh(in: child) { return found }
        }
        return nil
    }

    /// Given a soup of vertex positions in local space, figure out which axis
    /// runs along the fingers (longest extent) and which is the palm normal
    /// (shortest extent). The remaining axis is the width axis. Thumb side is
    /// detected by looking at the volume on each half of the width axis at
    /// the wrist end — the thumb thickens one side.
    private static func detectCanonicalFrame(positions: [SIMD3<Float>]) -> CanonicalFrame {
        guard !positions.isEmpty else { return CanonicalFrame() }

        // AABB.
        var lo = positions[0]
        var hi = positions[0]
        for p in positions {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        let extent = hi - lo

        // Rank axes by extent (longest = finger, shortest = palm normal).
        let axes: [(idx: Int, size: Float)] = [
            (0, extent.x),
            (1, extent.y),
            (2, extent.z)
        ].sorted { $0.size > $1.size }
        let fingerAxisIdx = axes[0].idx
        let palmNormalIdx = axes[2].idx
        let widthAxisIdx = axes[1].idx

        func axisUnit(_ idx: Int) -> SIMD3<Float> {
            var v = SIMD3<Float>(0, 0, 0)
            v[idx] = 1
            return v
        }

        var frame = CanonicalFrame()
        frame.fingerAxis = axisUnit(fingerAxisIdx)
        frame.widthAxis = axisUnit(widthAxisIdx)
        frame.palmNormal = axisUnit(palmNormalIdx)

        // Wrist = low end of finger axis, tip = high end. Which end is which?
        // The wrist is thinner (the palm broadens toward the knuckles), so
        // choose whichever end has smaller cross-section spread.
        let mid = (lo + hi) * 0.5
        let lengthAlongFinger = extent[fingerAxisIdx]
        let sliceThickness = lengthAlongFinger * 0.15

        func widthAtSlice(near end: Float) -> Float {
            var maxW: Float = 0
            var minW: Float = .greatestFiniteMagnitude
            for p in positions {
                if abs(p[fingerAxisIdx] - end) < sliceThickness {
                    let w = p[widthAxisIdx]
                    if w > maxW { maxW = w }
                    if w < minW { minW = w }
                }
            }
            return maxW - minW
        }
        let widthAtLow = widthAtSlice(near: lo[fingerAxisIdx])
        let widthAtHigh = widthAtSlice(near: hi[fingerAxisIdx])
        let wristAtLow = widthAtLow <= widthAtHigh

        frame.wristCenter = mid
        frame.wristCenter[fingerAxisIdx] = wristAtLow ? lo[fingerAxisIdx] : hi[fingerAxisIdx]

        frame.fingertipCenter = mid
        frame.fingertipCenter[fingerAxisIdx] = wristAtLow ? hi[fingerAxisIdx] : lo[fingerAxisIdx]

        // If wrist was at "high", flip finger axis so it always points wrist→tip.
        if !wristAtLow {
            frame.fingerAxis = -frame.fingerAxis
        }

        // Detect which side of widthAxis holds the thumb: a hand mesh with a
        // thumb has extra area toward the wrist on one width-side. We look at
        // the average |width| coordinate near the wrist and see which side
        // wins. The thumb side is where mass is concentrated near the wrist
        // but OFFSET from wrist center along width.
        //
        // We measure signed mean of `widthAxis` for verts near the wrist end.
        var sumW: Float = 0
        var sumN: Float = 0
        for p in positions {
            let alongFinger = simd_dot(p - frame.wristCenter, frame.fingerAxis)
            if alongFinger > 0, alongFinger < lengthAlongFinger * 0.35 {
                sumW += p[widthAxisIdx] - frame.wristCenter[widthAxisIdx]
                sumN += 1
            }
        }
        let meanW = sumN > 0 ? sumW / sumN : 0
        // If the concentration is on the negative side, flip widthAxis so
        // positive width = pinky side (thumb on negative).
        if meanW > 0 {
            frame.widthAxis = -frame.widthAxis
        }

        // Half-width for spacing metacarpals.
        var minW: Float = .greatestFiniteMagnitude
        var maxW: Float = -.greatestFiniteMagnitude
        for p in positions {
            let w = simd_dot(p - frame.wristCenter, frame.widthAxis)
            minW = min(minW, w)
            maxW = max(maxW, w)
        }
        frame.halfWidth = max(0.02, (maxW - minW) * 0.5)

        return frame
    }

    /// Place 27 rest-pose anchors inside the mesh's local frame using the
    /// canonical axes. The positions are approximate — they don't need to
    /// hit the mesh's actual joint centers, only be close enough that the
    /// inverse-distance weights bind each vertex to the anatomically-right
    /// anchor (e.g. a vertex on the tip of the mesh's ring finger binds most
    /// strongly to `.ringFingerTip`).
    private static func buildRestSkeleton(
        positions: [SIMD3<Float>],
        frame: CanonicalFrame
    ) -> [SIMD3<Float>] {

        let f = frame.fingerAxis     // wrist → tip
        let w = frame.widthAxis      // thumb → pinky (positive to pinky)
        let n = frame.palmNormal     // back-of-hand normal
        let wrist = frame.wristCenter
        let tip = frame.fingertipCenter
        let length = simd_length(tip - wrist)   // wrist→tip distance
        let hw = frame.halfWidth

        // Column offsets across width axis. Convention: thumb sits at the
        // most-negative width, pinky at most positive.
        // Even fingers: index -0.2*hw, middle 0, ring +0.2*hw, pinky +0.55*hw
        // Thumb column: -0.75*hw
        func column(_ frac: Float) -> SIMD3<Float> { w * (frac * hw) }

        // Fingertip Y (along finger axis): tip position (fraction 1.0 of length).
        // Knuckles ≈ fraction 0.30 (base of fingers).
        // Metacarpals ≈ fraction 0.05 (just above wrist).
        func alongFinger(_ frac: Float) -> SIMD3<Float> {
            wrist + f * (length * frac)
        }

        // Small forward-lean along palm normal for the fingertips (not
        // essential; keeps rest pose slightly cupped).
        let curl: Float = 0.008

        var anchors = [SIMD3<Float>](repeating: .zero, count: jointOrder.count)

        anchors[0] = wrist                                // wrist
        anchors[1] = wrist - f * 0.03                     // forearmWrist
        anchors[2] = wrist - f * 0.14                     // forearmArm

        // Thumb — sits on the thumb side, angled toward the fingers.
        // We only need positions; the LBS math doesn't require rotation.
        anchors[3] = wrist + column(-0.6) + f * (length * 0.05)   // thumbKnuckle
        anchors[4] = wrist + column(-0.7) + f * (length * 0.16)   // thumbIntermediateBase
        anchors[5] = wrist + column(-0.75) + f * (length * 0.28)  // thumbIntermediateTip
        anchors[6] = wrist + column(-0.78) + f * (length * 0.36)  // thumbTip

        // Four fingers: metacarpal, knuckle, intermediateBase, intermediateTip, tip.
        // Fractions along finger axis for each joint.
        let fracs: (meta: Float, knuck: Float, base: Float, mid: Float, tip: Float) =
            (0.05, 0.42, 0.62, 0.80, 0.98)

        // Ordering: index, middle, ring, little.
        let columns: [Float] = [-0.28, 0.0, 0.28, 0.55]
        let indices: [(meta: Int, knuck: Int, base: Int, mid: Int, tip: Int)] = [
            (7, 8, 9, 10, 11),      // index
            (12, 13, 14, 15, 16),   // middle
            (17, 18, 19, 20, 21),   // ring
            (22, 23, 24, 25, 26)    // little
        ]

        for (finger, colOffset) in columns.enumerated() {
            let ii = indices[finger]
            let col = column(colOffset)
            anchors[ii.meta]  = wrist + col + f * (length * fracs.meta)
            anchors[ii.knuck] = wrist + col + f * (length * fracs.knuck)
            anchors[ii.base]  = wrist + col + f * (length * fracs.base) + n * curl
            anchors[ii.mid]   = wrist + col + f * (length * fracs.mid) + n * curl * 2
            anchors[ii.tip]   = wrist + col + f * (length * fracs.tip) + n * curl * 3
        }

        return anchors
    }

    /// For each vertex, pick the `maxInfluences` closest rest anchors and
    /// assign inverse-distance-squared weights, normalised to sum to 1.
    private static func buildJointWeights(
        positions: [SIMD3<Float>],
        jointPositions: [SIMD3<Float>]
    ) -> [[JointWeight]] {
        let maxInfluences = 4
        var table = [[JointWeight]]()
        table.reserveCapacity(positions.count)

        let jointCount = jointPositions.count
        for p in positions {
            // Compute (jointIndex, distSq) for every anchor.
            var distances = [(Int, Float)](); distances.reserveCapacity(jointCount)
            for j in 0..<jointCount {
                let d = simd_distance_squared(p, jointPositions[j])
                distances.append((j, d))
            }
            distances.sort { $0.1 < $1.1 }
            let picked = distances.prefix(maxInfluences)

            // Inverse-distance weighting with a small epsilon to avoid
            // divide-by-zero for a vertex exactly at an anchor.
            let eps: Float = 1e-6
            var raw = [Float](repeating: 0, count: picked.count)
            var sum: Float = 0
            for (i, entry) in picked.enumerated() {
                let w = 1.0 / (entry.1 + eps)
                raw[i] = w
                sum += w
            }
            var weights: [JointWeight] = []
            weights.reserveCapacity(picked.count)
            for (i, entry) in picked.enumerated() {
                weights.append(JointWeight(
                    jointIndex: UInt8(entry.0),
                    weight: sum > 0 ? raw[i] / sum : Float(1) / Float(picked.count)
                ))
            }
            table.append(weights)
        }
        return table
    }

    // MARK: - Material

    private static var cachedNormalTexture: MaterialParameters.Texture?

    private static func buildSkinMaterial(tint: UIColor) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: tint)
        material.roughness = 0.62
        material.metallic = 0.0
        material.specular = 0.35
        material.clearcoat = 0.15
        material.clearcoatRoughness = 0.35
        let warm = tint.blended(with: .white, fraction: 0.25) ?? tint
        material.emissiveColor = .init(color: warm)
        material.emissiveIntensity = 0.08
        material.blending = .opaque
        if let normal = skinNormalTexture() {
            material.normal = .init(texture: normal)
        }
        return material
    }

    private static func skinNormalTexture() -> MaterialParameters.Texture? {
        if let cached = cachedNormalTexture { return cached }
        guard let cg = makeSkinNormalCGImage(size: 256) else { return nil }
        do {
            let options = TextureResource.CreateOptions(semantic: .normal)
            let resource = try TextureResource.generate(
                from: cg,
                withName: "PhantomMirror.UsdcSkin.Normal",
                options: options
            )
            let tex = MaterialParameters.Texture(resource)
            cachedNormalTexture = tex
            return tex
        } catch {
            return nil
        }
    }

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

// MARK: - UIColor blending helper (fileprivate copy so we don't collide with other files)

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
