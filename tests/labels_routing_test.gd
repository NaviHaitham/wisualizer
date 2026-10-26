extends SceneTree
## Regression checks for labels reached through the model's real Grab signal.
## Uses native spatial event classes, but opens no platform windows.

const DocumentScene := preload("res://app/document.tscn")
const Meta := preload("res://app/meta.gd")

class TestVolume extends SpatialVolume3D:
	func _enter_tree() -> void:
		pass

	func get_controllers() -> Array[XRController3D]:
		return []

var checks := 0
var failures: Array[String] = []
var document: Node
var viewport: SubViewport
var camera: Camera3D
var volume: TestVolume
var labels: Node3D
var platform: int


func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		print("FAIL: ", message)


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if not ClassDB.class_exists(&"InputEventSpatialTouch") or not ClassDB.class_exists(&"InputEventSpatialDrag"):
		check(false, "GodotRealityKit spatial input classes are registered")
		_finish()
		return
	_setup()
	await physics_frame
	await physics_frame
	_test_occluded_label()
	_test_rotation()
	_test_fallback()
	_test_ignored_input()
	_test_plain_drag()
	_test_ray_order()
	SpatialPlatform._kind = platform
	viewport.free()
	document.free()
	_finish()


func _setup() -> void:
	viewport = SubViewport.new()
	viewport.size = Vector2i(800, 600)
	viewport.world_3d = World3D.new()
	root.add_child(viewport)
	camera = Camera3D.new()
	camera.position.z = 10.0
	viewport.add_child(camera)
	camera.make_current()
	volume = TestVolume.new()
	viewport.add_child(volume)
	document = DocumentScene.instantiate()
	document.turntable = document.get_node("Model/Turntable")
	document.grab = document.get_node("Model/Turntable/Grab")
	document.labels = document.get_node("Model/Turntable/Labels")
	document.volume = volume
	for child in document.turntable.find_children("*", "Node", true, false):
		child.owner = null
	document.turntable.owner = null
	document.turntable.reparent(viewport, false)
	document._center = Vector3.ZERO
	document._radius = 3.0
	(document.grab.get_node("Shape").shape as BoxShape3D).size = Vector3.ONE * 6.0
	labels = document.labels
	labels.volume = volume
	# The platform flag only creates input targets; the stub volume never
	# initializes a native backend.
	platform = SpatialPlatform._kind
	SpatialPlatform._kind = SpatialPlatform.Kind.VISIONOS
	var middle := Meta.PointLabel.new()
	middle.text = "Inside the model bounds"
	middle.frames = Vector2i(0, 1)
	var farther := Meta.PointLabel.new()
	farther.text = "Behind the first label"
	farther.position.z = -1.0
	farther.frames = Vector2i(0, 1)
	var limited := Meta.PointLabel.new()
	limited.text = "Second frame only"
	limited.position.x = 2.0
	limited.frames = Vector2i(1, 1)
	var entries: Array[Meta.PointLabel] = [middle, farther, limited]
	labels.set_labels(entries)
	labels.set_process(false)
	labels._process(0.0)


func _touch(index: int, pressed: bool, point: Vector3, with_ray := true, canceled := false) -> InputEvent:
	var event = ClassDB.instantiate(&"InputEventSpatialTouch")
	event.index = index
	event.pressed = pressed
	event.canceled = canceled
	event.position = camera.unproject_position(point)
	event.world_position = point
	event.has_selection_ray = with_ray
	if with_ray:
		event.selection_ray_origin = camera.global_position
		event.selection_ray_direction = (point - camera.global_position).normalized()
	return event


func _drag(index: int, point: Vector3, movement: Vector3) -> InputEvent:
	var event = ClassDB.instantiate(&"InputEventSpatialDrag")
	event.index = index
	event.world_position = point
	event.world_relative = movement
	return event


func _send(event: InputEvent, with_camera := true) -> void:
	document.grab.input_event.emit(camera if with_camera else null, event, event.get("world_position"), Vector3.FORWARD, 0)


func _test_occluded_label() -> void:
	var query := PhysicsRayQueryParameters3D.create(Vector3(0, 0, 10), Vector3(0, 0, -10))
	query.collide_with_areas = true
	var hit := viewport.world_3d.direct_space_state.intersect_ray(query)
	check(hit.get("collider") == document.grab, "real collision query hits Grab before the enclosed label")
	_send(_touch(11, true, Vector3.ZERO))
	labels._process(0.0)
	check(labels._selected == 0 and labels._texts[0].visible, "Grab press selects the visible label enclosed by its bounds")
	check(document._drag == -1, "label press does not begin model rotation")
	var yaw_before: float = document._yaw_target
	var tilt_before: float = document._tilt_target
	_send(_drag(11, Vector3(1, 1, 0), Vector3(1, 1, 0)))
	check(document._drag == -1 and is_equal_approx(document._yaw_target, yaw_before) and is_equal_approx(document._tilt_target, tilt_before), "drag in the selected label gesture does not rotate the model")
	_send(_touch(11, false, Vector3(1, 1, 0)))
	check(labels._selected == 0 and document._drag == -1, "label release preserves selection without beginning rotation")
	_send(_touch(12, true, Vector3.ZERO))
	check(labels._selected == -1, "second Grab press at the label toggles its text off")
	_send(_touch(12, false, Vector3.ZERO))


func _test_rotation() -> void:
	document.yaw = PI * 0.75
	document.tilt = 0.6
	document._place_turntable()
	var point: Vector3 = labels.to_global(labels._labels[1].position)
	_send(_touch(21, true, point))
	labels._process(0.0)
	check(labels._selected == 1 and labels._texts[1].visible, "rotated label is found in the turntable's local coordinates")
	_send(_touch(21, false, point))
	document.yaw = 0.0
	document.tilt = 0.0
	document._place_turntable()
	labels._selected = -1


func _test_fallback() -> void:
	_send(_touch(31, true, Vector3.ZERO, false))
	check(labels._selected == 0, "touch without selection ray uses the camera projection")
	_send(_touch(31, false, Vector3.ZERO, false))
	labels._selected = -1
	var invalid := _touch(32, true, Vector3.ZERO)
	invalid.set("selection_ray_direction", Vector3.ZERO)
	_send(invalid)
	check(labels._selected == 0, "zero-length selection ray falls back to the camera projection")
	_send(_touch(32, false, Vector3.ZERO))
	labels._selected = -1
	var conflicting := _touch(33, true, Vector3.ZERO)
	conflicting.set("selection_ray_direction", Vector3.UP)
	_send(conflicting)
	check(labels._selected == 0, "camera projection takes priority over a conflicting native selection ray")
	_send(_touch(33, false, Vector3.ZERO))
	labels._selected = -1
	_send(_touch(34, true, Vector3.ZERO), false)
	check(labels._selected == 0, "valid selection ray selects a label when there is no camera")
	_send(_touch(34, false, Vector3.ZERO), false)
	labels._selected = -1


func _test_ignored_input() -> void:
	_send(_touch(41, true, Vector3.ZERO, true, true))
	check(labels._selected == -1 and document._drag == -1, "canceled press neither selects a label nor starts rotation")
	labels.hide()
	_send(_touch(42, true, Vector3.ZERO))
	check(labels._selected == -1 and document._drag == 42, "hidden label does not intercept ordinary Grab input")
	_send(_touch(42, false, Vector3.ZERO))
	labels.show()
	labels.frame = 0
	_send(_touch(43, true, Vector3(2, 0, 0)))
	check(labels._selected == -1 and document._drag == 43, "out-of-frame label does not intercept ordinary Grab input")
	_send(_touch(43, false, Vector3(2, 0, 0)))
	labels.frame = 1
	_send(_touch(44, true, Vector3(2, 0, 0)))
	check(labels._selected == 2 and document._drag == -1, "label becomes selectable on its valid frame")
	_send(_touch(44, false, Vector3(2, 0, 0)))
	labels._selected = -1
	labels.frame = 0


func _test_plain_drag() -> void:
	var point := Vector3(1, 1, 3)
	_send(_touch(51, true, point))
	check(document._drag == 51, "empty part of Grab begins ordinary model rotation")
	_send(_drag(51, point + Vector3.RIGHT, Vector3.RIGHT))
	check(not is_zero_approx(document._yaw_target), "ordinary Grab drag still turns the model")
	_send(_touch(51, false, point + Vector3.RIGHT))
	check(document._drag == -1, "ordinary Grab release finishes rotation after earlier label gestures")
	# A canceled release must finish a captured label gesture as well.
	_send(_touch(52, true, Vector3.ZERO))
	_send(_touch(52, false, Vector3.ZERO, true, true))
	_send(_touch(53, true, point))
	check(document._drag == 53, "canceled label release does not leave later Grab gestures captured")
	_send(_touch(53, false, point))
	labels._selected = -1


func _test_ray_order() -> void:
	check(labels._label_along_ray(Vector3(0, 0, 10), Vector3.FORWARD) == 0, "nearest intersected label wins for overlapping projected targets")
	check(labels._label_along_ray(Vector3(0, 0, -10), Vector3.FORWARD) == -1, "labels behind the ray origin are not selected")
	check(labels._label_along_ray(Vector3.ZERO, Vector3.FORWARD) == 0, "ray originating inside a target selects that target")
	check(labels._label_along_ray(Vector3(0, 0, 10), Vector3.ZERO) == -1, "zero direction is rejected without selecting a label")


func _finish() -> void:
	print("Label routing tests: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
