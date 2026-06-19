@tool
extends EditorPlugin

const DevProjectSetup = preload("res://addons/DEVFramework/Tool/DevProjectSetup.gd")


func _enter_tree() -> void:
	_register("dev_framework/log/enabled", TYPE_BOOL, true)
	_register("dev_framework/log/show_timestamps", TYPE_BOOL, false)
	_register("dev_framework/log/ignored_tags", TYPE_PACKED_STRING_ARRAY, PackedStringArray())
	_register("dev_framework/save_tool/encrypt_salt", TYPE_STRING, ProjectSettings.get_setting("application/config/name", "GodotProject"))
	add_tool_menu_item("创建 DEV 项目结构...", Callable(self, "_on_create_structure"))


func _exit_tree() -> void:
	remove_tool_menu_item("创建 DEV 项目结构...")


func _on_create_structure() -> void:
	DevProjectSetup.create_structure()


func _register(name: String, type: int, default) -> void:
	if not ProjectSettings.has_setting(name):
		ProjectSettings.set_setting(name, default)
	ProjectSettings.add_property_info({"name": name, "type": type})
	ProjectSettings.set_initial_value(name, default)
