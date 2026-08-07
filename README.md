# PhantomMirror

Vision Pro demo: **intact-hand tracking → mirrored phantom hand** (classic mirror therapy, zero EMG).

> Creative prototype for demonstration — **not a medical device**. Do not claim treatment of phantom limb pain.

## Requirements

- Mac with Xcode 16+ (visionOS SDK)
- **Apple Vision Pro** (hand tracking does **not** work in the Simulator)
- Apple Developer account + team set in Xcode for device signing

## Open & run

```bash
open /Users/event/PhantomMirror/PhantomMirror.xcodeproj
```

1. Select the **PhantomMirror** target
2. Set your **Team** under Signing & Capabilities
3. Add capability **Hands Tracking** if Xcode prompts (Info.plist already has usage strings)
4. Select your Vision Pro device → **Run**

## Demo flow

1. **Onboarding** — choose missing side, optional NRS score
2. **Calibrate** — offset / scale / yaw for telescoping
3. **Training**
   - Open / Close (4 cycles)
   - Touch 3 orbs with the phantom index tip
   - Bimanual: cyan cube (intact) + amber cube (phantom)
4. **Report** — duration, tracking %, latency, NRS

## Architecture

```
Intact Hand (ARKit HandTrackingProvider)
        ↓
  27 joint transforms
        ↓
MirrorTransform (reflect across head sagittal plane)
        ↓
Phantom hand (procedural joint spheres + bones)
        ↓
RealityKit ImmersiveSpace (mixed MR)
```

Virtual hands are **procedural** (no USDZ required). You can later swap in a rigged `RightHand.usdz` aligned to `HandSkeleton.JointName`.

## Privacy

- Hand / world data processed **on-device only**
- No network upload in this demo
