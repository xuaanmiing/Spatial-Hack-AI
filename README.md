# PhantomMirror

> Spatial Mirror Therapy for Phantom Limb Pain — reimagined for Apple Vision Pro.

PhantomMirror is a visionOS demonstration that adapts **Dr. V.S. Ramachandran's Mirror Box Therapy** for spatial computing. In Passthrough mode, it tracks the user's intact hand and short forearm, mirrors their ARKit joint motion across the body's central axis, and renders a synchronized virtual counterpart on the missing side.

---

## The Clinical Problem

Phantom Limb Pain is a debilitating condition where the brain sends motor commands to a missing or paralyzed limb and, receiving no visual or sensory feedback, interprets the void as intense physical pain.

The clinical gold standard is **Mirror Box Therapy** — a neuroplasticity intervention using a physical mirror to reflect the intact limb, tricking the brain into resolving the feedback loop. But traditional mirror boxes are:

- Ergonomically restrictive (fixed seating, single-plane movement)
- Limited to 2D reflections
- Unable to capture patient data or track progress
- Non-portable and clinic-bound

## Our Solution

PhantomMirror runs on **Apple Vision Pro** and places a real-time 3D mirrored hand and short forearm into the user's physical space. It does not currently estimate or render the elbow, upper arm, or shoulder.

This restores visual feedback to the somatosensory cortex, promotes neuroplasticity, and relieves pain — while capturing rich clinical telemetry that has never before been possible in mirror therapy.

---

## Key Features

- **Passthrough Spatial Mirroring** — Virtual limb rendered directly into the user's real environment via Vision Pro Passthrough.
- **Real-time Hand Tracking** — Joint updates using visionOS `HandTrackingProvider`.
- **Central-axis Coordinate Transformation** — Mathematically mirrored joint positions and rotations across the user's body midline.
- **Three Guided Demo Tasks** — Open/close, touch targets, and bilateral matching.
- **Session Summary** — In-memory task, tracking-update, duration, and optional NRS values.
- **No 3D World-building Required** — Runs in Passthrough, keeping development focused on the therapy engine.

---

## Technical Architecture

### 1. Spatial Coordinate Transformation Engine
The core engine uses `HandTrackingProvider` from ARKit on visionOS to capture the intact hand's joint positions and rotations every frame. Each joint transform is mirrored across the user's central sagittal plane, then applied to a 3D hand mesh anchored on the opposite side of the body.

```
Intact Hand Joint (x, y, z)  →  Mirror across body axis  →  Phantom Hand Joint (-x, y, z)
```

### 2. Rendering
- **RealityKit** entities driven by mirrored joint transforms
- Passthrough rendering via `ImmersiveSpace` in mixed immersion style
- Skeletal 3D hand mesh with skinning weights aligned to visionOS joint hierarchy

### 3. Session Reporting
- In-memory session duration, task count, tracking success, and hand-update interval
- Optional pre/post NRS values
- Persistent telemetry, trend analytics, and LLM reports remain roadmap items

---

## Tech Stack

| Layer | Technology |
|-------|------------|
| Platform | visionOS 2.0+ |
| Language | Swift 5.9+ |
| Spatial Rendering | RealityKit |
| Hand Tracking | ARKit `HandTrackingProvider` |
| UI | SwiftUI |
| Data | Swift Concurrency + Codable telemetry logs |
| Reporting | In-memory Swift model (persistent/AI reporting planned) |
| Tooling | Xcode 16+ |

---

## Requirements

- Apple Vision Pro (visionOS 2.0 or later)
- Xcode 16+
- Apple Developer account (for on-device deployment)
- macOS Sonoma 14.5+ (for development)

---

## Getting Started

### Clone the repo
```bash
git clone https://github.com/<your-username>/Spatial-Hack-AI.git
cd Spatial-Hack-AI
```

### Open in Xcode
```bash
open PhantomMirror.xcodeproj
```

### Configure signing
1. Open the project in Xcode.
2. Under **Signing & Capabilities**, set your development team.
3. Ensure the **Hand Tracking** privacy usage description is set in `Info.plist`.

### Run
- Select the **Apple Vision Pro** destination (device or simulator).
- Hit **Cmd + R**.
- On first launch, grant hand tracking permission.

---

## Usage

1. Launch PhantomMirror on Vision Pro.
2. Select which limb is affected (left or right).
3. Enter the immersive session — a virtual limb will appear where your missing/affected limb would be.
4. Move your intact hand slowly — the phantom limb mirrors your motion in real time.
5. At session end, log your pain score (0–10 VAS).
6. Review the local session summary.

---

## Roadmap

- [x] Passthrough immersive space
- [x] Hand tracking → joint capture
- [x] Central-axis mirror transformation
- [x] Virtual limb rendering
- [ ] Telemetry logging pipeline
- [ ] Pain score input UI (VAS slider)
- [ ] LLM-based clinical report generation
- [ ] Physiotherapist web dashboard
- [ ] Multi-session trend analytics
- [ ] Bilateral training modes

---

## Hackathon Context

Built for a **3-day spatial computing sprint** under Brief 4 (Apple Vision Pro).

The strategic advantage: because PhantomMirror runs in **Passthrough**, we avoid the heavy overhead of 3D environment building. Development bandwidth is dedicated entirely to:
- Coordinate transformation math
- Spatial UI overlays
- Clinical data analytics

This delivers an **emotionally resonant, clinically backed demo** with minimal asset overhead.

---

## Clinical Grounding

This project is inspired by decades of published neuroscience research, most notably:

- Ramachandran, V.S. & Rogers-Ramachandran, D. (1996). *Synaesthesia in phantom limbs induced with mirrors.* Proceedings of the Royal Society B.
- Chan, B.L. et al. (2007). *Mirror Therapy for Phantom Limb Pain.* New England Journal of Medicine.

PhantomMirror is a research and demonstration prototype. It is **not a certified medical device** and should not replace clinical guidance from a licensed physiotherapist.

---

## Team

Built during the Spatial Hack AI hackathon.

---

## License

TBD — add a license file before public release.

---

## Contact

For questions, feedback, or clinical collaboration inquiries, please open an issue on this repository.
