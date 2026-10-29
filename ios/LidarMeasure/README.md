# LiDAR Measure (iOS)

A SwiftUI + ARKit + RealityKit app for metric measurement and 3D capture with the iPhone/iPad LiDAR Scanner. Everything runs on the device; nothing is uploaded.

- **Measure:** live point-to-point distance, polygon area and prism volume (rooms, boxes). Values are in mm, cm or m with an honest ± uncertainty and a confidence colour.
- **Snapping:** to detected planes, to fitted edges and corners of the LiDAR mesh, and to existing points.
- **Library:** named, timestamped measurements with CSV export, plus captured 3D models.
- **Scan:** captures the LiDAR mesh of a whole scene or a boxed object, cleans it up (crop, simplify, remove noise), textures it from camera keyframes and exports USDZ (primary), OBJ and glTF (.glb).
- **Viewer:** RealityKit orbit, zoom and pan with lighting controls, plus AR Quick Look at true scale.

## Requirements

| | |
|---|---|
| Device | iPhone 12 Pro or later Pro model, or iPad Pro (2020 or later). LiDAR is checked at runtime. Other devices get a library-only experience. The Simulator cannot run AR. |
| OS | iOS 17.0+ |
| Xcode | 16 or later (the project uses Xcode 16's synchronised folders) |

## Build and run

1. Open `LidarMeasure.xcodeproj`.
2. Select the **LidarMeasure** target. Under **Signing & Capabilities**, choose your team and change the bundle identifier from `com.example.lidarmeasure` to one you own.
3. Select a connected LiDAR device and run.

Core unit tests (geometry, accuracy model, mesh cleanup, snapping, texture projection, exporters):

```sh
cd Packages/MeasureCore && swift test      # macOS or Linux
```

The same tests run from the Xcode scheme's Test action (⌘U).

If the project ever fails to open (for example in an older Xcode), regenerate it with XcodeGen from `project.yml`: `brew install xcodegen && xcodegen generate`.

## One camera, two tools

Measure and Scan share a single ARKit session and RealityKit view (`ARSessionHost`).

- Switching between them never pauses tracking. Placed points and the reconstructed mesh stay in one coordinate system, so Scan can fit its capture box to your last measurement.
- The camera turns off completely in the Library and Settings.
- After any pause or interruption:
  - an in-progress scan is frozen, never extended into a possibly shifted world;
  - on-screen measurements are flagged until tracking is normal again;
  - a full "Restart tracking" clears everything world-based.

## Project layout

```
LidarMeasure.xcodeproj         Xcode 16 project (synchronised folder + local package)
Config/Info.plist              camera usage text, portrait, ARKit capability
LidarMeasure/
  App/                         @main app, RootView (onboarding gate, tabs, permission/device gates)
  AR/                          shared session host, depth/confidence sampling, mesh access, snapping resolver, warnings
  Measure/                     ARMeasureView, MeasureController, RealityKit renderer, HUD, label overlay
  Capture/                     ModelCaptureView, CaptureController, keyframes, mesh extraction, atlas, pipeline
  Library/                     LibraryView, SwiftData models, ModelStore (files and exports)
  Viewer/                      ModelViewerView (RealityKit orbit viewer, AR Quick Look, export)
  Settings/                    SettingsView, AppSettings, accuracy explainer
  Onboarding/                  requirements, honest accuracy, camera permission
  Resources/                   asset catalog, privacy manifest
docs/DEVICE_VALIDATION.md      on-device release checklist
Packages/MeasureCore/          framework-free Swift package (builds and tests on macOS and Linux)
  Sources/MeasureCore/
    Math, Units, Geometry      vectors, rigid transforms, metric formatting, polygon area, prism and mesh volume
    Accuracy                   per-point error model and propagation to distance, area and volume
    Snapping                   plane clustering and edge/corner intersection
    Mesh                       TriangleMesh, crop, weld, vertex-clustering simplification, noise removal, topology
    Texturing                  multi-view projective texturing and atlas layout
    Export                     USDZ (USDA + aligned zip), GLB, OBJ/MTL zip, CSV, internal mesh archive
  Tests/MeasureCoreTests/
```

## The LiDAR pipeline

1. **Sensor.** The dToF LiDAR fires a sparse grid of laser dots. ARKit fuses the returns with the camera into a 256×192 depth map every frame (`sceneDepth`, or `smoothedSceneDepth` averaged over frames), with a per-pixel confidence map (low/medium/high).
2. **Reconstruction.** With `sceneReconstruction` on, ARKit integrates depth over time into a triangle mesh delivered as `ARMeshAnchor` chunks, optionally with per-face classification (floor, wall, table…).
3. **Tracking.** Visual-inertial odometry puts all of this in one metric world frame: metres, with +Y opposite gravity.

**Measuring a point.** `SurfaceResolver` combines every source:

1. An existing point within 22 pt on screen, so polygons close exactly.
2. Otherwise, a RealityKit ray cast against the fused LiDAR mesh (scene-understanding collision).
3. Failing that, the depth-map median under the pixel, unprojected through the camera intrinsics, then ARKit's estimated plane as a last resort.

Every candidate must then be **supported**: its distance along the camera axis must agree with the LiDAR depth under the pixel (within max(5 cm, 4%)), or reconstructed mesh must exist within 4 cm.

- Planes that disagree with the depth are rejected. They are usually the wall behind the object you're aiming at.
- Mesh hits that disagree are kept but downgraded.
- Points closer than 15 cm are rejected, and beyond 5 m only points on reconstructed geometry are accepted.

The point is then refined:

- **Plane:** if it agrees with a detected plane to within max(2 cm, 1% of range), it is projected onto that plane. The plane is a least-squares fit over hundreds of samples.
- **Edge or corner:** `SnapGeometry` clusters nearby mesh triangles by normal, fits a plane to each face, and intersects two planes for an edge or three for a corner. The LiDAR mesh rounds sharp edges into 1–3 cm bevels; intersecting the flat faces recovers the true edge.

**Placement rules:**

- Points are refused while tracking is limited.
- A point within 5 mm of the previous one is refused, as an accidental double tap.
- Outlines are capped at 64 corners.
- Closing an outline that crosses or touches itself, repeats a corner, or is collinear is refused with a message.
- A volume's top point must be at least 5 mm off the base.

Each point becomes an `ARAnchor`, so when ARKit refines its map the points move with it and the values update live. Free-surface points (mesh or raw depth) are also re-sampled along the current view ray as the mesh improves. They blend 20% per pass and never move more than 2 cm from the anchor. Plane, edge and corner points are already fits, so they are left alone.

**Capturing a model.**

1. While scanning, `KeyframeRecorder` stores sharp, well-spaced frames (motion and novelty gated) as 1024-px JPEGs. It saves the LiDAR depth alongside, with low-confidence pixels zeroed.
2. On stop, every `ARMeshAnchor` is copied into one world-space mesh. Winding is checked against ARKit's normals, so exports never come out inside-out.
3. `ModelPipeline` crops to the capture box, removes the support surface, welds chunk borders, simplifies by vertex clustering and removes small disconnected pieces.
4. Each triangle is textured from the single keyframe that sees it best: facing the camera, within 5 m, and central.
   - That keyframe's own LiDAR depth must agree with the triangle's centre, and none of its corners may be hidden behind a nearer surface.
   - Views whose depth can't be checked are heavily penalised, so a verified view always wins.
   - A scan with no keyframes is offered plain materials only.
5. The chosen frames are packed into an atlas of up to 4096 px, with exposure normalised between frames and optional colour correction. The model is re-centred to its base and written as USDZ.

## Accuracy: what the numbers mean

Phone LiDAR is **not survey-grade**. The app says so in onboarding, in Settings → About accuracy, and next to every value.

- **±.** Each value shows an estimated 1σ uncertainty from `AccuracyModel`:
  - per point: `σ = (3 mm + 5 mm × range)`, ×2 for medium depth confidence, ×4 for low;
  - by placement method: plane 0.75×, raw depth pixel 1.3×, estimated plane 2.5×;
  - limited tracking: ×2; beyond 5 m, error grows fast;
  - distances add 0.5% of length for tracking drift;
  - areas and volumes propagate vertex errors to first order.

  These coefficients are an engineering estimate consistent with published iPhone 12/13 Pro evaluations (about ±1 cm for objects over 10 cm at close range). They are not a per-device calibration.
- **Confidence colour.** Green means within about 1 cm and 2%. Amber means within about 3 cm and 6%. Red means treat the value as approximate. Small objects go red quickly: ±5 mm on 4 cm is 12%.
- **Honest precision.** This is on by default. The displayed decimals stop at the first uncertain digit, so ±2 cm shows as `1.24 m`, not `1.2437 m`.
- **Warnings.** Banners appear for:
  - limited tracking;
  - low light;
  - reflective, transparent or dark surfaces (centre of the confidence map mostly low);
  - edges and thin objects (depth discontinuity under the reticle);
  - beyond about 5 m, or closer than 20 cm;
  - no LiDAR return;
  - thermal throttling;
  - interruptions;
  - scan memory pressure.
- **Object volume.** Mesh topology is checked first: boundary, non-manifold and inconsistently wound edges, and the number of connected pieces.
  - **Closed mesh:** a single closed, consistently oriented piece gets the exact enclosed volume.
  - **Closed above base:** an object scan whose only opening is the bottom gets the volume between the surface and the support plane (divergence theorem).
  - **Mesh has holes:** with holes, several pieces or flipped faces, the number is marked approximate.
  - Rooms and other open scans get no volume rather than a guess.
- **Prism volumes** (Measure → Volume) always carry the caveat that they assume a constant cross-section.
- **Scale in AR Quick Look.** Content scaling is disabled, so a 40 cm object stays 40 cm.

## Library safety

- Each model folder's `meta.json` holds its stats, material, name, date and scope. The name is written *before* the folder is committed to the library.
- If the app is killed between saving the files and saving the record, the Library re-registers the folder on next launch ("Recovered N models").
- Entries whose files have gone are listed under "Files missing", each with a Remove button.
- Model folders and OBJ exports carry a `README.txt` explaining units, axes, texturing and limits.
- CSV rows include the record `id`, so repeated exports can be de-duplicated.

## Memory and performance

- Keyframes go to disk as they are captured: at most one frame is in flight, and at most 100 frames (~35 MB of disk). The AR session is never starved of camera buffers.
- The scan shows live vertex counts against a budget you choose (300k, 600k or 1M vertices). It warns at 85% and stops at 120%. It also stops when iOS posts a memory warning.
- The session is paused during processing. Cleanup and texturing run off the main thread and can be cancelled. The atlas is composed cell by cell, with peak memory around one 4096² bitmap.
- Measuring work is throttled: the reticle resolves at about 20 Hz and warnings at about 5 Hz. Labels are UIKit views moved each frame, not SwiftUI updates.

## Export formats

| Format | Contents | Notes |
|---|---|---|
| USDZ | `model.usda` + `textures/texture.jpg`, stored uncompressed, 64-byte aligned | Metres, +Y up, `UsdPreviewSurface`, double-sided. Opens in AR Quick Look, Reality Composer, Blender. |
| GLB | glTF 2.0 binary with embedded JPEG | Metres, +Y up, metallic-roughness material. |
| OBJ (zip) | `.obj` + `.mtl` + `texture.jpg` | Metres, +Y up. V is flipped for OBJ's bottom-left UV origin. |
| CSV | one row per measurement | SI values with `.` decimals for spreadsheets, plus the value as displayed. Session-relative point coordinates. UTF-8 with BOM. |

## Release gate

[`docs/DEVICE_VALIDATION.md`](docs/DEVICE_VALIDATION.md) is the on-device checklist that must pass before release: lifecycle, measurement trials against a reference, capture/export compatibility and sustained memory. None of it can be done without hardware.

## Verification done for this drop

The code was written without access to Xcode or a device. What has and hasn't been verified:

- **Swift syntax:** every Swift file parses cleanly with tree-sitter-swift. A broken sample confirmed the checker catches errors.
- **Export formats:** a byte-for-byte Python mirror of the Swift exporters produced sample files, checked against reference tools:
  - USDZ passes all 30 OpenUSD 26.11 validators, including the USDZ package, root package, material binding and shader checks. Zip entries are stored, CRC-valid and 64-byte aligned.
  - GLB passes the Khronos glTF Validator with 0 errors and 0 warnings.
  - The OBJ bundle loads with UVs and texture in trimesh, with a positive (outward) volume.
- **Maths:** the open-bottom mesh volume and the plane/edge/corner intersection formulas were checked numerically against analytic values.
- **Project file:** `project.pbxproj` parses and every object reference resolves. The plists, asset catalog JSON and scheme XML are valid.
- **Not yet verified:** a full `xcodebuild` compile, `swift test`, and testing on device. Run these first. If something doesn't compile, the likeliest causes are SDK-specific API signatures in the ARKit/RealityKit layer; the core package is plain Swift.
