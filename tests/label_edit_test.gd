extends Node
## Runs on desktop or as a native simulator main scene. The source ZIP is
## copied first; save and Save As exercise the actual editor signals/thread.

const Meta := preload("res://app/meta.gd")
var checks := 0
var failures: Array[String] = []
var document: Node
var editor: Window
var directory := ""
var source := ""

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
	print("EDIT %s: %s" % ["PASS" if ok else "FAIL", message])

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var native := OS.has_feature("visionos")
	if not native:
		get_tree().root.gui_embed_subwindows = true
	directory = ProjectSettings.globalize_path("user://label-edit-tests" if native else "res://builds/label-edit-tests")
	DirAccess.make_dir_recursive_absolute(directory)
	source = OS.get_environment("LABEL_EDIT_ZIP")
	if source.is_empty():
		source = "user://Hall sensor-3d-labels-test.zip" if native else "res://builds/labels-tests/labels.zip"
	var target := directory.path_join("editable.zip")
	FileAccess.open(target, FileAccess.WRITE).store_buffer(FileAccess.get_file_as_bytes(source))
	var before := archive(target)
	document = load("res://app/document.tscn").instantiate()
	add_child(document)
	check(document.open(target).is_empty(), "document opens the test copy")
	document.set_playing(false)
	document.seek(0)
	if native:
		# GLB prefetch and native window creation finish asynchronously.
		await get_tree().create_timer(3.0).timeout
	var volume_id: int = document.volume.get_instance_id()
	var model_id: int = document.models[0].get_instance_id()
	var old_text: String = document.meta.labels[0].text
	document.labels._selected = 0
	document.get_node("%EditLabels").pressed.emit()
	editor = document._label_editor
	await get_tree().create_timer(0.5 if native else 0.0).timeout
	check(is_instance_valid(editor) and editor.visible, "Edit labels opens the label editor")
	check(editor.get_node("%Pages/Labels").visible, "editor starts on the Labels page")
	check(editor.get_node("%LabelList").get_selected_items() == PackedInt32Array([0]), "selected 3D label is selected in the form")
	document.edit_labels()
	check(editor == document._label_editor, "reopening reuses the same editor")
	for bad in ["1.5", "0", "3, 2", "1, 2, 3", "wrong"]:
		editor.get_node("%LabelFrames").text = bad
		editor.edit_label()
		editor.save()
		check(not editor._label_errors.is_empty() and not editor.is_saving(), "invalid frames cannot be saved: " + bad)
	editor.show_labels(1)
	editor.show_labels(0)
	check(editor.get_node("%LabelFrames").text == "wrong", "invalid input survives switching labels")
	editor.get_node("%LabelFrames").text = "2, 3"
	editor.get_node("%LabelPosition").text = "1, missing, 3"
	editor.edit_label()
	check(not editor._label_errors.is_empty(), "invalid coordinates are reported")
	editor.get_node("%LabelPosition").text = "1.25, 2.5, 3.75"
	editor.get_node("%LabelRadius").text = "-1"
	editor.edit_label()
	check(not editor._label_errors.is_empty(), "negative radius is rejected")
	editor.get_node("%LabelRadius").text = "4.5"
	editor.get_node("%LabelText").text = "Edited label\nSecond line"
	editor.edit_label()
	check(editor._label_errors.is_empty(), "valid edits clear the form error")
	check(document.meta.labels[0].text == old_text, "unsaved edits leave the document unchanged")
	editor.get_node("%Save").pressed.emit()
	await wait_save()
	check(document.meta.labels[0].text == "Edited label\nSecond line", "Save refreshes the text in the running document")
	check(document.meta.labels[0].position == Vector3(1.25, 2.5, 3.75), "Save refreshes the point")
	check(document.meta.labels[0].radius == 4.5, "Save refreshes controller reach")
	check(document.meta.labels[0].frames == Vector2i(1, 2), "Save refreshes the frame range")
	check(document.volume.get_instance_id() == volume_id and document.models[0].get_instance_id() == model_id, "saving retains the native volume and model nodes")
	check(not document.playing and document.frame == 0, "saving keeps playback state and frame")
	compare_archive(before, archive(target))
	var reopened := Meta.new()
	check(reopened.open(target).is_empty() and reopened.labels[0].text == "Edited label\nSecond line", "edited ZIP reopens with saved text")
	reopened.close()
	editor.get_node("%LabelFrames").text = ""
	editor.get_node("%LabelRadius").text = ""
	editor.edit_label()
	var saved_as := directory.path_join("saved-as.zip")
	editor.save_as(saved_as)
	await wait_save()
	check(document._source_path == saved_as and document.models[0]._zip_path == saved_as, "Save As retargets the document and future frame loading")
	check(document.meta.labels[0].frames == Vector2i(0, document.frame_count - 1) and document.meta.labels[0].radius == 0.0, "blank range and radius restore defaults")
	compare_archive(before, archive(saved_as))
	check(document.labels._dots.size() == document.meta.labels.size() and document.labels._texts.size() == document.meta.labels.size(), "refresh does not duplicate 3D label nodes")
	var count: int = editor.draft.labels.size()
	editor.add_label()
	check(editor.draft.labels.size() == count + 1, "labels can be added")
	editor.remove_label()
	check(editor.draft.labels.size() == count, "labels can be removed")
	editor.show_labels(0)
	document.seek(1)
	document.labels._selected = 0
	await get_tree().create_timer(0.5).timeout
	check(document.labels._texts[0].visible and document.labels._texts[0].text == "Edited label\nSecond line", "edited 3D text is visible in the original volume")
	editor.gui_release_focus()
	var minimum: Vector2 = editor.get_node("Root").get_combined_minimum_size()
	var viewport_size := editor.get_visible_rect().size
	check(minimum.x <= viewport_size.x and minimum.y <= viewport_size.y, "editor form fits inside the window")
	FileAccess.open(directory.path_join("results.json"), FileAccess.WRITE).store_string(JSON.stringify({checks = checks, failures = failures, stage = "complete", source = source, edited_zip = saved_as, native = native, layout = {window = str(editor.size), viewport = str(editor.get_visible_rect().size), minimum = str(editor.get_node("Root").get_combined_minimum_size()), scale = editor.content_scale_factor}}, "\t"))
	print("Label editing tests: %d checks, %d failures" % [checks, failures.size()])
	if not native:
		editor.close()
		document.close()
		await get_tree().process_frame
		get_tree().quit(0 if failures.is_empty() else 1)

func wait_save() -> void:
	for tick in 600:
		if not editor.is_saving():
			return
		await get_tree().create_timer(0.1).timeout
	check(false, "save completes within 60 seconds")

func archive(path: String) -> Dictionary:
	var zip := ZIPReader.new()
	check(zip.open(path) == OK, "archive can be read")
	var result := {}
	for file in zip.get_files():
		var bytes := zip.read_file(file)
		if file == "meta.json":
			var manifest: Dictionary = JSON.parse_string(bytes.get_string_from_utf8())
			manifest.erase("labels")
			result[file] = manifest
		else:
			var hash := HashingContext.new()
			hash.start(HashingContext.HASH_SHA256)
			if not bytes.is_empty():
				hash.update(bytes)
			result[file] = hash.finish()
	zip.close()
	return result

func compare_archive(before: Dictionary, after: Dictionary) -> void:
	check(before.keys().all(func(file: String) -> bool: return after.has(file)), "all ZIP members are retained")
	for file in before:
		check(after.has(file) and before[file] == after[file], "non-label content unchanged: " + file)
	for file: String in after:
		if not before.has(file):
			# ZIPPacker may add explicit entries for implicit parent folders.
			var empty := HashingContext.new()
			empty.start(HashingContext.HASH_SHA256)
			check(after[file] == empty.finish() and before.keys().any(func(path: String) -> bool: return path.begins_with(file + "/")), "extra ZIP entry is only a parent folder: " + file)
