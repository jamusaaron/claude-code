# Device release gate

Every item below is **pending** until someone runs it on hardware and records the result. Desktop checks (syntax, format validators, unit tests) do not replace these. For each run, record the device model, iOS version, app build, scene conditions and any exported test files.

## Build and lifecycle

- [ ] Build the `LidarMeasure` scheme for a device with no errors. Run the MeasureCore tests (⌘U, or `swift test` in `Packages/MeasureCore`).
- [ ] Install on a LiDAR iPhone and check the app icon, onboarding pages, dark interface and device check ("LiDAR detected").
- [ ] Camera permission:
  - first grant;
  - deny;
  - relaunch;
  - return from Settings after granting and after revoking.
- [ ] Simulator and a non-LiDAR device both show the "LiDAR not available" state, with Library and Settings still working.
- [ ] Switch Measure ↔ Scan repeatedly.
  - There is one camera with no black flash.
  - Points stay put.
  - Instruments shows one ARSession.
- [ ] Open Library and Settings: the camera indicator goes off.
- [ ] Background and foreground, lock and unlock, an incoming call, and Control Centre.
  - Resuming in Measure shows the "Session interrupted" banner until tracking is normal.
  - A scan in progress freezes and goes to review; its frames and mesh are kept.
- [ ] Settings → Restart tracking while on the Settings tab: the camera must **not** start. Returning to Measure starts a fresh world with no stale points.
- [ ] Leave Scan while recording: the "Finish the scan first?" dialog appears. Both choices behave as labelled.
- [ ] Larger Dynamic Type sizes and VoiceOver.
  - The crosshair and the **+** button target the same point.
  - Every control is reachable and labelled.

## Measurement quality

- [ ] Repeat distances of 0.3, 1, 2 and 4 m against a tape or laser measure, 10 times each. Record mean error and spread, and compare with the displayed ±. Re-tune `AccuracyModel` coefficients if they're consistently off.
- [ ] Move around placed endpoints. Values should stay stable as anchors and refinement settle (refinement moves points by at most 2 cm).
- [ ] Areas:
  - horizontal, vertical and tilted;
  - convex and concave;
  - a crossing outline and a duplicate tap (both refused with a message);
  - a non-flat outline (caveat shown, grade lowered);
  - Undo, and the 3-point rectangle.
- [ ] Volume:
  - base close;
  - height preview;
  - a top point on the base (refused);
  - Undo of height;
  - mode change, save and clear;
  - the prism caveat is visible.
- [ ] Snapping:
  - box edges and corners (the snapped point sits on the true edge, not inside the bevel);
  - floor/wall plane;
  - an object in front of a wall (no snapping through to the wall);
  - each snap toggle off.
- [ ] Hard surfaces: low light, mirror, window glass, glossy black, thin cable or chair leg, under 0.15 m and over 5 m.
  - Nothing is silently accepted. Expect warnings, "No reliable LiDAR surface", or a low grade.
- [ ] Placement while tracking is limited is refused with a message.
- [ ] Units: mm, cm and m for length; mm², cm² and m² for area; cm³, L and m³ for volume. Honest precision drops digits; no imperial units anywhere.
- [ ] Save a named measurement, relaunch, then export CSV. Check:
  - `id` column;
  - quoted names;
  - UTC timestamps;
  - SI values;
  - display values;
  - notes;
  - opens correctly in Numbers and Excel.

## Capture and export

- [ ] Object scan (with box) and room scan (whole scene) in uneven light.
  - Mesh and keyframe counts rise.
  - Warnings appear when relevant.
  - Texture coverage is plausible.
- [ ] Scan without moving (no keyframes): review says the model can't be textured, and the texture material isn't offered.
- [ ] Fit the box to a measurement taken in Measure: the box lands around the measured object.
- [ ] Reach the scan size limit. Profile memory in Instruments for 15 minutes or more, finish several scans, and confirm memory is reclaimed.
- [ ] Cleanup options:
  - crop and margin;
  - support-surface removal;
  - simplify 0–5 cm;
  - noise threshold;
  - re-process without rescanning.
- [ ] Force failures (crop away everything; fill the disk). Messages should be actionable, and Back or Adjust should keep the scan.
- [ ] Open a device-captured USDZ in the in-app viewer and in AR Quick Look. Check:
  - orientation;
  - metre scale (true size in AR);
  - texture;
  - orbit, pinch and pan;
  - lighting controls.
- [ ] Share USDZ, GLB and the OBJ zip through Files and AirDrop. Open each in other viewers (Reality Converter, Blender, an online glTF viewer). Check materials and scale, and that README.txt is in the OBJ zip.
- [ ] Inspect grey regions and seams against what the camera saw. No texture may project through a foreground occluder.
- [ ] Volume:
  - a closed test object reports "Closed mesh" and matches a known volume;
  - an object on a table reports "Closed above base";
  - a room scan reports no volume.
- [ ] Kill the app right after tapping Save on a model. Relaunch: the Library reports the model as recovered, with its name.
- [ ] Delete a model's folder by hand (in Xcode's container view): the Library lists it under "Files missing" with Remove.
- [ ] Delete a measurement and a model with swipe. Only that item and its files go.

## Release record

Record results, device details and any unresolved failures here or in the release tracker. A production release needs the iOS build, the physical measurement trials, on-device capture and export compatibility, and the sustained-memory checks above.
