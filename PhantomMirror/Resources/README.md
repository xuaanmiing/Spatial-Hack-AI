# RightHand_ARKit27

Procedural **right-hand** USD model with **27 joints**, ordered to match `ARKit.HandSkeleton.JointName.allCases` on visionOS.

## Files

| File | Description |
|------|-------------|
| `RightHand_ARKit27.usdz` | Packed model for RealityKit / Quick Look |
| `RightHand_ARKit27.usda` | ASCII source (editable) |

The generated USDZ contains a crate-format `RightHand_ARKit27.usdc` root layer.

## Joint order (0–26)

```
0  wrist
1  thumbKnuckle
2  thumbIntermediateBase
3  thumbIntermediateTip
4  thumbTip
5  indexFingerMetacarpal
6  indexFingerKnuckle
7  indexFingerIntermediateBase
8  indexFingerIntermediateTip
9  indexFingerTip
10 middleFingerMetacarpal
11 middleFingerKnuckle
12 middleFingerIntermediateBase
13 middleFingerIntermediateTip
14 middleFingerTip
15 ringFingerMetacarpal
16 ringFingerKnuckle
17 ringFingerIntermediateBase
18 ringFingerIntermediateTip
19 ringFingerTip
20 littleFingerMetacarpal
21 littleFingerKnuckle
22 littleFingerIntermediateBase
23 littleFingerIntermediateTip
24 littleFingerTip
25 forearmWrist
26 forearmArm
```

## Rest pose convention (Apple sample)

- Fingers along **-Z**
- Palm facing **-Y**
- Origin at **wrist base**

## Drive from ARKit (sketch)

```swift
let hand = try await Entity(named: "RightHand_ARKit27")
// or ModelEntity(named:in:) from the USDZ in the bundle

hand.transform = Transform(matrix: handAnchor.originFromAnchorTransform)
for (index, joint) in handSkeleton.allJoints.enumerated() {
    let q = simd_quatf(joint.parentFromJointTransform)
    // If loaded as ModelEntity with skeletal poses:
    // model.jointTransforms[index].rotation = q
}
```

## Regenerating

```bash
python3 Scripts/generate_arkit_hand.py
```

## Notes

- This is a **blocky procedural mesh** (demo / binding reference), not a photoreal glove.
- For production look, retarget a sculpted glove onto this same 27-joint skeleton.
- Left hand: mirror the mesh / skeleton in X, or mirror joint poses in code (as PhantomMirror does).
