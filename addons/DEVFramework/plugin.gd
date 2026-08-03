@tool
extends EditorPlugin

const DevProjectSetup = preload("res://addons/DEVFramework/Tool/DevProjectSetup.gd")

var _mcp: MCPDevServer


func _enter_tree() -> void:
	_register("dev_framework/log/enabled", TYPE_BOOL, true)
	_register("dev_framework/log/show_timestamps", TYPE_BOOL, false)
	_register("dev_framework/log/ignored_tags", TYPE_PACKED_STRING_ARRAY, PackedStringArray())
	_register("dev_framework/save_tool/encrypt_salt", TYPE_STRING, ProjectSettings.get_setting("application/config/name", "GodotProject"))
	_register("dev_framework/mcp/enabled", TYPE_BOOL, true)
	_register("dev_framework/mcp/port", TYPE_INT, 8931)
	add_tool_menu_item("创建 DEV 项目结构...", Callable(self, "_on_create_structure"))
	# 插件启用时启动 MCP 服务器(服务编辑器), 并每帧驱动它处理请求
	_mcp = MCPDevServer.new(get_editor_interface())
	_mcp.start()


func _exit_tree() -> void:
	remove_tool_menu_item("创建 DEV 项目结构...")
	if _mcp:
		_mcp.shutdown()
		_mcp = null


func _process(_delta: float) -> void:
	if _mcp:
		_mcp.poll()


func _on_create_structure() -> void:
	DevProjectSetup.create_structure()


func _register(name: String, type: int, default) -> void:
	if not ProjectSettings.has_setting(name):
		ProjectSettings.set_setting(name, default)
	ProjectSettings.add_property_info({"name": name, "type": type})
	ProjectSettings.set_initial_value(name, default)