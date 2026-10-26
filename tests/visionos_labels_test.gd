extends Node
## Native visionOS checks using real document scenes and injected XR poses.
## See tests/README.md for packaging and simulator setup.

const Meta := preload("res://app/meta.gd")
var checks := 0
var failures := []
var document: Node
var controller: XRController3D
var tracker := XRControllerTracker.new()

func _ready() -> void:
	_run.call_deferred()

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
	print("SIM %s: %s" % ["PASS" if ok else "FAIL", message])

func settle() -> void:
	await get_tree().create_timer(0.6).timeout

func move_tip(point: Vector3) -> void:
	controller.tracker = tracker.name
	controller.pose = &"aim"
	var mpu: float = document.labels._meters_per_unit()
	var local: Vector3 = controller.get_parent().to_local(document.labels.to_global(point))
	tracker.set_pose(&"aim", Transform3D(Basis.from_scale(Vector3.ONE / mpu), local + Vector3(0, 0, 0.18 / mpu)), Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	await settle()
	print("SIM TRACKER: ", controller.tracker, " pose=", controller.pose, " mock=", tracker.get_pose(&"aim").has_tracking_data, " node=", controller.get_has_tracking_data())

func visible_texts() -> Array:
	var texts := []
	for child in document.labels.get_children():
		if child is Label3D and child.is_visible_in_tree():
			texts.append(child.text)
	return texts

func stage(name: String) -> void:
	var data := {stage = name, checks = checks, failures = failures, texts = visible_texts() if document != null else [], tracker = str(controller.tracker), pose = str(controller.pose)}
	FileAccess.open("user://simulator-results.json", FileAccess.WRITE).store_string(JSON.stringify(data, "\t"))
	print("SIM STAGE: ", name)
	if OS.get_environment("LABEL_SIM_SCREENSHOTS") != "1":
		return
	for step in 450:
		if FileAccess.file_exists("user://simulator-continue.txt") and FileAccess.get_file_as_string("user://simulator-continue.txt").strip_edges() == name:
			break
		await get_tree().create_timer(0.1).timeout

func _run() -> void:
	check(OS.has_feature("visionos"), "running in native visionOS")
	check(get_tree().is_class("RealitySceneTree"), "RealityKit scene tree active")
	check(SpatialPlatform.current() == SpatialPlatform.Kind.VISIONOS, "production visionOS volume backend selected")
	check(MathJax.tex_to_svg("\\frac{1}{2}").contains("<svg"), "MathJax typesets TeX in the simulator engine")
	document = load("res://app/document.tscn").instantiate()
	get_parent().add_child(document)
	check(document.open("user://labels.zip").is_empty(), "test ZIP opens on visionOS")
	document.set_playing(false)
	document.seek(0)
	await get_tree().create_timer(3.0).timeout
	await _test_taps()
	await _test_grab_taps()
	controller = document.volume.get_controllers()[0]
	check(controller.pose == &"aim", "native controller keeps aim pose after tracker binding")
	tracker.name = &"label_test_left"
	tracker.type = XRServer.TRACKER_CONTROLLER
	tracker.hand = XRPositionalTracker.TRACKER_HAND_LEFT
	XRServer.add_tracker(tracker)
	controller.tracker = tracker.name
	await move_tip(Vector3(100, 100, 100))
	check(visible_texts().is_empty(), "far controller hides all label text")
	await move_tip(Vector3.ZERO)
	check(controller.get_has_tracking_data(), "simulated controller pose reaches XRController3D")
	check(visible_texts() == ["Hall element\nsenses B"], "near controller reveals frame 1 label")
	await stage("frame1-near")
	var reach: float = 0.03 / document.labels._meters_per_unit()
	await move_tip(Vector3(reach * 1.1, 0, 0))
	check(visible_texts().size() == 1, "label stays at 1.1 times reach")
	await move_tip(Vector3(reach * 1.3, 0, 0))
	check(visible_texts().is_empty(), "label hides beyond 1.25 times reach")
	document.seek(1)
	await move_tip(Vector3(10, 0, 0))
	check(visible_texts() == ["Coil"], "frame 2 reveals Coil inside its radius")
	document.labels_button.button_pressed = false
	await settle()
	check(visible_texts().is_empty(), "Labels switch hides text")
	document.labels_button.button_pressed = true
	await settle()
	check(visible_texts() == ["Coil"], "Labels switch restores eligible text")
	await stage("frame2-coil")
	document.seek(3)
	await settle()
	check(visible_texts().is_empty(), "Coil disappears outside its frame range")
	await move_tip(Vector3(0, 10, 0))
	check(visible_texts() == ["Only frame 4"], "frame 4 label appears at its point")
	await stage("frame4-top")
	# Keep the first native volume alive while opening the edited ZIP.
	# Closing it currently exits the app in this GodotRealityKit build.
	document.labels.visible = false
	document.content.visible = false
	document = null
	await settle()
	var workspace: Window = load("res://app/workspace.tscn").instantiate()
	get_parent().add_child(workspace)
	check(workspace.draft.open("user://labels.zip").is_empty(), "workspace loads test ZIP on visionOS")
	workspace.draft.labels[0].frames = Vector2i(0, 0)
	workspace.show_frames()
	workspace.show_labels(0)
	var tree: Tree = workspace.get_node("%FrameList")
	tree.get_root().get_child(0).select(0)
	workspace.remove_frame()
	check(workspace.draft.labels.size() == 2, "deleting sole frame removes its label")
	check(workspace.draft.labels[0].frames == Vector2i(0, 1), "remaining label range follows surviving frames")
	check(workspace.draft.save(ProjectSettings.globalize_path("user://removed.zip")).is_empty(), "edited ZIP saves on visionOS")
	workspace.draft.close()
	await settle()
	document = load("res://app/document.tscn").instantiate()
	get_parent().add_child(document)
	check(document.open("user://removed.zip").is_empty(), "edited ZIP reopens as a native volume")
	document.set_playing(false)
	document.seek(0)
	await settle()
	controller = document.volume.get_controllers()[0]
	controller.tracker = tracker.name
	await move_tip(Vector3.ZERO)
	check(visible_texts().is_empty(), "deleted label stays absent in the volume")
	await move_tip(Vector3(10, 0, 0))
	check(visible_texts() == ["Coil"], "Coil appears at new frame 1 after save and reload")
	await stage("after-delete")
	var source := ZIPReader.new()
	source.open("user://labels.zip")
	var manifest: Dictionary = JSON.parse_string(source.read_file("meta.json").get_string_from_utf8())
	for span in [[0], [3, 2], [99]]:
		manifest.labels = [{text = "Invalid", position = [0, 0, 0], frames = span}]
		var packer := ZIPPacker.new()
		packer.open("user://invalid.zip")
		for file in source.get_files():
			packer.start_file(file)
			packer.write_file(JSON.stringify(manifest).to_utf8_buffer() if file == "meta.json" else source.read_file(file))
			packer.close_file()
		packer.close()
		var meta := Meta.new()
		check(not meta.open("user://invalid.zip").is_empty(), "invalid range %s rejected on visionOS" % str(span))
		meta.close()
	source.close()
	await stage("complete")


func _test_taps() -> void:
	var labels: Node3D = document.labels
	check(labels._targets.size() == document.meta.labels.size(), "one native tap target per label")
	check(labels._targets.all(func(target: Area3D) -> bool: return target.get_child(0).shape == labels._target_shape), "native targets share one collision shape")
	check(labels._targets.all(func(target: Area3D) -> bool: return not target.monitoring and not target.monitorable), "native targets skip overlap monitoring")
	var press = ClassDB.instantiate(&"InputEventSpatialTouch")
	press.pressed = true
	var release = ClassDB.instantiate(&"InputEventSpatialTouch")
	var canceled = ClassDB.instantiate(&"InputEventSpatialTouch")
	canceled.pressed = true
	canceled.canceled = true
	var camera: Node = document.volume._backend._camera
	var first: Area3D = labels._targets[0]
	var second: Area3D = labels._targets[1]
	first.input_event.emit(camera, press, first.global_position, Vector3.UP, 0)
	await settle()
	check(visible_texts() == ["Hall element\nsenses B"], "native spatial tap selects label text")
	first.input_event.emit(camera, release, first.global_position, Vector3.UP, 0)
	check(labels._selected == 0, "native release keeps selection")
	first.input_event.emit(camera, canceled, first.global_position, Vector3.UP, 0)
	check(labels._selected == 0, "canceled native touch does not toggle selection")
	second.input_event.emit(camera, press, second.global_position, Vector3.UP, 0)
	check(labels._selected == 0 and not second.input_ray_pickable, "out-of-frame native target cannot be selected")
	document.seek(1)
	await settle()
	second.input_event.emit(camera, press, second.global_position, Vector3.UP, 0)
	await settle()
	check(visible_texts() == ["Coil"], "another native target switches the selected text")
	document.labels_button.button_pressed = false
	check(labels._selected == -1 and not second.input_ray_pickable, "Labels switch immediately clears selection and picking")
	document.labels_button.button_pressed = true
	await settle()
	check(visible_texts().is_empty() and second.input_ray_pickable, "showing labels restores targets without stale text")
	second.input_event.emit(camera, press, second.global_position, Vector3.UP, 0)
	await settle()
	second.input_event.emit(camera, press, second.global_position, Vector3.UP, 0)
	await settle()
	check(visible_texts().is_empty(), "second native tap hides the selected text")
	var before := second.global_position
	document.yaw = PI * 0.5
	document._yaw_target = document.yaw
	document.tilt = 0.35
	document._tilt_target = document.tilt
	document._place_turntable()
	await settle()
	check(not second.global_position.is_equal_approx(before), "native target follows model rotation")
	second.input_event.emit(camera, press, second.global_position, Vector3.UP, 0)
	await settle()
	check(visible_texts() == ["Coil"], "rotated native target still selects its label")
	var dot_point: Vector3 = document.volume.to_local(labels._dots[1].global_position)
	var text_point: Vector3 = document.volume.to_local(labels._texts[1].global_position)
	check(text_point.y > dot_point.y and is_equal_approx(text_point.x, dot_point.x), "rotated native text stays above the point in volume space")
	document.yaw = 0.0
	document._yaw_target = 0.0
	document.tilt = 0.0
	document._tilt_target = 0.0
	document._place_turntable()
	document.labels_button.button_pressed = false
	document.labels_button.button_pressed = true
	document.seek(0)
	await settle()


func _test_grab_taps() -> void:
	var labels: Node3D = document.labels
	var camera: Node = document.volume._backend._camera
	var press = ClassDB.instantiate(&"InputEventSpatialTouch")
	press.index = 73
	press.pressed = true
	press.position = camera.unproject_position(labels._dots[0].global_position)
	press.world_position = labels._dots[0].global_position
	var release = press.duplicate()
	release.pressed = false
	var before: float = document._yaw_target
	document.grab.input_event.emit(camera, press, document.grab.global_position, Vector3.UP, 0)
	await settle()
	check(visible_texts() == ["Hall element\nsenses B"], "tap received by native model bounds selects the label behind them")
	check(document._drag == -1, "label tap on model bounds does not start model rotation")
	var drag = ClassDB.instantiate(&"InputEventSpatialDrag")
	drag.index = press.index
	drag.world_position = press.world_position + Vector3(5, 0, 0)
	drag.world_relative = Vector3(5, 0, 0)
	document.grab.input_event.emit(camera, drag, document.grab.global_position, Vector3.UP, 0)
	check(is_equal_approx(document._yaw_target, before), "label gesture movement does not rotate the model")
	document.grab.input_event.emit(camera, release, document.grab.global_position, Vector3.UP, 0)
	check(document._label_touch == -1, "native label gesture releases its capture")
	document.grab.input_event.emit(camera, press, document.grab.global_position, Vector3.UP, 0)
	document.grab.input_event.emit(camera, release, document.grab.global_position, Vector3.UP, 0)
	await settle()
	check(visible_texts().is_empty(), "second tap received by native model bounds hides the label")
