@tool
extends EditorPlugin

# MCP 服务器完全由本插件的启用/停用开关管理, 无需手动改设置或 project.godot:
#   - 启用插件: 写入 autoload 行 + 设置 enabled=true, 并启动编辑器 MCP 服务器
#   - 停用插件: 停止服务器, 移除 autoload 行 + 设置 enabled=false
# autoload 行(DevMCP)只对"游戏运行进程"起作用(run_game 时游戏内开启运行时服务器),
# 编辑器本身的服务器由本插件持有的 MCPDevServer 节点提供, 两者互不冲突。

const DevProjectSetup = preload("res://addons/DEVFramework/Tool/DevProjectSetup.gd")
const DevAudioExamples = preload("res://addons/DEVFramework/Tool/DevAudioExamples.gd")

const AUTOLOAD_NAME := "DevMCP"
const AUTOLOAD_PATH := "res://addons/DEVFramework/MCP/MCPDevServer.gd"

var _mcp: MCPDevServer


func _enter_tree() -> void:
	_register("dev_framework/log/enabled", TYPE_BOOL, true)
	_register("dev_framework/log/show_timestamps", TYPE_BOOL, false)
	_register("dev_framework/log/ignored_tags", TYPE_PACKED_STRING_ARRAY, PackedStringArray())
	_register("dev_framework/save_tool/encrypt_salt", TYPE_STRING, ProjectSettings.get_setting("application/config/name", "GodotProject"))
	_register("dev_framework/mcp/enabled", TYPE_BOOL, true)
	_register("dev_framework/mcp/port", TYPE_INT, 8931)
	_register("dev_framework/mcp/runtime_port", TYPE_INT, 8932)
	_register("dev_framework/mcp/token", TYPE_STRING, "")
	_register("dev_framework/audio/default_sample_rate", TYPE_INT, 44100)
	add_tool_menu_item("创建 DEV 项目结构...", Callable(self, "_on_create_structure"))
	add_tool_menu_item("DEV 音频：生成示例音频定义...", Callable(self, "_on_create_audio_examples"))
	# 启用插件: 开启 MCP
	_set_mcp_enabled(true)


func _exit_tree() -> void:
	remove_tool_menu_item("创建 DEV 项目结构...")
	remove_tool_menu_item("DEV 音频：生成示例音频定义...")
	# 停用插件: 关闭 MCP
	_set_mcp_enabled(false)


func _on_create_structure() -> void:
	DevProjectSetup.create_structure()


func _on_create_audio_examples() -> void:
	var results := DevAudioExamples.create_all()
	LogTool.log("音频", "示例生成完成: ", results)


## 统一开关: enable=true 启动服务器并写 autoload, 否则停止并移除 autoload
func _set_mcp_enabled(enable: bool) -> void:
	ProjectSettings.set_setting("dev_framework/mcp/enabled", enable)
	_write_autoload_row(enable)
	if enable:
		if _mcp == null:
			_mcp = MCPDevServer.new()
			add_child(_mcp)
		_mcp.start_editor()
	else:
		if _mcp:
			_mcp.stop()
			_mcp.queue_free()
			_mcp = null


## 写入/移除 project.godot 的 autoload 行(供游戏运行进程的运行时服务器使用)
func _write_autoload_row(enable: bool) -> void:
	if enable:
		ProjectSettings.set_setting("autoload/" + AUTOLOAD_NAME, "*" + AUTOLOAD_PATH)
	else:
		ProjectSettings.set_setting("autoload/" + AUTOLOAD_NAME, null)
	ProjectSettings.save()


func _register(name: String, type: int, default) -> void:
	if not ProjectSettings.has_setting(name):
		ProjectSettings.set_setting(name, default)
	ProjectSettings.add_property_info({"name": name, "type": type})
	ProjectSettings.set_initial_value(name, default)