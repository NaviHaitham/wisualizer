# Labels tests

Use the custom Godot build and RealityKit addon described in the root README.

## Desktop regression checks

```sh
godot --headless --path . --script res://tests/labels_test.gd
godot --headless --path . --script res://tests/labels_click_test.gd
godot --headless --path . --script res://tests/labels_routing_test.gd
godot --headless --path . --script res://tests/document_integration_test.gd
godot --headless --path . res://tests/label_edit_test.tscn
```

This writes fixtures to `builds/labels-tests/` and exits with a nonzero code
when a check fails.

The click runner checks tap selection at all 16 frames, release and canceled
input, switching labels, frame ranges, and clearing selection when labels or
their parent are hidden. It also checks shared collision shapes, keeping the
physical target size during resizing, and avoiding shape updates while the
size stays unchanged. It invokes the input callback and collision signal;
it does not verify simulator mouse delivery.

The routing runner first verifies that a real physics ray hits the model's
Grab bounds before a label inside them. It then sends native spatial events
through Grab's connected signal to verify label selection, rotation, gesture
capture, camera projection, canceled input and ordinary model dragging.

The document integration runner uses the fixture from `labels_test.gd`. It
checks the Labels switch after moving labels into the turntable, fitting
rotated labels (including documents with only labels), and TeX rendering and
preview refresh. The custom engine must include its MathJax module.

The editing runner opens **Edit labels** on a real document, checks validation,
saves through the worker thread, and verifies Save As, in-place text/position/
range refresh, stable volume/model nodes, and unchanged non-label ZIP members.
Set `LABEL_EDIT_ZIP` to test another ZIP with at least two labels. On visionOS
it defaults to `user://Hall sensor-3d-labels-test.zip` and writes
`user://label-edit-tests/results.json`. To package that runner, pass
`-- --edit-labels` to `pack_visionos_labels_test.gd`; install its
`label-edit-test.pck` as the app's `wisualizer.pck`.

## Native visionOS simulator

Boot an Apple Vision Pro simulator in Xcode's Device Hub, then prepare a
separate test pack. It contains the production resources plus a test entry
scene; the app's normal entry scene in `project.godot` stays unchanged.

```sh
mkdir -p builds/simulator-test
godot --headless --path . --export-debug visionOS builds/simulator-test/wisualizer.xcodeproj
godot --headless --path . --script res://tests/pack_visionos_labels_test.gd
cp builds/simulator-test/simulator-test.pck builds/simulator-test/wisualizer.pck
xcodebuild -project builds/simulator-test/wisualizer.xcodeproj -scheme wisualizer -sdk xrsimulator -destination 'generic/platform=visionOS Simulator' -derivedDataPath builds/simulator-test/DerivedData CODE_SIGNING_ALLOWED=NO build
xcrun simctl install booted builds/simulator-test/DerivedData/Build/Products/Debug-xrsimulator/wisualizer.app
test_data="$(xcrun simctl get_app_container booted com.zilongpa.wisualizer data)"
cp builds/labels-tests/labels.zip "$test_data/Documents/labels.zip"
xcrun simctl launch --terminate-running-process booted com.zilongpa.wisualizer
```

Run the desktop regression checks first to create `labels.zip`. Once
`$test_data/Documents/simulator-results.json` reports `stage: complete`, its
`failures` array must be empty. The native runner verifies 45 conditions:
native backend selection, aim-pose binding, proximity and hysteresis, frame
filtering, the Labels switch, deleting a frame in the workspace, saving and
opening the edited ZIP, and rejecting invalid ranges. Native spatial taps
also cover selection, switching, canceled input, hiding labels and rotation.
It also typesets a formula using the simulator engine's MathJax module. Input
through the model's Grab bounds checks selection and gesture capture.
Controller poses are injected through `XRServer`, and `InputEventSpatialTouch` events are
emitted through the collision signals; physical accessory tracking and OS
mouse delivery are not covered.

For screenshots, launch with `SIMCTL_CHILD_LABEL_SIM_SCREENSHOTS=1`. Each stage
then pauses for up to 45 seconds. Capture with `xcrun simctl io booted screenshot`
and write the current stage name to `$test_data/Documents/simulator-continue.txt`
to advance. The test leaves its windows open for inspection.

The test retains the original volume when opening the edited one. During the
2026-10-24 run, closing the first volume exited the app with a native
GodotRealityKit crash; it remains a separate issue. The plugin also emitted
`SkeletonLoader` and null-mesh errors during rendering. Passing the label
checks does not resolve those plugin errors.
