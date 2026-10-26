extends SceneTree
## Checks the collision-object input path used by RealityKit spatial taps.
const Labels := preload("res://app/labels.gd")
const Meta := preload("res://app/meta.gd")

class TestVolume extends SpatialVolume3D:
	func _enter_tree() -> void:
		pass

	func get_controllers() -> Array[XRController3D]:
		return []

var checks := 0
var failures := []

func check(ok: bool, description: String) -> void:
	checks += 1
	if not ok:
		failures.append(description)
		print("FAIL: ", description)

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(800, 600)
	viewport.own_world_3d = true
	root.add_child(viewport)
	var camera := Camera3D.new()
	camera.position.z = 10
	viewport.add_child(camera)
	camera.make_current()
	var volume := TestVolume.new()
	viewport.add_child(volume)
	var unopened_volume := SpatialVolume3D.new()
	check(unopened_volume.get_controllers().is_empty(), "volume has no controllers before backend initialization")
	unopened_volume.free()
	var labels := Labels.new()
	viewport.add_child(labels)
	labels.volume = volume
	var first := Meta.PointLabel.new()
	first.text = "Global"
	first.frames = Vector2i(0, 15)
	var second := Meta.PointLabel.new()
	second.text = "Frame 8"
	second.frames = Vector2i(7, 7)
	second.position.x = 3
	labels.set_labels([first, second])
	var press := InputEventScreenTouch.new()
	press.pressed = true
	var release := InputEventScreenTouch.new()
	var canceled := InputEventScreenTouch.new()
	canceled.pressed = true
	canceled.canceled = true
	labels._on_label_input(camera, canceled, Vector3.ZERO, Vector3.UP, 0, 0)
	check(labels._selected == -1, "canceled touch does not select a label")
	var right_click := InputEventMouseButton.new()
	right_click.pressed = true
	right_click.button_index = MOUSE_BUTTON_RIGHT
	labels._on_label_input(camera, right_click, Vector3.ZERO, Vector3.UP, 0, 0)
	check(labels._selected == -1, "right click does not select a label")
	for frame in 16:
		labels.frame = frame
		labels._on_label_input(camera, press, Vector3.ZERO, Vector3.UP, 0, 0)
		labels._process(0.0)
		check(labels._texts[0].visible, "tap shows global label at frame %d" % frame)
		labels._on_label_input(camera, release, Vector3.ZERO, Vector3.UP, 0, 0)
		check(labels._selected == 0, "release does not toggle")
		labels._on_label_input(camera, press, Vector3.ZERO, Vector3.UP, 0, 0)
		labels._process(0.0)
		check(not labels._texts[0].visible, "second tap hides")
	labels.frame = 0
	labels._on_label_input(camera, press, Vector3.ZERO, Vector3.UP, 0, 1)
	check(labels._selected == -1, "out-of-frame label cannot be selected")
	labels.frame = 7
	labels._on_label_input(camera, press, Vector3.ZERO, Vector3.UP, 0, 0)
	labels._on_label_input(camera, press, Vector3.ZERO, Vector3.UP, 0, 1)
	labels._process(0.0)
	check(labels._texts[1].visible and not labels._texts[0].visible, "another tap switches label")
	labels.frame = 8
	labels._process(0.0)
	check(labels._selected == -1 and not labels._texts[1].visible, "frame range expires selection")
	labels.hide()
	labels._on_label_input(camera, press, Vector3.ZERO, Vector3.UP, 0, 0)
	check(labels._selected == -1, "hidden labels ignore taps")
	labels.show()
	labels._on_label_input(camera, press, Vector3.ZERO, Vector3.UP, 0, 0)
	labels._held["test controller"] = 0
	labels._process(0.0)
	labels.hide()
	labels.show()
	check(labels._selected == -1, "hiding labels clears selection")
	check(labels._held.is_empty(), "hiding labels clears controller hysteresis")
	check(not labels._texts[0].visible, "showing labels does not flash stale text before processing")
	# A hidden ancestor must have the same effect as hiding Labels directly.
	labels._on_label_input(camera, press, Vector3.ZERO, Vector3.UP, 0, 0)
	labels._process(0.0)
	var parent := Node3D.new()
	viewport.add_child(parent)
	labels.reparent(parent)
	parent.hide()
	parent.show()
	check(labels._selected == -1 and not labels._texts[0].visible, "hidden ancestor clears selection and text")
	parent.free()
	# Exercise native target creation without initializing the platform backend.
	var platform := SpatialPlatform._kind
	SpatialPlatform._kind = SpatialPlatform.Kind.VISIONOS
	labels = Labels.new()
	viewport.add_child(labels)
	labels.volume = volume
	labels.set_labels([first, second])
	check(labels._targets.size() == 2, "one spatial input target per label")
	var target: Area3D = labels._targets[0]
	check(target.get_child(0).shape == labels._targets[1].get_child(0).shape, "targets share their collision resource")
	check(not target.monitoring and not target.monitorable, "input targets do not monitor physics overlaps")
	check(not labels._targets[1].input_ray_pickable, "out-of-frame target is not pickable on creation")
	labels._process(0.0)
	check(is_equal_approx(labels._target_shape.radius * labels._meters_per_unit(), Labels.TAP_RADIUS), "target keeps its physical radius")
	var changes := [0]
	labels._target_shape.changed.connect(func() -> void: changes[0] += 1)
	for tick in 120:
		labels._process(0.0)
	check(changes[0] == 0, "stationary targets do not rebuild their collision shape over 120 frames")
	volume.window_size *= 2.0
	labels._process(0.0)
	check(changes[0] > 0, "resizing refreshes the shared collision shape")
	check(is_equal_approx(labels._target_shape.radius * labels._meters_per_unit(), Labels.TAP_RADIUS), "resized target keeps its physical radius")
	var resized_changes: int = changes[0]
	for tick in 120:
		labels._process(0.0)
	check(changes[0] == resized_changes, "resized targets stop rebuilding once their size settles")
	labels.hide()
	check(not target.input_ray_pickable, "hiding immediately disables target picking")
	labels.show()
	labels.frame = 7
	labels._process(0.0)
	check(labels._targets.all(func(area: Area3D) -> bool: return area.input_ray_pickable), "showing restores current-frame targets")
	target.input_event.emit(camera, press, target.global_position, Vector3.UP, 0)
	labels._process(0.0)
	check(labels._texts[0].visible, "collision input signal selects text")
	labels.frame = 8
	labels._process(0.0)
	check(not labels._targets[1].input_ray_pickable, "frame change disables expired target")
	SpatialPlatform._kind = platform
	labels.volume = null
	volume.free()
	viewport.free()
	print("Label click tests: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
