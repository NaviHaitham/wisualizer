extends SceneTree

var out := ProjectSettings.globalize_path("res://builds/simulator-test/")
var packer := PCKPacker.new()

func _initialize() -> void:
	ProjectSettings.set_setting("application/run/main_scene", "res://simulator_test.tscn")
	ProjectSettings.save_custom(out + "test-project.binary")
	packer.pck_start(out + "simulator-test.pck")
	var source := FileAccess.open(out + "wisualizer.pck", FileAccess.READ)
	assert(source != null, "Export visionOS to builds/simulator-test/wisualizer.xcodeproj first.")
	assert(source.get_32() == 0x43504447 and source.get_32() == 4, "The test packer expects Godot PCK version 4.")
	source.seek(24)
	var base := source.get_64()
	var directory := source.get_64()
	source.seek(directory)
	var count := source.get_32()
	for index in count:
		var path := source.get_buffer(source.get_32()).get_string_from_utf8()
		var offset := source.get_64()
		var size := source.get_64()
		source.get_buffer(20)
		var next := source.get_position()
		if path != "project.binary":
			source.seek(base + offset)
			packer.add_file_from_buffer("res://" + path, source.get_buffer(size))
		source.seek(next)
	packer.add_file("res://project.binary", out + "test-project.binary")
	packer.add_file("res://simulator_test.tscn", "res://tests/visionos_labels_test.tscn")
	packer.add_file("res://simulator_test.gd", "res://tests/visionos_labels_test.gd")
	var result := packer.flush()
	print("Test PCK result: ", result)
	quit(result)
