extends SceneTree
## Regression coverage for combining point labels with turntable fitting
## and the engine-backed TeX notes renderer.

const DocumentScene := preload("res://app/document.tscn")
const Meta := preload("res://app/meta.gd")
const ModelFrames := preload("res://app/model_frames.gd")
const NotesImages := preload("res://app/notes_images.gd")
const Labels := preload("res://app/labels.gd")

class TestVolume extends SpatialVolume3D:
	func _enter_tree() -> void:
		pass

	func get_controllers() -> Array[XRController3D]:
		return []

var checks := 0
var failures := 0


func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		print("FAIL: ", message)


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_document()
	_test_rotated_text()
	_test_formulas()
	print("Document integration tests: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)


func _test_document() -> void:
	# Wire the scene's references without opening native windows. Its real
	# model loader, fitting code, scene hierarchy and signal connections run.
	var document = DocumentScene.instantiate()
	document.turntable = document.get_node("Model/Turntable")
	document.content = document.get_node("Model/Turntable/Content")
	document.labels = document.get_node("Model/Turntable/Labels")
	document.grab = document.get_node("Model/Turntable/Grab")
	document.volume = document.get_node("Model/Volume")
	check(document.labels.get_parent() == document.content.get_parent(), "labels and model share the turntable")
	var toggle: CheckButton = document.get_node("Model/Options/Bar/ShowLabels")
	toggle.toggled.emit(false)
	check(not document.labels.visible, "Labels switch reaches the relocated node")
	toggle.toggled.emit(true)
	check(document.labels.visible, "Labels switch restores the relocated node")
	var zip := ProjectSettings.globalize_path("res://builds/labels-tests/labels.zip")
	var error: String = document.meta.open(zip)
	check(error.is_empty(), "fixture opens: " + error)
	if not error.is_empty():
		document.free()
		return
	for entry: Meta.Model in document.meta.models:
		var frames := ModelFrames.new()
		frames.setup(zip, entry)
		document.content.add_child(frames)
		document.models.append(frames)
		frames.show_frame(0)
	document.fit()
	_check_rotated_labels(document, "model and labels")
	for frames in document.models:
		frames.free()
	document.models.clear()
	document.meta.fields.clear()
	document.fit()
	_check_rotated_labels(document, "labels alone")
	var point := Meta.PointLabel.new()
	point.position = Vector3(7, -4, 2)
	point.text = "Single label"
	document.meta.labels.assign([point])
	document.fit()
	check(document.volume.position.is_equal_approx(point.position), "single label is centered")
	check(document.volume.size > 0.0, "single-label volume has a positive size")
	var shape: BoxShape3D = document.grab.get_node("Shape").shape
	check(shape.size.x > 0.0 and shape.size.y > 0.0 and shape.size.z > 0.0, "single-label grab has nonzero extents")
	document.meta.close()
	document.free()


func _check_rotated_labels(document: Node, context: String) -> void:
	var region: Vector3 = document.volume.get_region_size()
	var box := AABB(document.volume.position - region * 0.5, region)
	for angle in [0.0, PI * 0.5, PI, PI * 1.5]:
		document.yaw = angle
		document.tilt = deg_to_rad(60.0)
		document._place_turntable()
		for label: Meta.PointLabel in document.meta.labels:
			var point: Vector3 = document.turntable.transform * label.position
			check(box.has_point(point), "%s: label remains in volume at yaw %s" % [context, angle])


func _test_rotated_text() -> void:
	var viewport := SubViewport.new()
	viewport.own_world_3d = true
	root.add_child(viewport)
	var volume := TestVolume.new()
	viewport.add_child(volume)
	var turntable := Node3D.new()
	turntable.rotation.z = PI * 0.5
	viewport.add_child(turntable)
	var labels := Labels.new()
	turntable.add_child(labels)
	labels.volume = volume
	var middle := Meta.PointLabel.new()
	middle.position = Vector3(1, 1, 0)
	middle.text = "Middle"
	middle.frames = Vector2i(0, 0)
	var top := Meta.PointLabel.new()
	top.position = Vector3(2.49, 0, 0)
	top.text = "Top"
	top.frames = Vector2i(0, 0)
	labels.set_labels([middle, top])
	labels._selected = 0
	labels._process(0.0)
	var offset: Vector3 = labels._texts[0].global_position - labels._dots[0].global_position
	check(offset.y > 0.0 and is_zero_approx(offset.x), "rotated label text stays above the point in the volume")
	labels._selected = 1
	labels._process(0.0)
	check(labels._texts[1].vertical_alignment == VERTICAL_ALIGNMENT_TOP, "rotated point near the volume top uses text below")
	check(labels._texts[1].global_position.y < labels._dots[1].global_position.y, "rotated top label stays inside the volume")
	viewport.free()


func _test_formulas() -> void:
	var images := NotesImages.new()
	var read := func(_path: String) -> PackedByteArray: return PackedByteArray()
	var first := images.embed("[math]E=mc^2[/math]", read, "notes.txt", "integration", Color.WHITE, 24)
	check(first.begins_with("[img=center,baseline]math://"), "inline TeX becomes an SVG texture")
	check(images.textures.size() == 1 and images.textures[0].get_width() > 0, "formula texture has visible dimensions")
	var edited := images.embed("[math]E=mc^3[/math]", read, "notes.txt", "integration", Color.WHITE, 24)
	check(first != edited, "editing TeX changes the resource path and refreshes the notes")
	var display := images.embed("[math=display]\\frac{a}{b}[/math]", read, "notes.txt", "integration", Color.WHITE, 24)
	check(display.begins_with("[center][img=center,baseline]math://"), "display TeX is centered")
	check(MathJax.get_error_message().is_empty(), "MathJax completes without errors")
