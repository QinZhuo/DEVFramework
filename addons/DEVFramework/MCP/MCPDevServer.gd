@tool
## MCP 开发服务器(autoload 单例, 双模式)
## 以 autoload 形式注册, 在编辑器和游戏进程中都会加载(见 project.godot [autoload]):
##   - 编辑器模式(Engine.is_editor_hint): 在 8932 端口提供编辑器工具(场景树/节点/项目设置/截图等)
##     以及游戏运行时工具(经 HTTP 转发到游戏进程的运行时服务器)
##   - 运行时模式: run_game 启动游戏时传入 --mcp-runtime-port, 游戏进程内的 autoload
##     在对应端口开启运行时服务器, 原生提供 get_game_view / simulate_click / simulate_drag /
##     simulate_key / take_screenshot / game_eval / 游戏日志等。因为在游戏进程内,
##     Input.parse_input_event 等引擎 API 直接生效, 这是 Godot 最原生最不易出错的形态。
## 生命周期由 autoload 自身接管, 不再依赖 plugin.gd; 也无需再为"避开 autoload"做任何特殊处理。
class_name MCPDevServer extends Node

## ------- 配置项(ProjectSettings) -------
const SETTING_ENABLED := "dev_framework/mcp/enabled"
const SETTING_PORT := "dev_framework/mcp/port"
const SETTING_RUNTIME_PORT := "dev_framework/mcp/runtime_port"
const SETTING_TOKEN := "dev_framework/mcp/token"
const SETTING_MAX_MESSAGES := "dev_framework/mcp/max_messages"

## 输出给 AI 的核心属性白名单(过滤编辑器内部数百项属性, 控制上下文开销)
const CORE_PROP_NAMES := ["name", "position", "scale", "rotation", "rotation_degrees", "visible", "modulate", "process_mode", "z_index", "text", "color"]

## ------- MCP 常量 -------
const PROTOCOL_VERSION := "2025-03-26"
const SERVER_NAME := "devframework-godot-mcp"
const SERVER_VERSION := "0.2.0"

## 模式
const MODE_EDITOR := "editor"
const MODE_RUNTIME := "runtime"

## 全局唯一实例(编辑器/游戏进程各自持有)
static var instance: MCPDevServer

var _http: MCPTcpHttpServer
var _logger: MCPLogger
var _port := 8932
var _runtime_port := 8933
var _enabled := true
var _tool_handlers := {}        # 工具名 -> Callable
var _tool_defs := []            # 工具定义列表(MCP 格式)
var _mode := MODE_EDITOR        # editor / runtime

## 编辑器模式: 运行中游戏进程 PID(0=未运行)
var _run_pid := 0


## ------- 生命周期(autoload) -------
func _ready() -> void:
	instance = self
	_enabled = ProjectSettings.get_setting(SETTING_ENABLED, true)
	_port = int(ProjectSettings.get_setting(SETTING_PORT, 8932))
	_runtime_port = int(ProjectSettings.get_setting(SETTING_RUNTIME_PORT, _port + 1))
	if Engine.is_editor_hint():
		# 编辑器进程: autoload 的生命周期完全由 plugin.gd 控制(启用时 start_editor()/停用时 stop())。
		# 这里仅登记 instance, 不自动启动, 避免与插件开关产生端口/生命周期冲突。
		return
	# 游戏进程: 仅当带 --mcp-runtime-port 参数时才开启运行时服务器(正常手动运行不受影响)
	if not _enabled:
		return
	var rp := _get_cmdline_int("--mcp-runtime-port", 0)
	if rp > 0:
		_mode = MODE_RUNTIME
		_port = rp
		_runtime_port = rp
		_logger = MCPLogger.new()
		OS.add_logger(_logger)
		_register_runtime_tools()
		start()


## 编辑器模式显式启动(由 plugin.gd 在启用插件时调用)
func start_editor() -> void:
	if _http:
		return
	_mode = MODE_EDITOR
	_enabled = true
	if _logger == null:
		_logger = MCPLogger.new()
		OS.add_logger(_logger)
	_register_editor_tools()
	start()


## 每帧驱动 HTTP 服务器 + 检测游戏进程退出
func _process(_delta: float) -> void:
	if _http:
		_http.poll()
	if _mode == MODE_EDITOR:
		if _run_pid != 0 and not OS.is_process_running(_run_pid):
			_run_pid = 0


## 关闭服务器并移除 Logger(退出时由引擎自动调用)
func _exit_tree() -> void:
	stop()
	if _logger:
		OS.remove_logger(_logger)
		_logger = null


## 读取命令行整数参数, 不存在返回默认值
func _get_cmdline_int(key: String, default: int) -> int:
	var args := OS.get_cmdline_args()
	for i in args.size():
		if args[i] == key and i + 1 < args.size():
			return int(args[i + 1])
	return default


## ------- 服务器启停 -------
func start() -> void:
	if not _enabled or _http:
		return
	_http = MCPTcpHttpServer.new()
	var err := _http.listen(_port)
	if err != OK:
		printerr("MCPDevServer: 监听端口 %d 失败 (错误码 %d)。已自动跳过, AI 助手将无法连接。" % [_port, err])
		_http = null
		return
	_http.request_received.connect(_on_request)
	LogTool.log("MCP", "MCP 服务器已开启(%s): http://127.0.0.1:%d/mcp" % [_mode, _port])
	LogTool.log("MCP", "可用工具(%s): %s" % [_mode, _tool_defs.map(func(d): return d.name)])


func stop() -> void:
	if _http:
		_http.request_received.disconnect(_on_request)
		_http.stop()
		_http = null


func is_running() -> bool:
	return _http != null and _http.is_listening()


## ------- 工具注册 -------
func _add_tool(name: String, desc: String, input_schema: Dictionary, handler: Callable) -> void:
	_tool_handlers[name] = handler
	_tool_defs.append({"name": name, "description": desc, "inputSchema": input_schema})


func _register_editor_tools() -> void:
	_tool_handlers.clear()
	_tool_defs.clear()
	_register_validate_tools()
	_register_log_tools()
	_register_screenshot_tools()
	_register_scene_tools()
	_register_scene_edit_tools()
	_register_project_tools()
	_register_run_tools()
	_register_dev_tools()
	_register_file_tools()
	_register_game_play_tools()


## ------- 工具实现 =======

## -- 脚本/资源验证 --
func _register_validate_tools() -> void:
	_add_tool("validate_script",
		"验证一个 GDScript 脚本的语法与可编译性(不执行)。返回是否有效及错误明细。可传 'path'(res://路径) 读取磁盘脚本, 或 'code'(源码文本)直接验证。注意: 仅存在'被当作错误的警告'(如 untyped_declaration)时会判为有效并在 warnings 中列出; 若验证的脚本 class_name 与已加载类同名(如 addons 内已加载脚本)属环境冲突, 会提示 hint。",
		{"type": "object", "properties": {"path": {"type": "string", "description": "脚本 res:// 路径, 与 code 二选一"}, "code": {"type": "string", "description": "GDScript 源码文本, 与 path 二选一"}}},
		_call_validate_script)

	_add_tool("validate_resource",
		"验证一个资源/场景文件能否被引擎正确加载。返回是否可加载、资源类型及错误信息。常见于排查 .tres/.tscn 资源损坏或依赖缺失。",
		{"type": "object", "properties": {"path": {"type": "string", "description": "资源 res:// 路径"}}},
		_call_validate_resource)

	_add_tool("list_dir",
		"列出指定 res:// 或 user:// 目录下的内容(目录/文件)。便于了解项目结构。",
		{"type": "object", "properties": {"path": {"type": "string", "description": "目录路径, 默认 res://"}, "recursive": {"type": "boolean", "description": "是否递归列出子目录, 默认 false"}}},
		_call_list_dir)


## -- 日志/错误 --
func _register_log_tools() -> void:
	_add_tool("get_logs",
		"获取日志(print/printerr 输出)。支持 since 索引增量获取, 以及按关键字过滤、截断数量。返回日志数组(含时间戳/是否错误流)。",
		{"type": "object", "properties": {"since": {"type": "integer", "description": "从上一次获取的索引之后增量获取, 默认从头全部"}, "keyword": {"type": "string", "description": "过滤包含此关键字的日志"}, "max": {"type": "integer", "description": "最多返回条数, 默认 200"}}},
		_call_get_logs)

	_add_tool("get_errors",
		"获取捕获的错误(脚本错误/assert/push_error 等), 每个错误包含信息、来源文件、行号、类型及 GDScript 栈追踪。这是定位崩溃与逻辑错误的关键工具。",
		{"type": "object", "properties": {"since": {"type": "integer", "description": "增量获取索引, 默认全部"}, "max": {"type": "integer", "description": "最多返回条数, 默认 100"}}},
		_call_get_errors)

	_add_tool("clear_errors",
		"清空已捕获的错误缓冲区, 便于开始新一轮调试观察。",
		{"type": "object", "properties": {}},
		_call_clear_errors)


## -- 截图 --
func _register_screenshot_tools() -> void:
	_add_tool("take_screenshot",
		"捕获编辑器当前视口(编辑器窗口)的截图并保存到本地(res://.godot/mcp_screenshots/)。返回截图文件路径、像素尺寸与占用字节。AI 可通过文件路径读取分析画面。可选 max_width 限制最大宽度以降采样(减少 AI 读图开销)。可选 capture_type: 'editor' 编辑器视口(默认), 'scene' 当前场景缩略图, 'game' 运行中的游戏画面(需先 run_game)。",
		{"type": "object", "properties": {
			"filename": {"type": "string", "description": "截图文件名(不含路径), 默认自动按时间命名"},
			"max_width": {"type": "integer", "description": "可选: 若截图宽度超过该值则等比缩小以便 AI 读图(默认不缩放)"},
			"capture_type": {"type": "string", "description": "截图类型: 'editor' 编辑器视口(默认), 'scene' 当前场景缩略图, 'game' 运行中的游戏画面"},
			"scene_path": {"type": "string", "description": "当 capture_type='scene' 时, 指定场景路径(默认当前编辑场景)"},
			"thumbnail_size": {"type": "integer", "description": "场景缩略图尺寸(像素, 默认 256)"}
		}},
		_call_take_screenshot)


## -- 场景树 / 节点 --
func _register_scene_tools() -> void:
	_add_tool("get_scene_tree",
		"获取当前正在编辑的场景的节点树结构(节点路径/名称/类型)。用于理解场景与逻辑结构。未打开场景时返回空。",
		{"type": "object", "properties": {"max_depth": {"type": "integer", "description": "最大展开深度, 默认 8"}, "include_properties": {"type": "boolean", "description": "是否附带每个节点的关键属性, 默认 false"}}},
		_call_get_scene_tree)

	_add_tool("get_node_info",
		"获取当前编辑场景中指定节点的属性列表及当前值。输入节点名称或路径(如根节点名/子节点路径)。用于检查节点状态。",
		{"type": "object", "properties": {"path": {"type": "string", "description": "节点路径(编辑场景内), 如 'Main' 或 'Main/Player'"}}},
		_call_get_node_info)

	_add_tool("set_node_property",
		"修改当前编辑场景中指定节点的属性值(用于调试调整逻辑)。修改仅影响内存中的场景, 不会写回 .tscn 文件直到手动保存。",
		{"type": "object", "properties": {"path": {"type": "string", "description": "节点路径(编辑场景内)"}, "property": {"type": "string", "description": "属性名"}, "value": {"description": "新值(支持数字/字符串/布尔; Vector2 等可传 '1,2' 字符串)"}}},
		_call_set_node_property)

	_add_tool("call_node_method",
		"调用当前编辑场景中某节点的方法(用于调试触发逻辑, 如播放动画/切换状态)。参数以数组传入。",
		{"type": "object", "properties": {"path": {"type": "string", "description": "节点路径(编辑场景内)"}, "method": {"type": "string", "description": "方法名"}, "args": {"type": "array", "description": "参数数组"}}},
		_call_call_node_method)


## -- 场景编辑 --
func _register_scene_edit_tools() -> void:
	_add_tool("add_node",
		"在当前编辑场景中添加节点或实例化子场景。parent 为父节点路径(缺省根), node_type 为节点类型类名(如 Sprite2D/CharacterBody2D/Label)或子场景 res:// 路径。",
		{"type": "object", "properties": {"parent": {"type": "string", "description": "父节点路径(编辑场景内), 缺省为场景根"}, "node_type": {"type": "string", "description": "节点类型类名或子场景 res:// 路径"}, "name": {"type": "string", "description": "新节点名称(可选)"}}},
		_call_add_node)

	_add_tool("save_scene",
		"保存当前正在编辑的场景到磁盘(set_node_property/add_node 的改动需要保存后才会写回 .tscn)。",
		{"type": "object", "properties": {}},
		_call_save_scene)


## -- 项目信息 --
func _register_project_tools() -> void:
	_add_tool("get_project_info",
		"获取 Godot 项目基本信息(项目名/Godot 版本/当前编辑场景/运行模式/插件开关等)。",
		{"type": "object", "properties": {}},
		_call_get_project_info)

	_add_tool("get_project_settings",
		"获取项目关键配置(主场景/autoload/输入映射/图层命名等), 帮助 AI 理解项目约定。",
		{"type": "object", "properties": {}},
		_call_get_project_settings)


## -- 运行游戏 --
func _register_run_tools() -> void:
	_add_tool("run_game",
		"启动项目(独立进程)以便实际测试。必须提供 scene: 要运行的场景 res:// 路径(如 res://Scenes/Main/Main.tscn), 缺省会报错。游戏进程会以 --mcp-runtime-port 开启运行时服务器, 之后 get_game_view / simulate_click / simulate_drag / simulate_key / take_screenshot(capture_type=game) / game_eval / get_game_logs 等运行时工具将可用(经编辑器转发)。",
		{"type": "object", "properties": {"scene": {"type": "string", "description": "要运行的场景 res:// 路径, 必填(如 res://Scenes/Main/Main.tscn)"}}, "required": ["scene"]},
		_call_run_game)

	_add_tool("stop_game",
		"停止当前运行中的游戏进程(若在运行)。",
		{"type": "object", "properties": {}},
		_call_stop_game)


## -- 开发辅助(重载/求值/设置) --
func _register_dev_tools() -> void:
	_add_tool("reload_project",
		"触发编辑器重新扫描项目: 重建全局类缓存(新增 class_name 立即生效) + 重扫资源文件。新脚本/新资源不生效时调用此工具。可选 reopen_scene 重载当前编辑场景(未保存修改会丢失)。",
		{"type": "object", "properties": {
			"reopen_scene": {"type": "boolean", "description": "是否重载当前编辑场景, 默认 false(注意: 未保存修改会丢失)"}
		}},
		_call_reload_project)

	_add_tool("eval_code",
		"在编辑器进程中执行一段 GDScript 代码(常用于查值/调工具/验证逻辑)。代码中可显式 return 返回值; print 输出会进入 get_logs。代码会被包装为挂到场景树的 Node 方法, 因此可直接使用 get_tree()/get_node() 访问场景。缩进自动归一化(tab/空格均可)。注意: 字符串内需要换行请用 char(10) 而非 '\\n'(JSON 传输会拆行导致字符串被破坏)。",
		{"type": "object", "properties": {"code": {"type": "string", "description": "要执行的 GDScript 代码(方法体内容, 缩进由服务器自动处理)"}}},
		_call_eval_code)

	_add_tool("get_global_classes",
		"列出当前已注册的全部全局类(class_name 全局类), 含名称/脚本路径/基类。用于确认新脚本是否已进入类缓存。",
		{"type": "object", "properties": {}},
		_call_get_global_classes)

	_add_tool("open_scene",
		"在编辑器打开指定场景文件(res:// 路径)。",
		{"type": "object", "properties": {"path": {"type": "string", "description": "场景 res:// 路径"}}},
		_call_open_scene)

	_add_tool("set_main_scene",
		"设置项目主场景(application/run/main_scene)并保存 project.godot。",
		{"type": "object", "properties": {"path": {"type": "string", "description": "主场景 res:// 路径"}}},
		_call_set_main_scene)

	_add_tool("get_project_setting",
		"读取任意项目设置项的值(ProjectSettings), 如 application/config/name、audio/buses/default_bus_layout 等。",
		{"type": "object", "properties": {"name": {"type": "string", "description": "设置项名称"}}},
		_call_get_project_setting)

	_add_tool("set_project_setting",
		"修改任意项目设置项并保存(ProjectSettings)。value 传 JSON 值。",
		{"type": "object", "properties": {"name": {"type": "string", "description": "设置项名称"}, "value": {"description": "新值"}, "save": {"type": "boolean", "description": "是否立即保存到 project.godot, 默认 true"}}},
		_call_set_project_setting)

	_add_tool("save_all",
		"保存全部打开的场景与项目设置。",
		{"type": "object", "properties": {}},
		_call_save_all)

	_add_tool("reimport",
		"重新导入指定资源文件(触发导入管线重建 .godot/imported 缓存)。资源显示异常/导入配置变更后使用。",
		{"type": "object", "properties": {"path": {"type": "string", "description": "要重新导入的资源 res:// 路径"}}},
		_call_reimport)


## -- 文件操作 --
func _register_file_tools() -> void:
	_add_tool("read_file",
		"读取指定路径的文件内容。支持 res:// 和 user:// 路径。返回文件内容和大小信息。",
		{"type": "object", "properties": {
			"path": {"type": "string", "description": "文件路径(res:// 或 user://)"},
			"encoding": {"type": "string", "description": "编码方式, 默认 utf-8, 可选: utf-8, gbk, gb2312"}
		}, "required": ["path"]},
		_call_read_file)

	_add_tool("write_file",
		"写入内容到指定路径的文件。如果文件不存在会创建, 存在则覆盖。支持创建目录。",
		{"type": "object", "properties": {
			"path": {"type": "string", "description": "文件路径(res:// 或 user://)"},
			"content": {"type": "string", "description": "要写入的内容"},
			"create_dirs": {"type": "boolean", "description": "是否自动创建不存在的目录, 默认 true"}
		}, "required": ["path", "content"]},
		_call_write_file)

	_add_tool("append_file",
		"向指定路径的文件追加内容。如果文件不存在会创建。",
		{"type": "object", "properties": {
			"path": {"type": "string", "description": "文件路径(res:// 或 user://)"},
			"content": {"type": "string", "description": "要追加的内容"}
		}, "required": ["path", "content"]},
		_call_append_file)

	_add_tool("delete_file",
		"删除指定路径的文件或空目录。",
		{"type": "object", "properties": {
			"path": {"type": "string", "description": "文件或目录路径(res:// 或 user://)"}
		}, "required": ["path"]},
		_call_delete_file)

	_add_tool("file_exists",
		"检查指定路径的文件或目录是否存在。",
		{"type": "object", "properties": {
			"path": {"type": "string", "description": "文件或目录路径(res:// 或 user://)"}
		}, "required": ["path"]},
		_call_file_exists)


## ======= MCP 协议处理 =======

func _on_request(method: String, path: String, headers: Dictionary, body: PackedByteArray, stream) -> void:
	# MCP 服务器已关闭时忽略请求（编辑器重启期间）
	if _http == null:
		return
	if method == "OPTIONS":
		_http.send_response(stream, 204, _cors_headers(headers), "")
		return
	if method != "POST":
		_http.send_response(stream, 405, {"Allow": "POST, OPTIONS", "Content-Type": "application/json"}, "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32000,\"message\":\"Method Not Allowed\"},\"id\":null}")
		return
	# 鉴权: 可选 Bearer token(dev_framework/mcp/token, 非空时启用)
	var token: String = ProjectSettings.get_setting(SETTING_TOKEN, "")
	if not token.is_empty():
		var auth := str(headers.get("authorization", ""))
		if auth != "Bearer " + token:
			_http.send_response(stream, 401, _cors_headers(headers), JSON.stringify({"jsonrpc": "2.0", "error": {"code": -32000, "message": "Unauthorized"}, "id": null}))
			return
	# 校验 Origin: 拦截浏览器/外部站点的跨域调用(eval_code 可执行任意代码, 防本机 RCE)。
	# 无 Origin(本地 CLI/工具)或本机 Origin 放行。
	var origin := str(headers.get("origin", "")).to_lower()
	if not origin.is_empty() and not (origin.begins_with("http://127.0.0.1") or origin.begins_with("http://localhost") or origin.begins_with("http://0.0.0.0")):
		_http.send_response(stream, 403, _cors_headers(headers), JSON.stringify({"jsonrpc": "2.0", "error": {"code": -32000, "message": "Forbidden"}, "id": null}))
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if parsed == null or not parsed is Dictionary:
		_http.send_response(stream, 400, {"Content-Type": "application/json"}, "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32700,\"message\":\"Parse error\"},\"id\":null}")
		return
	var req: Dictionary = parsed
	var response := await _handle_jsonrpc(req)
	# JSON-RPC 通知(无 id)按 MCP 规范回 202 空响应
	if response.is_empty():
		_http.send_response(stream, 202, {}, "")
		return
	var json := JSON.stringify(response)
	_http.send_response(stream, 200, _cors_headers(headers), json)


## CORS 响应头
func _cors_headers(headers: Dictionary) -> Dictionary:
	var h := {
		"Content-Type": "application/json",
		"Mcp-Session-Id": _make_session_id(headers),
		"Access-Control-Allow-Methods": "POST, GET, OPTIONS",
		"Access-Control-Allow-Headers": "Authorization, Content-Type, Mcp-Session-Id",
	}
	var origin := str(headers.get("origin", ""))
	if not origin.is_empty():
		h["Access-Control-Allow-Origin"] = origin
	return h


func _make_session_id(headers: Dictionary) -> String:
	return headers.get("mcp-session-id", "dev-framework-default-session")


## 处理一条 JSON-RPC 请求(MCP), 返回响应字典
func _handle_jsonrpc(req: Dictionary) -> Dictionary:
	var req_id: Variant = req.get("id", null)
	if req_id == null:
		return {}

	var method: String = req.get("method", "")
	match method:
		"initialize":
			return {
				"jsonrpc": "2.0",
				"id": req_id,
				"result": {
					"protocolVersion": PROTOCOL_VERSION,
					"capabilities": {"tools": {"listChanged": false}, "logging": {}},
					"serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
				},
			}
		"tools/list":
			return {"jsonrpc": "2.0", "id": req_id, "result": {"tools": _tool_defs}}
		"tools/call":
			var params: Dictionary = req.get("params", {})
			var tool_name: String = params.get("name", "")
			var arguments: Dictionary = params.get("arguments", {})
			LogTool.log("MCP", "工具调用(%s): %s, 参数: %s" % [_mode, tool_name, str(arguments)])
			if not _tool_handlers.has(tool_name):
				return _jsonrpc_error(req_id, -32602, "Unknown tool: %s" % tool_name)
			var tool_result: Dictionary = await _tool_handlers[tool_name].call(arguments)
			return {
				"jsonrpc": "2.0",
				"id": req_id,
				"result": {
					"content": [{"type": "text", "text": tool_result.get("text", "")}],
					"isError": tool_result.get("is_error", false),
				},
			}
		"ping":
			return {"jsonrpc": "2.0", "id": req_id, "result": {}}
		"logging/setLevel":
			return {"jsonrpc": "2.0", "id": req_id, "result": {}}
		_:
			return _jsonrpc_error(req_id, -32601, "Method not found: %s" % method)


func _jsonrpc_error(req_id: Variant, code: int, message: String) -> Dictionary:
	return {"jsonrpc": "2.0", "id": req_id, "error": {"code": code, "message": message}}


## 统一工具结果封装
func _ok(text: String) -> Dictionary:
	return {"text": text, "is_error": false}


func _fail(text: String) -> Dictionary:
	return {"text": text, "is_error": true}


## 辅助函数：将 Variant 转换为 bool（支持 bool、String("true"/"True")、数字等）
func _to_bool(value: Variant) -> bool:
	if value is bool:
		return value
	if value is String:
		return value.to_lower() == "true"
	if value is int or value is float:
		return value != 0
	return false


## ======= 工具 Callable 实现 =======

func _call_validate_script(args: Dictionary) -> Dictionary:
	var path: String = str(args.get("path", ""))
	var code: String = str(args.get("code", ""))
	if path.is_empty() and code.is_empty():
		return _fail("必须提供 path 或 code 之一")
	var script := GDScript.new()
	if not path.is_empty():
		if not ResourceLoader.exists(path):
			return _fail("脚本文件不存在: %s" % path)
		var file := FileAccess.open(path, FileAccess.READ)
		if not file:
			return _fail("无法读取脚本文件: %s" % path)
		code = file.get_as_text()
		file.close()
	script.source_code = code
	var n0: int = _logger.get_error_count() if _logger else 0
	var reload_err := script.reload()
	var new_errs: Array = []
	if _logger:
		var all_entries: Array = _logger.take_errors_since(0).entries
		var added: int = all_entries.size() - n0
		if added > 0:
			new_errs = all_entries.slice(maxi(0, all_entries.size() - added))
	var real_errors: Array = []
	var warnings: Array = []
	for e in new_errs:
		var msg: String = str(e.get("message", ""))
		if msg.contains("Warning treated as error") or msg.contains("variable type is being inferred from a Variant value"):
			warnings.append(msg)
		else:
			real_errors.append(msg)
	if reload_err == OK and real_errors.is_empty():
		return _ok(JSON.stringify({
			"valid": true,
			"message": "脚本语法有效" + ("(含 %d 条可忽略警告)" % warnings.size() if warnings.size() > 0 else ""),
			"error_latin": 0,
			"error_text": "",
			"warnings": warnings,
		}))
	if real_errors.is_empty():
		return _ok(JSON.stringify({
			"valid": true,
			"message": "脚本语法有效(仅存在被当作错误的警告, 编辑器可正常加载)",
			"error_latin": 0,
			"error_text": "",
			"warnings": warnings,
		}))
	var text := "; ".join(real_errors)
	var hint := ""
	if text.contains("hides a global script class"):
		hint = " (class_name 与全局类缓存冲突: 若是新脚本, 先调用 reload_project 刷新类缓存后再试; 若验证的是已被编辑器加载的类脚本(如 addons 内), 属正常冲突)"
	elif text.contains("Warning treated as error") or text.contains("inferred from a Variant"):
		hint = " (存在被当作错误的警告: 可在项目设置 GDScript 警告中放宽, 或为相关变量标注显式类型)"
	var msg := "解析失败: %s%s" % [text, hint]
	return _ok(JSON.stringify({
		"valid": false,
		"message": msg,
		"error_line": 0,
		"error_text": text,
		"hint": hint.strip_edges().trim_prefix(" (").trim_suffix(")"),
		"errors": real_errors,
		"warnings": warnings,
	}))


func _call_validate_resource(args: Dictionary) -> Dictionary:
	var path: String = str(args.get("path", ""))
	if path.is_empty():
		return _fail("必须提供 path")
	if not ResourceLoader.exists(path):
		return _fail("资源不存在: %s" % path)
	var res: Resource = ResourceLoader.load(path)
	if res == null:
		return _fail("资源加载失败: %s" % path)
	return _ok(JSON.stringify({
		"valid": true,
		"type": res.get_class(),
		"message": "资源可正常加载",
	}))


func _call_list_dir(args: Dictionary) -> Dictionary:
	var path: String = str(args.get("path", "res://"))
	var recursive: bool = _to_bool(args.get("recursive", false))
	if not path.ends_with("/"):
		path += "/"
	var dir := DirAccess.open(path)
	if dir == null:
		return _fail("无法打开目录: %s" % path)
	var dirs: Array = []
	var files: Array = []
	if recursive:
		_collect_dir(path, dirs, files)
	else:
		dir.list_dir_begin()
		var f := dir.get_next()
		while not f.is_empty():
			if dir.current_is_dir() and f != "." and f != "..":
				dirs.append(f)
			elif not dir.current_is_dir():
				files.append(f)
			f = dir.get_next()
		dir.list_dir_end()
	return _ok(JSON.stringify({"path": path, "dirs": dirs, "files": files}))


## 递归收集目录内容(供 list_dir 使用)
func _collect_dir(base: String, dirs: Array, files: Array) -> void:
	var d := DirAccess.open(base)
	if d == null:
		return
	d.list_dir_begin()
	var f := d.get_next()
	while not f.is_empty():
		if d.current_is_dir() and f != "." and f != "..":
			dirs.append(base + f + "/")
			_collect_dir(base + f + "/", dirs, files)
		elif not d.current_is_dir():
			files.append(base + f)
		f = d.get_next()
	d.list_dir_end()


func _call_get_logs(args: Dictionary) -> Dictionary:
	if _logger == null:
		return _fail("日志捕获器未就绪")
	var since: int = int(args.get("since", 0))
	var keyword: String = str(args.get("keyword", ""))
	var max: int = int(args.get("max", 200))
	var result: Dictionary = _logger.take_logs_since(since)
	var entries: Array = result.entries
	var out: Array = []
	for e in entries:
		var clean: Dictionary = e.duplicate()
		clean.message = _logger.sanitize(str(e.message))
		if not keyword.is_empty() and keyword not in str(clean.message):
			continue
		out.append(clean)
		if out.size() >= max:
			break
	return _ok(JSON.stringify({"next": result.next, "count": out.size(), "logs": out}))


func _call_get_errors(args: Dictionary) -> Dictionary:
	if _logger == null:
		return _fail("错误捕获器未就绪")
	var max: int = int(args.get("max", 100))
	var since: int = int(args.get("since", 0))
	var result: Dictionary = _logger.take_errors_since(since)
	var out: Array = result.entries.duplicate()
	if out.size() > max:
		out = out.slice(out.size() - max)
	var cleaned: Array = []
	for e in out:
		var clean: Dictionary = e.duplicate()
		if clean.has("message"):
			clean.message = _logger.sanitize(str(clean.message))
		cleaned.append(clean)
	return _ok(JSON.stringify({"count": cleaned.size(), "errors": cleaned, "next": result.next}))


func _call_clear_errors(_args: Dictionary) -> Dictionary:
	if _logger:
		_logger.clear_errors()
	return _ok("已清空错误缓冲区")


func _call_take_screenshot(args: Dictionary) -> Dictionary:
	# 游戏运行画面: 转发到游戏进程运行时服务器原生截图
	var capture_type: String = str(args.get("capture_type", "editor"))
	if capture_type == "game":
		if _mode == MODE_EDITOR:
			return await _call_runtime_proxy("take_screenshot", args)
		# 运行时模式: 直接截游戏画面
		return await _runtime_take_screenshot(args)

	var filename: String = str(args.get("filename", ""))
	if filename.is_empty():
		filename = "mcp_%s" % Time.get_datetime_string_from_system().replace(":", "-").replace(" ", "_")
	# 清理文件名中的非法字符(Windows 不支持 : / \ * ? " < > |)
	filename = filename.replace("/", "_").replace("\\", "_").replace("*", "_").replace("?", "_")\
		.replace("\"", "_").replace("<", "_").replace(">", "_").replace("|", "_")
	if not filename.ends_with(".png"):
		filename += ".png"
	# 保存到 .godot 目录下，不会被 Godot 扫描为资源，也不会被版本控制
	var dir_path := "res://.godot/mcp_screenshots"
	var dir := DirAccess.open("res://")
	if dir:
		dir.make_dir_recursive(".godot/mcp_screenshots")
	var img: Image = null
	match capture_type:
		"scene":
			img = await _capture_scene_thumbnail(args)
			if img == null or img.is_empty():
				return _fail("场景缩略图生成失败: 无法渲染场景或场景为空")
		_:  # "editor"
			img = await _capture_editor_viewport()
			if img == null or img.is_empty():
				return _fail("截图失败: 编辑器视口纹理为空")
	var max_width := int(args.get("max_width", 0))
	if max_width > 0 and max_width < img.get_width():
		var scale := float(max_width) / float(img.get_width())
		img.resize(max_width, int(img.get_height() * scale), Image.INTERPOLATE_LANCZOS)
	var path := "%s/%s" % [dir_path, filename]
	var img_err := img.save_png(path)
	if img_err != OK:
		return _fail("保存截图失败: 错误码 %d" % img_err)
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(path)
	return _ok(JSON.stringify({
		"path": ProjectSettings.globalize_path(path),
		"res_path": path,
		"width": img.get_width(),
		"height": img.get_height(),
		"bytes": bytes.size() if bytes else 0,
		"capture_type": capture_type,
	}))


## 捕获编辑器视口截图
func _capture_editor_viewport() -> Image:
	if not Engine.is_editor_hint():
		return null
	var base: Control = EditorInterface.get_base_control()
	if base == null:
		return null
	var viewport := base.get_viewport()
	var tree := base.get_tree()
	if viewport == null or tree == null:
		return null
	await _wait_frames(tree, 3, 2500)
	RenderingServer.force_draw(false)
	return viewport.get_texture().get_image()


## 生成场景缩略图
func _capture_scene_thumbnail(args: Dictionary) -> Image:
	if not Engine.is_editor_hint():
		return null
	var scene_path: String = str(args.get("scene_path", ""))
	var thumbnail_size: int = int(args.get("thumbnail_size", 256))
	if scene_path.is_empty():
		var root := _edited_root()
		if root == null:
			return null
		scene_path = root.get_scene_file_path()
		if scene_path.is_empty():
			return null
	if not ResourceLoader.exists(scene_path):
		return null
	var scene_res: Resource = ResourceLoader.load(scene_path)
	if not scene_res is PackedScene:
		return null
	var scene_instance: Node = scene_res.instantiate()
	if scene_instance == null:
		return null
	var viewport := SubViewport.new()
	viewport.size = Vector2i(thumbnail_size, thumbnail_size)
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.add_child(scene_instance)
	scene_instance.owner = viewport
	var base: Control = EditorInterface.get_base_control()
	if base == null:
		viewport.queue_free()
		return null
	var tree := base.get_tree()
	if tree == null:
		viewport.queue_free()
		return null
	tree.root.add_child(viewport)
	await _wait_frames(tree, 5, 3000)
	var img: Image = viewport.get_texture().get_image()
	viewport.queue_free()
	return img


## 等待若干帧, 带超时上限(毫秒, 0 表示不限)
func _wait_frames(tree: SceneTree, frames: int, timeout_msec: int) -> void:
	var deadline := Time.get_ticks_msec() + timeout_msec
	for i in frames:
		if timeout_msec > 0 and Time.get_ticks_msec() > deadline:
			break
		await tree.process_frame


func _call_get_scene_tree(args: Dictionary) -> Dictionary:
	var max_depth: int = int(args.get("max_depth", 8))
	var include_props: bool = _to_bool(args.get("include_properties", false))
	var root := _edited_root()
	if root == null:
		return _fail("当前没有打开的场景")
	var lines: Array = []
	_walk_scene_tree(root, 0, max_depth, include_props, lines)
	return _ok("\n".join(lines))


## 递归展开场景树(供 get_scene_tree 使用)
func _walk_scene_tree(node: Node, depth: int, max_depth: int, include_props: bool, lines: Array) -> void:
	if depth > max_depth:
		return
	var indent := "  ".repeat(depth)
	lines.append("%s%s [%s]" % [indent, node.name, node.get_class()])
	if include_props and depth < 3:
		var props := _collect_essential_props(node)
		if not props.is_empty():
			lines.append("%s    props: %s" % [indent, JSON.stringify(props)])
	for child in node.get_children():
		_walk_scene_tree(child, depth + 1, max_depth, include_props, lines)


func _call_get_node_info(args: Dictionary) -> Dictionary:
	var path: String = str(args.get("path", ""))
	var node := _resolve_node(path)
	if node == null:
		return _fail("找不到节点: %s" % path)
	var info := {
		"name": node.name,
		"class": node.get_class(),
		"path": node.get_path(),
		"properties": _collect_essential_props(node),
	}
	return _ok(JSON.stringify(info))


## 提取对 AI 调试最有用的核心属性
func _collect_essential_props(node: Node) -> Dictionary:
	var out := {}
	for p in node.get_property_list():
		var pname: String = str(p.name)
		if pname.begins_with("theme_override") or pname.begins_with("accessibility_") \
				or pname.begins_with("focus_") or pname == "editor_description" or pname == "script":
			continue
		if p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE or pname in CORE_PROP_NAMES:
			var v: Variant = node.get(pname)
			if v != null and not (v is Object or v is Resource):
				out[pname] = v
	return out


func _call_set_node_property(args: Dictionary) -> Dictionary:
	var path: String = str(args.get("path", ""))
	var property: String = str(args.get("property", ""))
	var value: Variant = args.get("value", null)
	var node := _resolve_node(path)
	if node == null:
		return _fail("找不到节点: %s" % path)
	var current: Variant = node.get(property)
	if current == null and not node.has_method(property):
		return _fail("节点 %s 没有属性: %s" % [path, property])
	var typed: Variant = _auto_convert_arg(value)
	if typed is String and current != null:
		typed = _coerce_value(value, typeof(current))
	if typed == null and value != null:
		return _fail("无法转换值 %s 为属性类型" % str(value))
	node.set(property, typed)
	return _ok("已设置 %s.%s = %s" % [path, property, str(node.get(property))])


func _call_call_node_method(args: Dictionary) -> Dictionary:
	var path: String = str(args.get("path", ""))
	var method: String = str(args.get("method", ""))
	var args_arr: Array = args.get("args", [])
	var node := _resolve_node(path)
	if node == null:
		return _fail("找不到节点: %s" % path)
	if not node.has_method(method):
		return _fail("节点 %s 没有方法: %s" % [path, method])
	var converted_args: Array = []
	for arg in args_arr:
		converted_args.append(_auto_convert_arg(arg))
	var result: Variant = node.callv(method, converted_args)
	return _ok("已调用 %s.%s() -> %s" % [path, method, str(result)])


func _call_add_node(args: Dictionary) -> Dictionary:
	var parent_path := str(args.get("parent", ""))
	var node_type := str(args.get("node_type", ""))
	var new_name := str(args.get("name", ""))
	var root := _edited_root()
	if root == null:
		return _fail("当前没有打开的场景")
	var parent := root
	if not parent_path.is_empty():
		parent = _resolve_node(parent_path)
		if parent == null:
			return _fail("找不到父节点: %s" % parent_path)
	var new_node: Node
	if node_type.begins_with("res://"):
		if not ResourceLoader.exists(node_type):
			return _fail("子场景不存在: %s" % node_type)
		var packed: PackedScene = ResourceLoader.load(node_type)
		if packed == null:
			return _fail("子场景加载失败: %s" % node_type)
		new_node = packed.instantiate()
	else:
		if not ClassDB.class_exists(node_type):
			return _fail("未知节点类型: %s" % node_type)
		new_node = ClassDB.instantiate(node_type)
		if new_node == null:
			return _fail("无法实例化节点类型: %s" % node_type)
	if not new_name.is_empty():
		new_node.name = new_name
	parent.add_child(new_node, true)
	_assign_owner_recursive(new_node, root)
	return _ok("已添加节点 %s [%s] 到 %s" % [new_node.name, new_node.get_class(), parent.name])


## 递归把节点及其子树 owner 设为场景根, 保证新增节点可随场景保存
func _assign_owner_recursive(node: Node, root: Node) -> void:
	node.owner = root
	for child in node.get_children():
		_assign_owner_recursive(child, root)


func _call_save_scene(_args: Dictionary) -> Dictionary:
	if not Engine.is_editor_hint():
		return _fail("仅在编辑器模式可用")
	var root := _edited_root()
	if root == null:
		return _fail("当前没有打开的场景")
	var err := EditorInterface.save_scene()
	if err != OK:
		return _fail("保存场景失败(错误码 %d)" % err)
	return _ok("已保存场景 %s" % root.get_scene_file_path())


func _call_get_project_info(_args: Dictionary) -> Dictionary:
	var info := {
		"project_name": ProjectSettings.get_setting("application/config/name", ""),
		"godot_version": Engine.get_version_info(),
		"editor": Engine.is_editor_hint(),
		"debug_build": OS.is_debug_build(),
		"current_scene": _edited_root().get_scene_file_path() if _edited_root() else null,
		"mode": _mode,
		"mcp_port": _port,
		"mcp_running": is_running(),
		"game_running": _run_pid != 0,
	}
	return _ok(JSON.stringify(info))


func _call_get_project_settings(_args: Dictionary) -> Dictionary:
	var root := _edited_root()
	var info := {
		"main_scene": ProjectSettings.get_setting("application/run/main_scene", ""),
		"project_name": ProjectSettings.get_setting("application/config/name", ""),
		"autoloads": _autoloads(),
		"input_actions": _input_actions(),
		"layers_2d": _named_layers("layer_names/2d_physics"),
		"layers_2d_render": _named_layers("layer_names/2d_render"),
		"layers_3d": _named_layers("layer_names/3d_physics"),
		"layers_3d_render": _named_layers("layer_names/3d_render"),
		"current_scene": root.get_scene_file_path() if root else null,
	}
	return _ok(JSON.stringify(info))


## 收集 autoload 单例(名字 -> 路径)
func _autoloads() -> Dictionary:
	var out := {}
	for key in ProjectSettings.get_property_list():
		var name: String = str(key.get("name", ""))
		if name.begins_with("autoload/") and name.count("/") == 1:
			var keyname := name.trim_prefix("autoload/")
			var val = ProjectSettings.get_setting(name)
			if val is String and not (val.begins_with("*") or val.begins_with("&")):
				out[keyname] = val
	return out


## 收集输入映射动作名
func _input_actions() -> Array:
	var out := []
	for key in ProjectSettings.get_property_list():
		var name: String = str(key.get("name", ""))
		if name.begins_with("input/"):
			out.append(name.trim_prefix("input/"))
	return out


## 读取图层命名
func _named_layers(setting_key: String) -> Dictionary:
	var out := {}
	for key in ProjectSettings.get_property_list():
		var name: String = str(key.get("name", ""))
		if name.begins_with(setting_key + "/"):
			var idx := name.trim_prefix(setting_key + "/")
			out[int(idx)] = ProjectSettings.get_setting(name)
	return out


func _call_run_game(args: Dictionary) -> Dictionary:
	if not Engine.is_editor_hint():
		return _fail("仅在编辑器模式可运行游戏")
	if _run_pid != 0:
		return _fail("游戏已在运行(pid=%d)。如需重启请先 stop_game。" % _run_pid)
	var scene := str(args.get("scene", ""))
	if scene.is_empty():
		return _fail("必须提供 scene(要运行的场景 res:// 路径), 例如 res://Scenes/Main/Main.tscn")
	if not scene.begins_with("res://"):
		scene = "res://" + scene
	if not ResourceLoader.exists(scene):
		return _fail("启动场景不存在: %s" % scene)
	var scene_res: Resource = ResourceLoader.load(scene)
	if not scene_res is PackedScene:
		return _fail("不是有效场景文件: %s(类型: %s)" % [scene, scene_res.get_class() if scene_res else "null"])
	var exe := OS.get_executable_path()
	# 关键: 传入 --mcp-runtime-port, 游戏进程内的 autoload 会开启运行时服务器
	var args_arr := PackedStringArray([
		"--path", ProjectSettings.globalize_path("res://"),
		scene,
		"--mcp-runtime-port", str(_runtime_port),
	])
	_run_pid = OS.create_process(exe, args_arr)
	if _run_pid == 0:
		return _fail("启动游戏进程失败(OS.create_process 返回 0)。可检查路径: %s" % exe)
	return _ok("已启动游戏(独立进程, pid=%d) 场景=%s。运行时服务器端口=%d, 已可用运行时工具: get_game_view / simulate_click / simulate_drag / simulate_key / take_screenshot(game) / game_eval / get_game_logs。" % [_run_pid, scene, _runtime_port])


func _call_stop_game(_args: Dictionary) -> Dictionary:
	if _run_pid == 0:
		return _fail("当前没有运行中的游戏")
	if OS.is_process_running(_run_pid):
		OS.kill(_run_pid)
	_run_pid = 0
	return _ok("已停止游戏")


## ======= 开发辅助工具实现 =======

func _call_reload_project(args: Dictionary) -> Dictionary:
	if not Engine.is_editor_hint():
		return _fail("仅在编辑器模式可用")
	var reopen: bool = _to_bool(args.get("reopen_scene", false))
	var fs := EditorInterface.get_resource_filesystem()
	if fs == null:
		return _fail("编辑器文件系统不可用")
	var current := ""
	if _edited_root() != null:
		current = _edited_root().get_scene_file_path()
	fs.scan_sources()
	fs.scan()
	var msg := "已触发项目重载: scan_sources(重建类缓存) + scan(重扫资源)。扫描将在后台进行, 新资源可能需要片刻才能生效。"
	if reopen and not current.is_empty():
		var tree := EditorInterface.get_base_control().get_tree()
		if tree:
			await tree.create_timer(1.0).timeout
		EditorInterface.open_scene_from_path(current)
		msg += " 已重载当前场景 %s。注意: 未保存修改可能已丢失。" % current
	elif reopen and current.is_empty():
		msg += " 提示: 当前没有打开的场景, 未执行场景重载。"
	return _ok(msg)


func _call_eval_code(args: Dictionary) -> Dictionary:
	var code: String = str(args.get("code", ""))
	if code.is_empty():
		return _fail("必须提供 code")
	var script := GDScript.new()
	var body := _indent_method_body(code)
	# 包装为挂到场景树的 Node 方法, 让用户代码可直接 get_tree()/get_node() 访问当前场景
	script.source_code = "extends Node\nfunc _mcp_run():\n%s" % body
	var err := script.reload()
	if err != OK:
		var text := error_string(err)
		var hint := ""
		if text.contains("hides a global script class"):
			hint = " (class_name 与全局类冲突: 请勿在 eval_code 中声明类, 或先 reload_project)"
		return _fail("代码解析失败: %s%s\n解析详情已输出到编辑器控制台, 可用 get_logs 查看。" % [text, hint])
	var inst: Node = script.new()
	if inst == null:
		return _fail("无法实例化求值脚本")
	var root := get_tree().root
	if root:
		root.add_child(inst)
	var result: Variant = inst.call("_mcp_run")
	if root:
		inst.queue_free()
	var shown := str(result)
	if result is Dictionary or result is Array:
		shown = JSON.stringify(result)
	return _ok("执行成功, 返回: %s" % shown)


## 把用户 eval_code 规范成方法体缩进
func _indent_method_body(code: String) -> String:
	var lines := code.split("\n")
	var out := PackedStringArray()
	for line in lines:
		var norm := _normalize_indent(line, 4)
		out.append("    " + norm)
	return "\n".join(out)


func _normalize_indent(line: String, tab_w: int) -> String:
	var i := 0
	var spaces := 0
	while i < line.length():
		var c := line.unicode_at(i)
		if c == 9:
			spaces += tab_w
			i += 1
		elif c == 32:
			spaces += 1
			i += 1
		else:
			break
	var prefix := ""
	for j in spaces:
		prefix += " "
	return prefix + line.substr(i)


func _call_get_global_classes(_args: Dictionary) -> Dictionary:
	var list := ProjectSettings.get_global_class_list()
	var out: Array = []
	for c in list:
		out.append({
			"name": c.get("name", ""),
			"path": c.get("path", ""),
			"base": c.get("base", ""),
			"class": c.get("class", ""),
		})
	return _ok(JSON.stringify({"count": out.size(), "classes": out}))


func _call_open_scene(args: Dictionary) -> Dictionary:
	if not Engine.is_editor_hint():
		return _fail("仅在编辑器模式可用")
	var path := str(args.get("path", ""))
	if path.is_empty() or not ResourceLoader.exists(path):
		return _fail("场景不存在: %s" % path)
	EditorInterface.open_scene_from_path(path)
	return _ok("已打开场景 %s" % path)


func _call_set_main_scene(args: Dictionary) -> Dictionary:
	var path := str(args.get("path", ""))
	if path.is_empty():
		return _fail("必须提供 path")
	if not ResourceLoader.exists(path):
		return _fail("场景不存在: %s" % path)
	ProjectSettings.set_setting("application/run/main_scene", path)
	ProjectSettings.save()
	return _ok("已设置主场景: %s" % path)


func _call_get_project_setting(args: Dictionary) -> Dictionary:
	var name := str(args.get("name", ""))
	if name.is_empty():
		return _fail("必须提供 name")
	if not ProjectSettings.has_setting(name):
		return _fail("不存在设置项: %s" % name)
	return _ok(JSON.stringify({"name": name, "value": ProjectSettings.get_setting(name)}))


func _call_set_project_setting(args: Dictionary) -> Dictionary:
	var name := str(args.get("name", ""))
	if name.is_empty():
		return _fail("必须提供 name")
	var value: Variant = args.get("value", null)
	ProjectSettings.set_setting(name, value)
	if _to_bool(args.get("save", true)):
		ProjectSettings.save()
	return _ok("已设置 %s = %s" % [name, str(value)])


func _call_save_all(_args: Dictionary) -> Dictionary:
	if Engine.is_editor_hint():
		EditorInterface.save_all_scenes()
	var ps := ProjectSettings.save()
	return _ok("已保存全部场景, 项目设置(err=%d)" % ps)


func _call_reimport(args: Dictionary) -> Dictionary:
	var path := str(args.get("path", ""))
	if path.is_empty() or not ResourceLoader.exists(path):
		return _fail("资源不存在: %s" % path)
	if not Engine.is_editor_hint():
		return _fail("仅在编辑器模式可用")
	var fs := EditorInterface.get_resource_filesystem()
	if fs == null:
		return _fail("编辑器文件系统不可用")
	fs.reimport_files([path])
	return _ok("已触发重新导入: %s" % path)


## ======= 文件操作实现 =======

func _call_read_file(args: Dictionary) -> Dictionary:
	var path: String = str(args.get("path", ""))
	var encoding: String = str(args.get("encoding", "utf-8"))
	if path.is_empty():
		return _fail("必须提供 path")
	if not FileAccess.file_exists(path):
		return _fail("文件不存在: %s" % path)
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _fail("无法打开文件: %s (错误码: %d)" % [path, FileAccess.get_open_error()])
	var content: String
	if encoding.to_lower() == "gbk" or encoding.to_lower() == "gb2312":
		var bytes := file.get_buffer(file.get_length())
		content = bytes.get_string_from_utf8()
	else:
		content = file.get_as_text()
	var size := file.get_length()
	file.close()
	return _ok(JSON.stringify({
		"path": path,
		"size": size,
		"encoding": encoding,
		"content": content
	}))


func _call_write_file(args: Dictionary) -> Dictionary:
	var path: String = str(args.get("path", ""))
	var content: String = str(args.get("content", ""))
	var create_dirs: bool = _to_bool(args.get("create_dirs", true))
	if path.is_empty():
		return _fail("必须提供 path")
	if create_dirs:
		var dir_path := path.get_base_dir()
		if not dir_path.is_empty():
			var dir := DirAccess.open(dir_path)
			if dir == null:
				var err := DirAccess.make_dir_recursive_absolute(dir_path)
				if err != OK:
					return _fail("无法创建目录: %s (错误码: %d)" % [dir_path, err])
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return _fail("无法写入文件: %s (错误码: %d)" % [path, FileAccess.get_open_error()])
	file.store_string(content)
	var size := file.get_length()
	file.close()
	return _ok(JSON.stringify({
		"path": path,
		"size": size,
		"message": "文件写入成功"
	}))


func _call_append_file(args: Dictionary) -> Dictionary:
	var path: String = str(args.get("path", ""))
	var content: String = str(args.get("content", ""))
	if path.is_empty():
		return _fail("必须提供 path")
	if not FileAccess.file_exists(path):
		return _call_write_file(args)
	var file := FileAccess.open(path, FileAccess.READ_WRITE)
	if file == null:
		return _fail("无法打开文件: %s (错误码: %d)" % [path, FileAccess.get_open_error()])
	file.seek_end()
	file.store_string(content)
	var new_size := file.get_length()
	file.close()
	return _ok(JSON.stringify({
		"path": path,
		"size": new_size,
		"message": "内容追加成功"
	}))


func _call_delete_file(args: Dictionary) -> Dictionary:
	var path: String = str(args.get("path", ""))
	if path.is_empty():
		return _fail("必须提供 path")
	if not FileAccess.file_exists(path):
		var dir := DirAccess.open(path)
		if dir == null:
			return _fail("文件或目录不存在: %s" % path)
		var err := DirAccess.remove_absolute(path)
		if err != OK:
			return _fail("无法删除目录: %s (错误码: %d)。注意: 只能删除空目录" % [path, err])
		return _ok(JSON.stringify({"path": path, "message": "目录删除成功"}))
	var err := DirAccess.remove_absolute(path)
	if err != OK:
		return _fail("无法删除文件: %s (错误码: %d)" % [path, err])
	return _ok(JSON.stringify({"path": path, "message": "文件删除成功"}))


func _call_file_exists(args: Dictionary) -> Dictionary:
	var path: String = str(args.get("path", ""))
	if path.is_empty():
		return _fail("必须提供 path")
	var exists := FileAccess.file_exists(path)
	var is_dir := false
	if not exists:
		var dir := DirAccess.open(path)
		is_dir = dir != null
	return _ok(JSON.stringify({
		"path": path,
		"exists": exists or is_dir,
		"is_directory": is_dir,
		"message": "文件存在" if exists else ("目录存在" if is_dir else "文件不存在")
	}))


## ======= 辅助 =======

## 当前正在编辑的场景根节点(编辑器模式)或运行中场景(运行时模式)
func _edited_root() -> Node:
	if Engine.is_editor_hint():
		return EditorInterface.get_edited_scene_root()
	var tree := get_tree()
	return tree.current_scene if tree else null


## 在场景内解析节点(名称/相对路径/绝对路径)
func _resolve_node(path: String) -> Node:
	var root := _edited_root()
	if root == null:
		return null
	if path == "root" or path == "/":
		return root
	if path.begins_with("@"):
		return root.find_child(path.substr(1), true, false)
	if path.begins_with("/"):
		var rel := path.trim_prefix("/")
		return root.get_node_or_null(rel)
	var n := root.get_node_or_null(path)
	if n:
		return n
	return root.find_child(path, true, false)


## 自动推断并转换参数类型(无需知道目标类型)
## 支持: Vector2/Vector2i/Vector3/Vector3i/Color/Rect2/数字/布尔等
func _auto_convert_arg(value: Variant) -> Variant:
	if not value is String:
		return value
	var s: String = value
	# 检测 Vector2 格式: "x,y" 或 "(x, y)"
	if s.count(",") == 1 and not s.contains("Color") and not s.contains("Rect"):
		var parts := s.replace("(", "").replace(")", "").split(",")
		if parts.size() == 2:
			var x := parts[0].strip_edges()
			var y := parts[1].strip_edges()
			if _is_numeric(x) and _is_numeric(y):
				return Vector2(float(x), float(y))
	# 检测 Vector2i 格式
	if s.count(",") == 1 and s.contains("i"):
		var parts := s.replace("(", "").replace(")", "").replace("i", "").split(",")
		if parts.size() == 2:
			var x := parts[0].strip_edges()
			var y := parts[1].strip_edges()
			if _is_numeric(x) and _is_numeric(y):
				return Vector2i(int(x), int(y))
	# 检测 Vector3 格式: "x,y,z"
	if s.count(",") == 2:
		var parts := s.replace("(", "").replace(")", "").split(",")
		if parts.size() == 3:
			var x := parts[0].strip_edges()
			var y := parts[1].strip_edges()
			var z := parts[2].strip_edges()
			if _is_numeric(x) and _is_numeric(y) and _is_numeric(z):
				return Vector3(float(x), float(y), float(z))
	# 检测 Color 格式: "r,g,b" 或 "r,g,b,a"
	if s.count(",") >= 2 and s.count(",") <= 3:
		var parts := s.replace("(", "").replace(")", "").split(",")
		if parts.size() >= 3 and parts.size() <= 4:
			var all_numeric := true
			for p in parts:
				if not _is_numeric(p.strip_edges()):
					all_numeric = false
					break
			if all_numeric:
				var r := float(parts[0].strip_edges())
				var g := float(parts[1].strip_edges())
				var b := float(parts[2].strip_edges())
				var a := float(parts[3].strip_edges()) if parts.size() == 4 else 1.0
				return Color(r, g, b, a)
	# 检测 Rect2 格式: "x,y,w,h"
	if s.count(",") == 3:
		var parts := s.replace("(", "").replace(")", "").split(",")
		if parts.size() == 4:
			var all_numeric := true
			for p in parts:
				if not _is_numeric(p.strip_edges()):
					all_numeric = false
					break
			if all_numeric:
				return Rect2(float(parts[0].strip_edges()), float(parts[1].strip_edges()),
					float(parts[2].strip_edges()), float(parts[3].strip_edges()))
	# 检测纯数字
	if _is_numeric(s):
		if s.contains("."):
			return float(s)
		else:
			return int(s)
	# 检测布尔值
	if s == "true":
		return true
	elif s == "false":
		return false
	# 检测 null
	if s == "null" or s == "nil":
		return null
	return value


## 检查字符串是否为有效数字
func _is_numeric(s: String) -> bool:
	if s.is_empty():
		return false
	var i := 0
	if s[0] == "-" or s[0] == "+":
		i = 1
	var has_dot := false
	while i < s.length():
		var c := s[i]
		if c == ".":
			if has_dot:
				return false
			has_dot = true
		else:
			var code := c.unicode_at(0)
			if code < 48 or code > 57:  # '0'-'9'
				return false
		i += 1
	return true


## 将传入值转换为目标类型(处理 Vector2/Vector3/Color 等字符串)
func _coerce_value(value: Variant, target_type: int) -> Variant:
	if value is String:
		var s: String = value
		match target_type:
			TYPE_VECTOR2:
				if s.count(",") == 1:
					var parts := s.split(",")
					return Vector2(float(parts[0]), float(parts[1]))
			TYPE_VECTOR2I:
				if s.count(",") == 1:
					var parts := s.split(",")
					return Vector2i(int(parts[0]), int(parts[1]))
			TYPE_VECTOR3:
				if s.count(",") == 2:
					var parts := s.split(",")
					return Vector3(float(parts[0]), float(parts[1]), float(parts[2]))
			TYPE_VECTOR3I:
				if s.count(",") == 2:
					var parts := s.split(",")
					return Vector3i(int(parts[0]), int(parts[1]), int(parts[2]))
			TYPE_VECTOR4:
				if s.count(",") == 3:
					var parts := s.split(",")
					return Vector4(float(parts[0]), float(parts[1]), float(parts[2]), float(parts[3]))
			TYPE_VECTOR4I:
				if s.count(",") == 3:
					var parts := s.split(",")
					return Vector4i(int(parts[0]), int(parts[1]), int(parts[2]), int(parts[3]))
			TYPE_COLOR:
				if s.count(",") >= 2:
					var parts := s.split(",")
					if parts.size() == 3:
						return Color(float(parts[0]), float(parts[1]), float(parts[2]), 1.0)
					elif parts.size() >= 4:
						return Color(float(parts[0]), float(parts[1]), float(parts[2]), float(parts[3]))
			TYPE_RECT2:
				if s.count(",") == 3:
					var parts := s.split(",")
					return Rect2(float(parts[0]), float(parts[1]), float(parts[2]), float(parts[3]))
			TYPE_RECT2I:
				if s.count(",") == 3:
					var parts := s.split(",")
					return Rect2i(int(parts[0]), int(parts[1]), int(parts[2]), int(parts[3]))
			TYPE_PLANE:
				if s.count(",") == 3:
					var parts := s.split(",")
					return Plane(float(parts[0]), float(parts[1]), float(parts[2]), float(parts[3]))
			TYPE_QUATERNION:
				if s.count(",") == 3:
					var parts := s.split(",")
					return Quaternion(float(parts[0]), float(parts[1]), float(parts[2]), float(parts[3]))
			TYPE_AABB:
				if s.count(",") == 5:
					var parts := s.split(",")
					return AABB(Vector3(float(parts[0]), float(parts[1]), float(parts[2])),
					           Vector3(float(parts[3]), float(parts[4]), float(parts[5])))
			TYPE_INT:
				return int(s)
			TYPE_FLOAT:
				return float(s)
			TYPE_BOOL:
				return s == "true"
	return value


## ======= 运行时工具(游戏进程内原生执行) =======

func _register_runtime_tools() -> void:
	_tool_handlers.clear()
	_tool_defs.clear()
	_add_tool("get_game_view",
		"分析游戏运行时场景中所有可见节点的屏幕位置和大小信息。用于AI理解游戏画面布局以决定点击/拖拽目标。返回每个节点的名称、类型、屏幕坐标、尺寸、层级(z_index)、可见性及文本信息。",
		{"type": "object", "properties": {
			"max_nodes": {"type": "integer", "description": "最多返回节点数, 默认 50"},
			"include_hidden": {"type": "boolean", "description": "是否包含不可见节点, 默认 false"},
			"filter_type": {"type": "string", "description": "过滤节点类型, 如 'Button', 'Label', 'Sprite2D'"}
		}},
		_call_get_game_view)

	_add_tool("simulate_click",
		"在游戏窗口内模拟一次鼠标点击(按下+释放)。坐标为游戏视口坐标。用于AI自动化测试游戏交互(按钮/UI 点击等)。",
		{"type": "object", "properties": {
			"x": {"type": "integer", "description": "屏幕X坐标"},
			"y": {"type": "integer", "description": "屏幕Y坐标"},
			"button": {"type": "string", "description": "鼠标按钮: 'left'(左键), 'right'(右键), 'middle'(中键), 默认 'left'"},
			"double_click": {"type": "boolean", "description": "是否双击, 默认 false"}
		}, "required": ["x", "y"]},
		_call_simulate_click)

	_add_tool("simulate_drag",
		"在游戏窗口内模拟从起始位置拖拽到目标位置(按下->移动->释放)。用于AI测试拖拽交互。",
		{"type": "object", "properties": {
			"from_x": {"type": "integer", "description": "起始X坐标"},
			"from_y": {"type": "integer", "description": "起始Y坐标"},
			"to_x": {"type": "integer", "description": "目标X坐标"},
			"to_y": {"type": "integer", "description": "目标Y坐标"},
			"duration": {"type": "number", "description": "拖拽持续时间(秒), 默认 0.5"}
		}, "required": ["from_x", "from_y", "to_x", "to_y"]},
		_call_simulate_drag)

	_add_tool("simulate_key",
		"在游戏窗口内模拟一次键盘按键(按下/释放)。用于AI测试键盘交互。",
		{"type": "object", "properties": {
			"key": {"type": "string", "description": "按键名称, 如 'space', 'enter', 'escape', 'a'-'z', '0'-'9'"},
			"pressed": {"type": "boolean", "description": "true=按下, false=释放, 默认 true"},
			"shift": {"type": "boolean", "description": "是否按住Shift, 默认 false"},
			"ctrl": {"type": "boolean", "description": "是否按住Ctrl, 默认 false"}
		}, "required": ["key"]},
		_call_simulate_key)

	_add_tool("take_screenshot",
		"捕获游戏运行视口的截图并保存到本地(user://mcp_screenshots/)。返回截图文件路径、像素尺寸与占用字节。AI 可通过文件路径读取分析画面。可选 max_width 限制最大宽度以降采样。",
		{"type": "object", "properties": {
			"filename": {"type": "string", "description": "截图文件名(不含路径), 默认自动按时间命名"},
			"max_width": {"type": "integer", "description": "可选: 若截图宽度超过该值则等比缩小以便 AI 读图(默认不缩放)"}
		}},
		_call_take_screenshot)

	_add_tool("game_eval",
		"在游戏进程中执行一段 GDScript 代码, 可访问当前游戏场景树(get_tree()/get_node()/get_viewport() 等)。常用于读取游戏运行状态/修改变量/触发逻辑。代码中可显式 return 返回值。",
		{"type": "object", "properties": {"code": {"type": "string", "description": "要执行的 GDScript 代码(方法体内容, 缩进由服务器自动处理)"}}},
		_call_eval_code)

	_add_tool("get_game_logs",
		"获取游戏进程的日志(print/printerr 输出)。支持 since 索引增量获取、按关键字过滤、截断数量。",
		{"type": "object", "properties": {"since": {"type": "integer", "description": "增量索引"}, "keyword": {"type": "string", "description": "关键字过滤"}, "max": {"type": "integer", "description": "最多条数, 默认 200"}}},
		_call_get_logs)

	_add_tool("get_game_errors",
		"获取游戏进程捕获的错误(脚本错误/assert/push_error 等), 含来源文件、行号、类型及 GDScript 栈追踪。",
		{"type": "object", "properties": {"since": {"type": "integer", "description": "增量索引"}, "max": {"type": "integer", "description": "最多条数, 默认 100"}}},
		_call_get_errors)

	_add_tool("clear_game_errors",
		"清空游戏进程的错误缓冲区。",
		{"type": "object", "properties": {}},
		_call_clear_errors)


## 运行时: 分析游戏场景中可见节点的屏幕位置
func _call_get_game_view(args: Dictionary) -> Dictionary:
	var max_nodes: int = int(args.get("max_nodes", 50))
	var include_hidden: bool = _to_bool(args.get("include_hidden", false))
	var filter_type: String = str(args.get("filter_type", ""))
	var root := get_tree().current_scene
	if root == null:
		return _fail("当前没有运行中的场景")
	var viewport := get_viewport()
	var viewport_size := viewport.get_visible_rect().size
	var nodes_info: Array = []
	_collect_visible_nodes(root, viewport, nodes_info, max_nodes, include_hidden, filter_type, 0)
	return _ok(JSON.stringify({
		"viewport_size": {"x": int(viewport_size.x), "y": int(viewport_size.y)},
		"node_count": nodes_info.size(),
		"nodes": nodes_info
	}))


## 递归收集可见节点信息(运行时模式, 游戏进程内坐标天然正确)
func _collect_visible_nodes(node: Node, viewport: Viewport, result: Array, max_nodes: int, include_hidden: bool, filter_type: String, depth: int) -> void:
	if result.size() >= max_nodes:
		return
	if depth > 10:
		return
	var is_visible := true
	if node is CanvasItem:
		var canvas_item := node as CanvasItem
		if not include_hidden and not canvas_item.visible:
			return
		is_visible = canvas_item.visible
	if node.name != "" and not str(node.name).begins_with("@"):
		var screen_pos := Vector2.ZERO
		var screen_size := Vector2.ZERO
		var z_index := 0
		if node is CanvasItem:
			var canvas_item := node as CanvasItem
			if node is Control:
				var control := node as Control
				screen_pos = canvas_item.get_global_transform_with_canvas() * control.position
				screen_size = control.size
			elif node is Node2D:
				var node2d := node as Node2D
				screen_pos = canvas_item.get_global_transform_with_canvas() * node2d.position
				if node is Sprite2D:
					var sprite := node as Sprite2D
					if sprite.texture:
						screen_size = Vector2(sprite.texture.get_width(), sprite.texture.get_height())
				elif node is Polygon2D:
					var polygon := node as Polygon2D
					if polygon.polygon.size() > 0:
						var rect := Rect2(polygon.polygon[0], Vector2.ZERO)
						for p in polygon.polygon:
							rect = rect.expand(p)
						screen_size = rect.size
			z_index = canvas_item.z_index if canvas_item is Node2D else 0
		var class_name_str := node.get_class()
		var script_class_str: String = ""
		if node.get_script() != null:
			script_class_str = str(node.get_script_class())
		if filter_type.is_empty() or class_name_str.containsn(filter_type) or script_class_str.containsn(filter_type):
			var info := {
				"name": str(node.name),
				"class": class_name_str,
				"script_class": script_class_str,
				"screen_position": {"x": int(screen_pos.x), "y": int(screen_pos.y)},
				"screen_size": {"x": int(screen_size.x), "y": int(screen_size.y)},
				"z_index": z_index,
				"visible": is_visible
			}
			if node is Button:
				info["text"] = (node as Button).text
				info["disabled"] = (node as Button).disabled
			elif node is Label:
				info["text"] = (node as Label).text
			elif node is Sprite2D:
				var sprite := node as Sprite2D
				if sprite.texture:
					info["texture_size"] = {"x": sprite.texture.get_width(), "y": sprite.texture.get_height()}
			elif node is Control:
				var control := node as Control
				info["rect"] = {"x": int(control.position.x), "y": int(control.position.y), "w": int(control.size.x), "h": int(control.size.y)}
			elif node is Polygon2D:
				var polygon := node as Polygon2D
				info["polygon_count"] = polygon.polygon.size()
			result.append(info)
	for child in node.get_children():
		_collect_visible_nodes(child, viewport, result, max_nodes, include_hidden, filter_type, depth + 1)


## 运行时: 模拟鼠标点击(游戏进程内 Input.parse_input_event 直接生效)
func _call_simulate_click(args: Dictionary) -> Dictionary:
	var x: int = int(args.get("x", 0))
	var y: int = int(args.get("y", 0))
	var button_str: String = str(args.get("button", "left")).to_lower()
	var double_click: bool = _to_bool(args.get("double_click", false))
	var button_index: MouseButton
	match button_str:
		"left":
			button_index = MOUSE_BUTTON_LEFT
		"right":
			button_index = MOUSE_BUTTON_RIGHT
		"middle":
			button_index = MOUSE_BUTTON_MIDDLE
		_:
			return _fail("未知的鼠标按钮: %s" % button_str)
	var down_event := InputEventMouseButton.new()
	down_event.button_index = button_index
	down_event.pressed = true
	down_event.position = Vector2(x, y)
	down_event.global_position = Vector2(x, y)
	down_event.double_click = double_click
	Input.parse_input_event(down_event)
	var up_event := InputEventMouseButton.new()
	up_event.button_index = button_index
	up_event.pressed = false
	up_event.position = Vector2(x, y)
	up_event.global_position = Vector2(x, y)
	Input.parse_input_event(up_event)
	return _ok(JSON.stringify({
		"position": {"x": x, "y": y},
		"button": button_str,
		"double_click": double_click,
		"message": "点击事件已发送"
	}))


## 运行时: 模拟鼠标拖拽
func _call_simulate_drag(args: Dictionary) -> Dictionary:
	var from_x: int = int(args.get("from_x", 0))
	var from_y: int = int(args.get("from_y", 0))
	var to_x: int = int(args.get("to_x", 0))
	var to_y: int = int(args.get("to_y", 0))
	var duration: float = float(args.get("duration", 0.5))
	var down_event := InputEventMouseButton.new()
	down_event.button_index = MOUSE_BUTTON_LEFT
	down_event.pressed = true
	down_event.position = Vector2(from_x, from_y)
	down_event.global_position = Vector2(from_x, from_y)
	Input.parse_input_event(down_event)
	var steps_calc: int = int(duration * 60)
	var steps: int = 10 if steps_calc < 10 else steps_calc
	var step_duration: float = duration / float(steps)
	for i in range(steps + 1):
		var t := float(i) / float(steps)
		var current_x := lerpf(float(from_x), float(to_x), t)
		var current_y := lerpf(float(from_y), float(to_y), t)
		var move_event := InputEventMouseMotion.new()
		move_event.position = Vector2(current_x, current_y)
		move_event.global_position = Vector2(current_x, current_y)
		move_event.relative = Vector2(current_x - from_x, current_y - from_y) if i > 0 else Vector2.ZERO
		move_event.button_mask = MOUSE_BUTTON_MASK_LEFT
		Input.parse_input_event(move_event)
		if i < steps:
			await get_tree().create_timer(step_duration).timeout
	var up_event := InputEventMouseButton.new()
	up_event.button_index = MOUSE_BUTTON_LEFT
	up_event.pressed = false
	up_event.position = Vector2(to_x, to_y)
	up_event.global_position = Vector2(to_x, to_y)
	Input.parse_input_event(up_event)
	return _ok(JSON.stringify({
		"from": {"x": from_x, "y": from_y},
		"to": {"x": to_x, "y": to_y},
		"duration": duration,
		"message": "拖拽事件已发送"
	}))


## 运行时: 模拟键盘按键
func _call_simulate_key(args: Dictionary) -> Dictionary:
	var key_str: String = str(args.get("key", "")).to_lower()
	var pressed: bool = _to_bool(args.get("pressed", true))
	var shift: bool = _to_bool(args.get("shift", false))
	var ctrl: bool = _to_bool(args.get("ctrl", false))
	var key_code: Key
	match key_str:
		"space": key_code = KEY_SPACE
		"enter": key_code = KEY_ENTER
		"escape": key_code = KEY_ESCAPE
		"tab": key_code = KEY_TAB
		"backspace": key_code = KEY_BACKSPACE
		"delete": key_code = KEY_DELETE
		"up": key_code = KEY_UP
		"down": key_code = KEY_DOWN
		"left": key_code = KEY_LEFT
		"right": key_code = KEY_RIGHT
		"shift": key_code = KEY_SHIFT
		"ctrl": key_code = KEY_CTRL
		"alt": key_code = KEY_ALT
		_:
			if key_str.length() == 1:
				key_code = key_str.to_upper().unicode_at(0)
			else:
				return _fail("未知的按键: %s" % key_str)
	var event := InputEventKey.new()
	event.keycode = key_code
	event.pressed = pressed
	event.shift_pressed = shift
	event.ctrl_pressed = ctrl
	Input.parse_input_event(event)
	return _ok(JSON.stringify({
		"key": key_str,
		"pressed": pressed,
		"shift": shift,
		"ctrl": ctrl,
		"message": "按键事件已发送"
	}))


## 运行时: 捕获游戏视口截图
func _runtime_take_screenshot(args: Dictionary) -> Dictionary:
	var filename: String = str(args.get("filename", ""))
	if filename.is_empty():
		filename = "mcp_%s" % Time.get_datetime_string_from_system().replace(":", "-").replace(" ", "_")
	filename = filename.replace("/", "_").replace("\\", "_").replace("*", "_").replace("?", "_")\
		.replace("\"", "_").replace("<", "_").replace(">", "_").replace("|", "_")
	if not filename.ends_with(".png"):
		filename += ".png"
	var dir_path := "user://mcp_screenshots"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir_path))
	await get_tree().process_frame
	RenderingServer.force_draw(false)
	var viewport := get_viewport()
	if viewport == null:
		return _fail("无法获取游戏视口")
	var img: Image = viewport.get_texture().get_image()
	if img == null or img.is_empty():
		return _fail("游戏截图失败: 视口纹理为空")
	var max_width := int(args.get("max_width", 0))
	if max_width > 0 and max_width < img.get_width():
		var scale := float(max_width) / float(img.get_width())
		img.resize(max_width, int(img.get_height() * scale), Image.INTERPOLATE_LANCZOS)
	var path := "%s/%s" % [dir_path, filename]
	var img_err := img.save_png(path)
	if img_err != OK:
		return _fail("保存截图失败: 错误码 %d" % img_err)
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(path)
	return _ok(JSON.stringify({
		"path": ProjectSettings.globalize_path(path),
		"res_path": path,
		"width": img.get_width(),
		"height": img.get_height(),
		"bytes": bytes.size() if bytes else 0,
		"capture_type": "game",
	}))


## ======= 编辑器模式的运行时工具转发 =======

func _register_game_play_tools() -> void:
	# 编辑器模式下, 运行时工具经 HTTP 转发到游戏进程的运行时服务器
	_add_tool("get_game_view",
		"分析游戏运行时场景中所有可见节点的屏幕位置和大小信息(经编辑器转发到游戏进程)。需先 run_game 启动游戏。用于AI理解游戏画面布局以决定点击/拖拽目标。",
		{"type": "object", "properties": {
			"max_nodes": {"type": "integer", "description": "最多返回节点数, 默认 50"},
			"include_hidden": {"type": "boolean", "description": "是否包含不可见节点, 默认 false"},
			"filter_type": {"type": "string", "description": "过滤节点类型, 如 'Button', 'Label', 'Sprite2D'"}
		}},
		func(args): return await _call_runtime_proxy("get_game_view", args))

	_add_tool("simulate_click",
		"在游戏窗口内模拟一次鼠标点击(经编辑器转发到游戏进程)。需先 run_game 启动游戏。坐标为游戏视口坐标。",
		{"type": "object", "properties": {
			"x": {"type": "integer", "description": "屏幕X坐标"},
			"y": {"type": "integer", "description": "屏幕Y坐标"},
			"button": {"type": "string", "description": "鼠标按钮: 'left'(左键), 'right'(右键), 'middle'(中键), 默认 'left'"},
			"double_click": {"type": "boolean", "description": "是否双击, 默认 false"}
		}, "required": ["x", "y"]},
		func(args): return await _call_runtime_proxy("simulate_click", args))

	_add_tool("simulate_drag",
		"在游戏窗口内模拟从起始位置拖拽到目标位置(经编辑器转发到游戏进程)。需先 run_game 启动游戏。",
		{"type": "object", "properties": {
			"from_x": {"type": "integer", "description": "起始X坐标"},
			"from_y": {"type": "integer", "description": "起始Y坐标"},
			"to_x": {"type": "integer", "description": "目标X坐标"},
			"to_y": {"type": "integer", "description": "目标Y坐标"},
			"duration": {"type": "number", "description": "拖拽持续时间(秒), 默认 0.5"}
		}, "required": ["from_x", "from_y", "to_x", "to_y"]},
		func(args): return await _call_runtime_proxy("simulate_drag", args))

	_add_tool("simulate_key",
		"在游戏窗口内模拟一次键盘按键(经编辑器转发到游戏进程)。需先 run_game 启动游戏。",
		{"type": "object", "properties": {
			"key": {"type": "string", "description": "按键名称, 如 'space', 'enter', 'escape', 'a'-'z', '0'-'9'"},
			"pressed": {"type": "boolean", "description": "true=按下, false=释放, 默认 true"},
			"shift": {"type": "boolean", "description": "是否按住Shift, 默认 false"},
			"ctrl": {"type": "boolean", "description": "是否按住Ctrl, 默认 false"}
		}, "required": ["key"]},
		func(args): return await _call_runtime_proxy("simulate_key", args))

	_add_tool("game_eval",
		"在游戏进程中执行一段 GDScript 代码(经编辑器转发到游戏进程)。需先 run_game 启动游戏。可访问游戏场景树。",
		{"type": "object", "properties": {"code": {"type": "string", "description": "要执行的 GDScript 代码"}}},
		func(args): return await _call_runtime_proxy("game_eval", args))

	_add_tool("get_game_logs",
		"获取游戏进程的日志(经编辑器转发到游戏进程)。需先 run_game 启动游戏。",
		{"type": "object", "properties": {"since": {"type": "integer", "description": "增量索引"}, "keyword": {"type": "string", "description": "关键字过滤"}, "max": {"type": "integer", "description": "最多条数, 默认 200"}}},
		func(args): return await _call_runtime_proxy("get_game_logs", args))

	_add_tool("get_game_errors",
		"获取游戏进程捕获的错误(经编辑器转发到游戏进程)。需先 run_game 启动游戏。",
		{"type": "object", "properties": {"since": {"type": "integer", "description": "增量索引"}, "max": {"type": "integer", "description": "最多条数, 默认 100"}}},
		func(args): return await _call_runtime_proxy("get_game_errors", args))

	_add_tool("clear_game_errors",
		"清空游戏进程的错误缓冲区(经编辑器转发到游戏进程)。需先 run_game 启动游戏。",
		{"type": "object", "properties": {}},
		func(args): return await _call_runtime_proxy("clear_game_errors", args))


## 转发工具调用到游戏进程的运行时服务器(仅编辑器模式)
func _call_runtime_proxy(tool_name: String, args: Dictionary) -> Dictionary:
	if _run_pid == 0:
		return _fail("游戏未运行。请先使用 run_game 启动游戏")
	if not OS.is_process_running(_run_pid):
		_run_pid = 0
		return _fail("游戏进程已退出。请重新 run_game 启动游戏")
	var url := "http://127.0.0.1:%d/mcp" % _runtime_port
	var payload := {
		"jsonrpc": "2.0",
		"id": 1,
		"method": "tools/call",
		"params": {"name": tool_name, "arguments": args},
	}
	var token: String = ProjectSettings.get_setting(SETTING_TOKEN, "")
	var headers := PackedStringArray(["Content-Type: application/json"])
	if not token.is_empty():
		headers.append("Authorization: Bearer " + token)
	var req := HTTPRequest.new()
	add_child(req)
	var err := req.request(url, headers, HTTPClient.METHOD_POST, JSON.stringify(payload))
	if err != OK:
		req.queue_free()
		return _fail("无法连接游戏运行时服务器(%s): 请求发送失败(err=%d)。请确认 run_game 已启动。" % [url, err])
	var resp: Array = await req.request_completed
	req.queue_free()
	var resp_code: int = resp[1]
	if resp_code != 200:
		return _fail("游戏运行时服务器返回 HTTP %d。游戏可能尚未就绪, 请稍后重试。" % resp_code)
	var parsed: Variant = JSON.parse_string(resp[3].get_string_from_utf8())
	if parsed == null or not parsed is Dictionary:
		return _fail("游戏运行时服务器响应解析失败")
	var result: Dictionary = parsed.get("result", {})
	var content: Array = result.get("content", [])
	var text := ""
	for c in content:
		if c is Dictionary and c.get("type") == "text":
			text += str(c.get("text", ""))
	return {
		"text": text,
		"is_error": bool(result.get("isError", false)),
	}
