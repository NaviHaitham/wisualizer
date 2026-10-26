extends SceneTree
## Labels regression checks. Run with the project's custom Godot:
## godot --headless --path . --script res://tests/labels_test.gd

const Meta := preload("res://app/meta.gd")
const Draft := preload("res://app/draft.gd")
const Labels := preload("res://app/labels.gd")

var failures := 0
var checks := 0
var dir := OS.get_environment("TEST_DIR")


func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		print("FAIL: ", what)


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if dir.is_empty():
		dir = ProjectSettings.globalize_path("res://builds/labels-tests")
	DirAccess.make_dir_recursive_absolute(dir)
	var glb := _make_glb()
	var zip := dir.path_join("labels.zip")
	_make_zip(zip, glb, [
		{text = "Hall element\nsenses B", position = [0, 0, 0]},
		{text = "Coil", position = [10, 0, 0], radius = 2.5, frames = [2, 3]},
		{text = "Only frame 4", position = [0, 10, 0], frames = [4]},
	])

	# Meta
	var meta := Meta.new()
	var error := meta.open(zip)
	check(error.is_empty(), "meta opens: " + error)
	check(meta.labels.size() == 3, "three labels")
	if meta.labels.size() == 3:
		check(meta.labels[0].text == "Hall element\nsenses B", "text kept")
		check(meta.labels[0].frames == Vector2i(0, 3), "default frames are all: %s" % meta.labels[0].frames)
		check(meta.labels[0].radius == 0.0, "default radius 0")
		check(meta.labels[1].frames == Vector2i(1, 2), "frames counted from 1: %s" % meta.labels[1].frames)
		check(meta.labels[1].radius == 2.5, "radius read")
		check(meta.labels[1].position == Vector3(10, 0, 0), "position read")
		check(meta.labels[2].frames == Vector2i(3, 3), "one frame: %s" % meta.labels[2].frames)
		check(not meta.labels[1].shows_at(0) and meta.labels[1].shows_at(1) and meta.labels[1].shows_at(2) and not meta.labels[1].shows_at(3), "shows_at")
	meta.close()

	var bad := dir.path_join("bad.zip")
	_make_zip(bad, glb, [{text = "", position = [0, 0, 0]}])
	check(Meta.new().open(bad) == "Label 1 needs text and a position, [x, y, z].", "empty text rejected")
	_make_zip(bad, glb, [{text = "x", position = [0, 0]}])
	check(not Meta.new().open(bad).is_empty(), "short position rejected")
	_make_zip(bad, glb, [])
	var none := Meta.new()
	check(none.open(bad).is_empty() and none.labels.is_empty(), "no labels is fine")

	# Draft round trip
	var draft := Draft.new()
	error = draft.open(zip)
	check(error.is_empty(), "draft opens: " + error)
	check(draft.labels.size() == 3, "draft has three labels")
	check(draft.labels[0].frames == Vector2i(0, -1), "all frames stay open-ended: %s" % draft.labels[0].frames)
	check(draft.labels[1].frames == Vector2i(1, 2), "draft frames: %s" % draft.labels[1].frames)
	check(draft.labels[0].title() == "Hall element", "title is the first line")
	check(draft.problems().is_empty(), "no problems: " + draft.problems())
	var saved := dir.path_join("saved.zip")
	error = draft.save(saved)
	check(error.is_empty(), "draft saves: " + error)
	var reader := ZIPReader.new()
	reader.open(saved)
	var manifest: Dictionary = JSON.parse_string(reader.read_file("meta.json").get_string_from_utf8())
	reader.close()
	check(manifest.labels.size() == 3, "saved three labels")
	check(not manifest.labels[0].has("frames") and not manifest.labels[0].has("radius"), "defaults left out: %s" % manifest.labels[0])
	check(manifest.labels[1].frames == [2.0, 3.0] and manifest.labels[1].radius == 2.5, "saved frames and radius: %s" % manifest.labels[1])
	check(manifest.labels[2].frames == [4.0, 4.0], "saved one frame: %s" % manifest.labels[2])
	# Frames added later still reach a label shown at every frame.
	draft.times.append(4.0)
	check(draft.problems().is_empty(), "added frame ok: " + draft.problems())
	draft.labels[1].frames = Vector2i(2, 1)
	check(draft.problems().begins_with("The label Coil shows at frames 3 to 2"), "backwards frames: " + draft.problems())
	draft.labels[1].frames = Vector2i(1, 9)
	check(draft.problems().ends_with("but there are 5 frames."), "frames past the end: " + draft.problems())
	draft.labels[1].frames = Vector2i(1, 2)
	draft.labels[0].text = "  "
	check(draft.problems() == "A label has no text.", "blank text: " + draft.problems())
	draft.close()

	# Picking a label
	var meta2 := Meta.new()
	meta2.open(zip)
	var labels: Node3D = Labels.new()
	labels.set_labels(meta2.labels)
	# 0.01 m per unit: the default reach is 3 units.
	var mpu := 0.01
	labels.frame = 0
	check(labels.nearest(Vector3(2, 0, 0), -1, mpu) == 0, "within default reach")
	check(labels.nearest(Vector3(3.5, 0, 0), -1, mpu) == -1, "outside default reach")
	check(labels.nearest(Vector3(3.5, 0, 0), 0, mpu) == 0, "shown label reaches 1.25x")
	check(labels.nearest(Vector3(3.9, 0, 0), 0, mpu) == -1, "past 1.25x")
	check(labels.nearest(Vector3(9, 0, 0), -1, mpu) == -1, "coil hidden at frame 1")
	labels.frame = 1
	check(labels.nearest(Vector3(8, 0, 0), -1, mpu) == 1, "coil radius 2.5 at frame 2")
	check(labels.nearest(Vector3(7, 0, 0), -1, mpu) == -1, "coil radius ends")
	labels.frame = 3
	check(labels.nearest(Vector3(0, 9, 0), -1, mpu) == 2, "frame 4 label")
	check(labels.nearest(Vector3(1.5, 0, 0), -1, mpu) == 0, "first label at every frame")
	# Nearest wins where reaches overlap.
	var close := Meta.PointLabel.new()
	close.text = "near"
	close.position = Vector3(1, 0, 0)
	close.frames = Vector2i(0, 3)
	var both: Array[Meta.PointLabel] = [meta2.labels[0], close]
	var labels2: Node3D = Labels.new()
	labels2.set_labels(both)
	check(labels2.nearest(Vector3(0.8, 0, 0), -1, mpu) == 1, "nearest wins")
	check(labels2.nearest(Vector3(0.8, 0, 0), 0, mpu) == 1, "nearer one takes over from the shown one")
	labels.free()
	labels2.free()
	meta2.close()

	_test_frame_ranges(glb)
	_test_remove_frames(zip)
	_test_remove_all_frames(zip)

	print("labels test: %d checks, %d failed" % [checks, failures])
	quit(1 if failures > 0 else 0)


func _test_frame_ranges(glb: String) -> void:
	var zip := dir.path_join("frame-ranges.zip")
	for span in [[], [0], [-1], [99], [1, 99], [3, 2], [1, 2, 3], [1.5], [1, 2.5], ["1"], [true], [null], "1", 1, null, {}]:
		_make_zip(zip, glb, [{text = "Invalid", position = [0, 0, 0], frames = span}])
		var meta := Meta.new()
		var error := meta.open(zip)
		check(error.begins_with("Label 1 needs frames"), "invalid frames rejected: %s; error: %s" % [str(span), error])
		check(meta.labels.is_empty(), "invalid label not appended: %s" % str(span))
		meta.close()
	for span in [[1], [4], [1, 1], [1, 4], [2, 3]]:
		_make_zip(zip, glb, [{text = "Valid", position = [0, 0, 0], frames = span}])
		var meta := Meta.new()
		var error := meta.open(zip)
		check(error.is_empty() and meta.labels.size() == 1, "valid frames accepted: %s; error: %s" % [str(span), error])
		if meta.labels.size() == 1:
			for frame in 4:
				check(meta.labels[0].shows_at(frame) == (frame + 1 >= span[0] and frame + 1 <= span[-1]), "frame visibility for %s at %d" % [str(span), frame + 1])
		meta.close()


func _test_remove_frames(zip: String) -> void:
	var scene := load("res://app/workspace.tscn") as PackedScene
	var cases := [
		{span = Vector2i(0, 0), remove = 0},
		{span = Vector2i(1, 1), remove = 1},
		{span = Vector2i(3, 3), remove = 3},
		{span = Vector2i(1, 2), remove = 0},
		{span = Vector2i(1, 2), remove = 1},
		{span = Vector2i(1, 2), remove = 2},
		{span = Vector2i(1, 2), remove = 3},
		{span = Vector2i(0, 1), remove = 0},
		{span = Vector2i(0, 1), remove = 1},
		{span = Vector2i(0, -1), remove = 0},
		{span = Vector2i(0, -1), remove = 3},
		{span = Vector2i(2, -1), remove = 0},
		{span = Vector2i(2, -1), remove = 2},
		{span = Vector2i(3, -1), remove = 3},
	]
	for case in cases:
		var workspace: Window = scene.instantiate()
		root.add_child(workspace)
		check(workspace.draft.open(zip).is_empty(), "workspace fixture opens")
		workspace.draft.labels.clear()
		var label := Draft.PointLabel.new()
		label.text = "Frame label"
		label.frames = case.span
		workspace.draft.labels.append(label)
		workspace.show_frames()
		workspace.show_labels(0)
		var tree: Tree = workspace.get_node("%FrameList")
		tree.get_root().get_child(case.remove).select(0)
		workspace.remove_frame()
		check(workspace.draft.times.size() == 3, "workspace removes the selected frame")
		check(workspace.draft.problems().is_empty(), "deleting frame leaves a saveable label range: %s, delete %d" % [case.span, case.remove])
		var saved := dir.path_join("removed-frame.zip")
		var error: String = workspace.draft.save(saved)
		check(error.is_empty(), "deleted frame saves: " + error)
		var meta := Meta.new()
		error = meta.open(saved)
		check(error.is_empty(), "deleted frame reopens: " + error)
		var last: int = case.span.y if case.span.y >= 0 else 3
		var removed_label: bool = case.span.x == last and case.remove == last
		check(meta.labels.size() == (0 if removed_label else 1), "label with no surviving frames is removed: %s, delete %d" % [case.span, case.remove])
		for frame in 3:
			# Follow the original frames that survived, rather than their new indices.
			var original_frame: int = frame + 1 if frame >= case.remove else frame
			var was_visible: bool = original_frame >= case.span.x and original_frame <= last
			var now_visible := not meta.labels.is_empty() and meta.labels[0].shows_at(frame)
			check(now_visible == was_visible, "visibility preserved at original frame %d: %s, delete %d" % [original_frame, case.span, case.remove])
		meta.close()
		workspace.draft.close()
		workspace.free()


func _test_remove_all_frames(zip: String) -> void:
	var workspace: Window = load("res://app/workspace.tscn").instantiate()
	root.add_child(workspace)
	check(workspace.draft.open(zip).is_empty(), "multiple labels fixture opens")
	workspace.draft.labels.clear()
	for span in [Vector2i(0, 0), Vector2i(0, 0), Vector2i(0, -1), Vector2i(3, -1)]:
		var label := Draft.PointLabel.new()
		label.text = "Frame label"
		label.frames = span
		workspace.draft.labels.append(label)
	workspace.show_frames()
	workspace.show_labels(0)
	var tree: Tree = workspace.get_node("%FrameList")
	for remaining in range(3, -1, -1):
		tree.get_root().get_child(0).select(0)
		workspace.remove_frame()
		check(workspace.draft.times.size() == remaining, "remaining timeline length: %d" % remaining)
		check(workspace.draft.labels.size() == (0 if remaining == 0 else 2), "remove all labels that lose their last frame: %d remaining frames" % remaining)
		if remaining > 0:
			check(workspace.draft.labels[0].frames == Vector2i(0, -1), "all-frame label stays open-ended")
			check(workspace.draft.problems().is_empty(), "remaining labels can be saved")
	check(workspace.get_node("%LabelList").item_count == 0, "label list clears after the final frame")
	check(workspace.draft.problems().begins_with("Add a frame"), "empty timeline still needs a frame")
	workspace.add_frame()
	var saved := dir.path_join("new-timeline.zip")
	check(workspace.draft.save(saved).is_empty(), "new timeline can be saved after deleting all frames")
	var meta := Meta.new()
	check(meta.open(saved).is_empty() and meta.labels.is_empty(), "deleted labels stay removed on a new timeline")
	meta.close()
	workspace.draft.close()
	workspace.free()


func _make_glb() -> String:
	var root := Node3D.new()
	root.name = "Model"
	var box := MeshInstance3D.new()
	box.name = "Box"
	box.mesh = BoxMesh.new()
	(box.mesh as BoxMesh).size = Vector3(20, 4, 4)
	root.add_child(box)
	box.owner = root
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	document.append_from_scene(root, state)
	var path := dir.path_join("box.glb")
	document.write_to_filesystem(state, path)
	root.free()
	return path


func _make_zip(path: String, glb: String, labels: Array) -> void:
	var packer := ZIPPacker.new()
	packer.open(path)
	var manifest := {
		title = "Labels test",
		frames = [{time = 0.0}, {time = 1.0}, {time = 2.0}, {time = 3.0}],
		models = [{name = "Box", path = "models/box.glb"}],
	}
	if not labels.is_empty():
		manifest.labels = labels
	packer.start_file("meta.json")
	packer.write_file(JSON.stringify(manifest, "\t").to_utf8_buffer())
	packer.close_file()
	packer.start_file("models/box.glb")
	packer.write_file(FileAccess.get_file_as_bytes(glb))
	packer.close_file()
	packer.close()
