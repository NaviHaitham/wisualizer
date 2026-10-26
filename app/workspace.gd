extends Window
## The desktop's editor for a ZIP: a window where GLBs, bricks and images
## are imported, frames, models, fields and labels are set, and the notes are
## written with a live preview, then saved as a ZIP in the library. Edits
## a [Draft]; see docs/zip-format.md for what it saves.

const Draft := preload("res://app/draft.gd")
const NotesImages := preload("res://app/notes_images.gd")
const NativeDialogs := preload("res://app/native_dialogs.gd")
## Seconds after the last keystroke before the notes preview refreshes.
const PREVIEW_DELAY := 0.3

## The ZIP was saved; the library may show it, or open it as it plays.
signal saved(path: String, play: bool)

var draft := Draft.new()
## Where the ZIP is saved.
var target := ""
var _save_thread: Thread
## The textures the notes preview and the image preview show.
var _preview_images := NotesImages.new()
var _image_preview := NotesImages.new()
var _preview_timer: SceneTreeTimer
## Set while the forms show a draft, so their edits aren't taken as changes.
var _filling := false
var _label_inputs := {}
var _label_errors := {}


## Starts on the ZIP at [param path], or empty for a new one saved there.
## Returns an empty string, or what is wrong with the ZIP.
func start(path: String) -> String:
	NativeDialogs.apply_to(self)
	target = path
	if FileAccess.file_exists(path):
		var error := draft.open(path)
		if not error.is_empty():
			return error
	else:
		draft.title = path.get_file().get_basename()
	_show_target()
	_show_draft()
	show_page("Frames")
	show()
	return ""


func _show_draft() -> void:
	_label_inputs.clear()
	_label_errors.clear()
	_filling = true
	%Title.text = draft.title
	%Editor.text = draft.notes
	_filling = false
	show_frames()
	show_models()
	show_fields()
	show_labels()
	show_images()
	refresh_preview()


## Shows the page called [param page_name], one of the sidebar's sections.
func show_page(page_name: String) -> void:
	for page in %Pages.get_children():
		page.visible = page.name == page_name
	if page_name == "Labels":
		_show_model_bounds()
	# Through its group, so the other sections let go; only toggled fires.
	(%Pages.get_node("../../Sidebar/Column/%sSection" % page_name) as Button).button_pressed = true


func close() -> void:
	if _save_thread:
		return
	draft.close()
	queue_free()


func edit_title(text: String) -> void:
	draft.title = text


## Writes the ZIP on a thread, so a big one doesn't freeze the window.
func save(play := false) -> void:
	if _save_thread:
		return
	var problem: String = _label_errors.values()[0] if not _label_errors.is_empty() else draft.problems()
	if not problem.is_empty():
		_show_status(problem)
		return
	_set_busy(true, "Saving…")
	_save_thread = Thread.new()
	_save_thread.start(func() -> void:
		var error := draft.save(ProjectSettings.globalize_path(target))
		_finish_save.call_deferred(error, play))


func _finish_save(error: String, play: bool) -> void:
	_save_thread.wait_to_finish()
	_save_thread = null
	_set_busy(false, error if not error.is_empty() else "Saved")
	if error.is_empty():
		_label_inputs.clear()
		_label_errors.clear()
		# Sources now point into the saved ZIP.
		show_models()
		show_fields()
		show_images()
		refresh_preview()
		saved.emit(target, play)


func preview() -> void:
	save(true)


func ask_save_as() -> void:
	var dialog: FileDialog = %SaveAsFile
	dialog.current_file = target.get_file()
	dialog.popup_centered()


## Saves to [param path] instead, and keeps working on that ZIP.
func save_as(path: String) -> void:
	if path.get_extension().to_lower() != "zip":
		path += ".zip"
	target = path
	_show_target()
	save()


func _show_target() -> void:
	title = "%s – Workspace" % target.get_file().get_basename()
	%File.text = target.get_file()


func _set_busy(busy: bool, status: String) -> void:
	if busy:
		gui_release_focus()
	$Root.process_mode = Node.PROCESS_MODE_DISABLED if busy else Node.PROCESS_MODE_INHERIT
	%Save.disabled = busy
	%SaveAs.disabled = busy
	%Preview.disabled = busy
	%Pages.modulate.a = 0.6 if busy else 1.0
	_show_status(status)


func _show_status(message: String) -> void:
	%Status.text = message


# Frames

func show_frames() -> void:
	var tree: Tree = %FrameList
	tree.clear()
	tree.set_column_title(0, "Frame")
	tree.set_column_title(1, "Time")
	for column in 2:
		tree.set_column_title_alignment(column, HORIZONTAL_ALIGNMENT_LEFT)
	tree.set_column_expand(0, false)
	tree.set_column_custom_minimum_width(0, 100)
	var root := tree.create_item()
	for index in draft.times.size():
		var item := tree.create_item(root)
		item.set_text(0, str(index + 1))
		item.set_text(1, _number(draft.times[index]))
		item.set_editable(1, true)
	if draft.times.is_empty():
		%FramesCaption.text = "No frames yet. Importing GLBs or bricks with solver times fills them in; or add them here."
	else:
		%FramesCaption.text = "%d frames, played in this order, with their solver times. Double-click a time to change it." % draft.times.size()


func add_frame() -> void:
	draft.times.append(draft.times[-1] + 1.0 if not draft.times.is_empty() else 0.0)
	show_frames()


func remove_frame() -> void:
	var item: TreeItem = %FrameList.get_selected()
	if item == null:
		return
	var index := item.get_index()
	draft.times.remove_at(index)
	for model in draft.models:
		if model.changes() and index < model.files.size():
			model.files.remove_at(index)
	for field in draft.fields:
		var bricks := {}
		for frame: int in field.bricks:
			if frame < index:
				bricks[frame] = field.bricks[frame]
			elif frame > index:
				bricks[frame - 1] = field.bricks[frame]
		field.bricks = bricks
	# Labels with no surviving frames leave with their last frame. In
	# particular, never turn an explicit last frame of 0 into the -1 default.
	for label_index in range(draft.labels.size() - 1, -1, -1):
		var label := draft.labels[label_index]
		# The frame was already removed, so this was the last index before it.
		var last := label.frames.y if label.frames.y >= 0 else draft.times.size()
		if label.frames.x == last and index == last:
			draft.labels.remove_at(label_index)
			continue
		if index < label.frames.x:
			label.frames.x -= 1
		if index <= label.frames.y:
			label.frames.y -= 1
	show_frames()
	show_models()
	show_fields()
	show_labels()


func edit_frame() -> void:
	var item: TreeItem = %FrameList.get_edited()
	if item == null:
		return
	var text := item.get_text(1)
	if text.is_valid_float():
		draft.times[item.get_index()] = text.to_float()
	else:
		item.set_text(1, _number(draft.times[item.get_index()]))


# Models

func import_glbs(paths: PackedStringArray) -> void:
	var error := draft.add_glbs(paths)
	if not error.is_empty():
		_show_status(error)
		return
	show_frames()
	show_models(draft.models.size() - 1)
	# Bricks imported before the models are scaled to them now.
	for field in draft.fields:
		draft.fit_field(field)
	show_fields()


func show_models(selected := -1) -> void:
	var list: ItemList = %ModelList
	if selected < 0 and list.is_anything_selected():
		selected = list.get_selected_items()[0]
	list.clear()
	for model in draft.models:
		list.add_item(model.name)
	selected = clampi(selected, -1, draft.models.size() - 1)
	if selected >= 0:
		list.select(selected)
	show_model(selected)


func show_model(index: int) -> void:
	%ModelForm.get_parent().visible = index >= 0
	if index < 0:
		return
	var model: Draft.Model = draft.models[index]
	_filling = true
	%ModelName.text = model.name
	_filling = false
	if model.changes():
		%ModelInfo.text = "One per frame, %d in all, from %s" % [model.files.size(), _describe(model.files[0])]
	else:
		%ModelInfo.text = "One, shown at every frame: %s" % _describe(model.files[0])


func rename_model(text: String) -> void:
	if _filling:
		return
	var index := _selected(%ModelList)
	if index >= 0:
		draft.models[index].name = text
		%ModelList.set_item_text(index, text)


func remove_model() -> void:
	var index := _selected(%ModelList)
	if index >= 0:
		draft.models.remove_at(index)
		show_models(index - 1)


func move_model(by: int) -> void:
	var index := _selected(%ModelList)
	var to := index + by
	if index < 0 or to < 0 or to >= draft.models.size():
		return
	var model: Draft.Model = draft.models[index]
	draft.models.remove_at(index)
	draft.models.insert(to, model)
	show_models(to)


# Fields

func import_bovs(paths: PackedStringArray) -> void:
	var error := draft.add_bovs(paths)
	if not error.is_empty():
		_show_status(error)
		return
	show_frames()
	show_fields(draft.fields.size() - 1)


func show_fields(selected := -1) -> void:
	var list: ItemList = %FieldList
	if selected < 0 and list.is_anything_selected():
		selected = list.get_selected_items()[0]
	list.clear()
	for field in draft.fields:
		list.add_item(field.name)
	selected = clampi(selected, -1, draft.fields.size() - 1)
	if selected >= 0:
		list.select(selected)
	show_field(selected)


func show_field(index: int) -> void:
	%FieldForm.get_parent().visible = index >= 0
	if index < 0:
		return
	var field: Draft.Field = draft.fields[index]
	_filling = true
	%FieldName.text = field.name
	%Quantity.text = field.quantity
	%Unit.text = field.unit
	%Range.text = "%s, %s" % [_number(field.range.x), _number(field.range.y)]
	%Origin.text = _vector_text(field.origin)
	%Size.text = _vector_text(field.size)
	%First.button_pressed = index == draft.first_field
	_filling = false
	var missing := draft.times.size() - field.bricks.size()
	%FieldInfo.text = "%d × %d × %d cells; a brick at %d of %d frames%s" % [field.cells.x, field.cells.y, field.cells.z, field.bricks.size(), draft.times.size(), ", none at the others" if missing > 0 else ""]


func edit_field() -> void:
	if _filling:
		return
	var index := _selected(%FieldList)
	if index < 0:
		return
	var field: Draft.Field = draft.fields[index]
	field.name = %FieldName.text
	%FieldList.set_item_text(index, field.name)
	field.quantity = %Quantity.text
	field.unit = %Unit.text
	var span := _numbers(%Range.text)
	if span.size() == 2:
		field.range = Vector2(span[0], span[1])
	var origin := _numbers(%Origin.text)
	if origin.size() == 3:
		field.origin = Vector3(origin[0], origin[1], origin[2])
	var size := _numbers(%Size.text)
	if size.size() == 3:
		field.size = Vector3(size[0], size[1], size[2])


func fit_field() -> void:
	var index := _selected(%FieldList)
	if index < 0:
		return
	if not draft.model_bounds().has_volume():
		_show_status("Import a GLB first: the box is fitted to the models.")
		return
	draft.fit_field(draft.fields[index])
	show_field(index)


func set_first_field(pressed: bool) -> void:
	if _filling:
		return
	var index := _selected(%FieldList)
	if pressed and index >= 0:
		draft.first_field = index
	elif not pressed and index == draft.first_field:
		draft.first_field = 0
		%First.set_pressed_no_signal(index == 0)


func remove_field() -> void:
	var index := _selected(%FieldList)
	if index >= 0:
		draft.fields.remove_at(index)
		if draft.first_field >= draft.fields.size():
			draft.first_field = 0
		show_fields(index - 1)


# Labels

## Adds a label at the models' center, and starts on its text.
func add_label() -> void:
	var label := Draft.PointLabel.new()
	var bounds := draft.model_bounds()
	if bounds.has_volume():
		label.position = bounds.get_center()
	draft.labels.append(label)
	show_labels(draft.labels.size() - 1)
	%LabelText.grab_focus()


func show_labels(selected := -1) -> void:
	for label in _label_errors.keys():
		if not draft.labels.has(label):
			_label_errors.erase(label)
			_label_inputs.erase(label)
	var list: ItemList = %LabelList
	if selected < 0 and list.is_anything_selected():
		selected = list.get_selected_items()[0]
	list.clear()
	for label in draft.labels:
		list.add_item(label.title())
	selected = clampi(selected, -1, draft.labels.size() - 1)
	if selected >= 0:
		list.select(selected)
	show_label(selected)


func show_label(index: int) -> void:
	%LabelForm.get_parent().visible = index >= 0
	if index < 0:
		return
	var label: Draft.PointLabel = draft.labels[index]
	_filling = true
	var inputs: Dictionary = _label_inputs.get(label, {})
	%LabelText.text = inputs.get("text", label.text)
	%LabelPosition.text = inputs.get("position", _vector_text(label.position))
	%LabelRadius.text = inputs.get("radius", _number(label.radius) if label.radius > 0.0 else "")
	if label.frames == Vector2i(0, -1):
		%LabelFrames.text = ""
	else:
		var last := label.frames.y if label.frames.y >= 0 else draft.times.size() - 1
		%LabelFrames.text = "%d, %d" % [label.frames.x + 1, last + 1]
	%LabelFrames.text = inputs.get("frames", %LabelFrames.text)
	_filling = false
	_show_status(_label_errors.get(label, ""))


func edit_label() -> void:
	if _filling:
		return
	var index := _selected(%LabelList)
	if index < 0:
		return
	var label: Draft.PointLabel = draft.labels[index]
	_label_inputs[label] = {text = %LabelText.text, position = %LabelPosition.text, radius = %LabelRadius.text, frames = %LabelFrames.text}
	label.text = %LabelText.text
	%LabelList.set_item_text(index, label.title())
	var problem := _label_form_problem()
	if not problem.is_empty():
		_label_errors[label] = problem
		_show_status(problem)
		return
	_label_errors.erase(label)
	_show_status("")
	var position := _label_numbers(%LabelPosition.text)
	label.position = Vector3(position[0], position[1], position[2])
	var radius: String = %LabelRadius.text.strip_edges()
	label.radius = radius.to_float() if not radius.is_empty() else 0.0
	# Counted from 1, as the controls show them; one number is one frame.
	var frames := _label_numbers(%LabelFrames.text)
	if frames.is_empty():
		label.frames = Vector2i(0, -1)
	elif frames.size() <= 2:
		label.frames = Vector2i(int(frames[0]) - 1, int(frames[-1]) - 1)


func _label_form_problem() -> String:
	if %LabelText.text.strip_edges().is_empty():
		return "Enter text for the label."
	if _label_numbers(%LabelPosition.text).size() != 3:
		return "Point needs three finite numbers: x, y, z."
	var radius: String = %LabelRadius.text.strip_edges()
	if not radius.is_empty() and (not radius.is_valid_float() or not is_finite(radius.to_float()) or radius.to_float() < 0.0):
		return "Radius must be a nonnegative number, or blank for 3 cm."
	if not %LabelFrames.text.strip_edges().is_empty():
		var frames := _label_numbers(%LabelFrames.text)
		if frames.is_empty() or frames.size() > 2:
			return "Frames needs one number, or first, last; leave blank for all frames."
		for value in frames:
			if value != floor(value) or value < 1 or value > draft.times.size():
				return "Frames must be whole numbers from 1 to %d." % draft.times.size()
		if frames[0] > frames[-1]:
			return "The first frame must not come after the last."
	return ""


static func _label_numbers(text: String) -> PackedFloat64Array:
	var values := PackedFloat64Array()
	if text.strip_edges().is_empty():
		return values
	for part in text.split(","):
		var value: String = part.strip_edges()
		if not value.is_valid_float() or not is_finite(value.to_float()):
			return PackedFloat64Array()
		values.append(value.to_float())
	return values


func remove_label() -> void:
	var index := _selected(%LabelList)
	if index >= 0:
		_label_inputs.erase(draft.labels[index])
		_label_errors.erase(draft.labels[index])
		draft.labels.remove_at(index)
		show_labels(index - 1)


## Where the models are, to place labels by. Reading every model's bounds
## takes a while, so only while the labels show.
func _show_model_bounds() -> void:
	var bounds := draft.model_bounds()
	if bounds.has_volume():
		%LabelBounds.text = "From %s to %s, in the models' units" % [_vector_text(bounds.position), _vector_text(bounds.end)]
	else:
		%LabelBounds.text = "Import a GLB to see where the models are."


# Images

func import_images(paths: PackedStringArray) -> void:
	draft.add_images(paths)
	show_images(draft.images.size() - 1)
	refresh_preview()


func show_images(selected := -1) -> void:
	var list: ItemList = %ImageList
	if selected < 0 and list.is_anything_selected():
		selected = list.get_selected_items()[0]
	list.clear()
	for name: String in draft.images:
		list.add_item(name)
	selected = clampi(selected, -1, draft.images.size() - 1)
	if selected >= 0:
		list.select(selected)
	show_image(selected)


func show_image(index: int) -> void:
	var preview: TextureRect = %ImagePreview
	if index < 0:
		preview.texture = null
		return
	var name: String = draft.images.keys()[index]
	var images := NotesImages.new()
	images.embed("[img]%s[/img]" % Draft.IMAGES_FOLDER.path_join(name), draft.read_file, Draft.NOTES_FILE, "image", %NotesPreview.get_theme_color(&"default_color"), %NotesPreview.get_theme_font_size(&"normal_font_size"))
	preview.texture = images.textures[0] if not images.textures.is_empty() else null
	_image_preview = images


func remove_image() -> void:
	var index := _selected(%ImageList)
	if index >= 0:
		draft.images.erase(draft.images.keys()[index])
		show_images(index - 1)
		refresh_preview()


## Puts an [img] tag for the picked image at the notes' cursor.
func insert_image() -> void:
	var index := _selected(%ImageList)
	if index < 0:
		return
	var editor: CodeEdit = %Editor
	editor.insert_text_at_caret("[img]%s[/img]" % Draft.IMAGES_FOLDER.path_join(draft.images.keys()[index]))
	show_page("Notes")
	editor.grab_focus()


# Notes

func edit_notes() -> void:
	if _filling:
		return
	draft.notes = %Editor.text
	if _preview_timer and _preview_timer.time_left > 0.0:
		return
	_preview_timer = get_tree().create_timer(PREVIEW_DELAY)
	_preview_timer.timeout.connect(refresh_preview)


func refresh_preview() -> void:
	# A save reopens the ZIP the images come from; it refreshes when done.
	if _save_thread:
		return
	var preview: RichTextLabel = %NotesPreview
	var images := NotesImages.new()
	preview.text = images.embed(draft.notes, draft.read_file, Draft.NOTES_FILE, "workspace", preview.get_theme_color(&"default_color"), preview.get_theme_font_size(&"normal_font_size"))
	_preview_images = images


static func _selected(list: ItemList) -> int:
	return list.get_selected_items()[0] if list.is_anything_selected() else -1


static func _describe(source: String) -> String:
	return source.trim_prefix(Draft.IN_ZIP)


static func _vector_text(vector: Vector3) -> String:
	return "%s, %s, %s" % [_number(vector.x), _number(vector.y), _number(vector.z)]


## [param value] to six significant digits, which is all the 32-bit floats
## fields keep, so they don't show noise like 0.11310999840498.
static func _number(value: float) -> String:
	if value == 0.0 or not is_finite(value):
		return String.num(value)
	return String.num(value, maxi(5 - floori(log(absf(value)) / log(10.0)), 0))


static func _numbers(text: String) -> PackedFloat64Array:
	return text.split_floats(",", false)
