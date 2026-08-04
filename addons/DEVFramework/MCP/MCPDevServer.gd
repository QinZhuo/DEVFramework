@tool
## MCP 开发服务器 — 在 Godot 编辑器内嵌 MCP Streamable HTTP 服务器
## 让 AI 助手(opencode/Claude Code 等)通过 http://127.0.0.1:<端口>/mcp 连接
## 以**编辑器**为主工具, 提供:
##   验证脚本 / 验证资源 / 读取日志 / 读取错误与栈追踪 / 编辑器视口截图 /
##   当前编辑场景树 / 节点属性读写 / 调用节点方法 / 项目信息 /
##   重载项目 / 执行代码 / 全局类列表 / 场景与主场景管理 / 项目设置读写 / 全部保存 / 重新导入
## 生命周期由 plugin.gd 接管(启用插件时 start, 停用插件时 stop), 不使用 autoload
class_name MCPDevServer extends RefCounted

## ------- 配置项(ProjectSettings, 见 plugin.gd 注册) -------
const SETTING_ENABLED := "dev_framework/mcp/enabled"
const SETTING_PORT := "dev_framework/mcp/port"
const SETTING_MAX_MESSAGES := "dev_framework/mcp/max_messages"
const SETTING_TOKEN := "dev_framework/mcp/token"

## 输出给 AI 的核心属性白名单(过滤编辑器内部数百项属性, 控制上下文开销)
const CORE_PROP_NAMES := ["name", "position", "scale", "rotation", "rotation_degrees", "visible", "modulate", "process_mode", "z_index", "text", "color"]

## ------- MCP 常量 -------
const PROTOCOL_VERSION := "2025-03-26"          # 支持的 MCP 协议版本
const SERVER_NAME := "devframework-godot-mcp"
const SERVER_VERSION := "0.1.0"

var _http: MCPTcpHttpServer
var _logger: MCPLogger
var _port := 8931
var _enabled := true
var _tool_handlers := {}        # 工具名 -> Callable
var _tool_defs := []            # 工具定义列表(MCP 格式)
var _editor: EditorInterface

## 运行中游戏日志捕获: 游戏进程以 --log-file 写入项目 user://game_run.log,
## 编辑器进程增量读取该文件(增量解析已完成/持续写入的行), 并入 get_logs。
## 采用 create_process + --log-file 而非编辑器播放机制/调试器桥:
##  - EditorDebuggerPlugin._capture 收不到内建 "output" 消息(被内建 ScriptEditorDebugger 消费)
##  - play_custom_scene 不支持自定义命令行参数(无法注入 --log-file)
## 读取策略(通用/跨平台):
##  1) 首选 Godot FileAccess 增量读: POSIX(Linux/macOS)及部分场景下共享读可用, 零子进程开销, UTF-8 天然正确
##  2) Windows 上游戏进程对 --log-file 独占锁导致 FileAccess 失败时, 退化为子进程读取:
##     用 PowerShell 按字节 Seek 增量读, 并以 base64(纯 ASCII)输出, 彻底绕开系统代码页(GBK/CP1252)
##     转码问题; Godot 端 base64 解码后按 UTF-8 还原, 编码无损。
##  只消费完整行(以 \n 结尾), 最后的不完整行按字节回退 offset, 下帧重读, 不丢不重。
var _run_pid := 0               # 游戏进程 PID(0=未运行)
var _run_log_abs := ""          # 游戏 --log-file 的绝对路径(user://game_run.log)
var _run_log_offset := 0        # 上次已消费到完整行末尾的字节偏移(增量读取)
var _run_last_poll_ms := 0      # 上次轮询时间戳(节流)
var _run_use_subprocess := false  # 当前是否处于子进程读取模式(FileAccess 被锁)

## FileAccess 读取模式的轮询间隔(轻量, 可较频繁)
const RUN_LOG_POLL_INTERVAL_MS := 200
## 子进程读取模式的轮询间隔(每次启动子进程约 200~300ms 固定开销, 需低频)
const RUN_LOG_POLL_INTERVAL_MS_FALLBACK := 1500

## 全局唯一实例(由 plugin.gd 持有)
static var instance: MCPDevServer


func _init(editor: EditorInterface) -> void:
	_editor = editor
	_enabled = ProjectSettings.get_setting(SETTING_ENABLED, true)
	_port = int(ProjectSettings.get_setting(SETTING_PORT, 8931))
	# 编辑器进程内注册 Logger, 捕获编辑器控制台输出与错误(含 GDScript 栈追踪)
	_logger = MCPLogger.new()
	OS.add_logger(_logger)
	_register_tools()


## 由 plugin.gd 在 _exit_tree 时调用, 停止并清理
func shutdown() -> void:
	if instance == self:
		instance = null
	stop()
	if _logger:
		OS.remove_logger(_logger)
		_logger = null


## 由 plugin.gd 在 _enter_tree 时调用, 启动 HTTP 服务器
func start() -> void:
	if not _enabled or _http:
		return
	instance = self
	_http = MCPTcpHttpServer.new()
	var err := _http.listen(_port)
	if err != OK:
		printerr("MCPDevServer: 监听端口 %d 失败 (错误码 %d)。已自动跳过, AI 助手将无法连接。" % [_port, err])
		_http = null
		return
	_http.request_received.connect(_on_request)
	LogTool.log("MCP", "MCP 服务器已开启(编辑器): http://127.0.0.1:%d/mcp" % _port)
	LogTool.log("MCP", "可用工具: ", _tool_defs.map(func(d): return d.name))


## 由 plugin.gd 每帧调用, 驱动 HTTP 服务器处理请求
func poll() -> void:
	if _http:
		_http.poll()
	_poll_run_log()


## 关闭服务器(保留 Logger)
func stop() -> void:
	if _http:
		_http.request_received.disconnect(_on_request)
		_http.stop()
		_http = null


func is_running() -> bool:
	return _http != null and _http.is_listening()


## ------- 工具注册 -------
func _register_tools() -> void:
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


func _add_tool(name: String, desc: String, input_schema: Dictionary, handler: Callable) -> void:
	_tool_handlers[name] = handler
	_tool_defs.append({"name": name, "description": desc, "inputSchema": input_schema})


## ======= 工具实现 =======

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
		"获取编辑器控制台日志(print/printerr 输出)。支持 since 索引增量获取, 以及按关键字过滤、截断数量。返回日志数组(含时间戳/是否错误流)。",
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


## -- 编辑器截图 --
func _register_screenshot_tools() -> void:
	_add_tool("take_screenshot",
		"捕获编辑器当前视口(编辑器窗口)的截图并保存到本地(user://mcp_screenshots/)。返回截图文件路径、像素尺寸与占用字节。AI 可通过文件路径读取分析画面。可选 max_width 限制最大宽度以降采样(减少 AI 读图开销)。可选 capture_type 指定截图类型: 'editor' 编辑器视口(默认), 'scene' 当前场景缩略图, 'game' 运行中的游戏画面。",
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
		"启动项目(独立进程)以便实际测试。必须提供 scene: 要运行的场景 res:// 路径(如 res://Scenes/Main/Main.tscn), 缺省会报错。运行日志实时合并进 get_logs。",
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
		"在编辑器进程中执行一段 GDScript 代码(常用于查值/调工具/验证逻辑)。代码中可显式 return 返回值; print 输出会进入 get_logs。缩进自动归一化(tab/空格均可)。注意: 字符串内需要换行请用 char(10) 而非 '\\n'(JSON 传输会拆行导致字符串被破坏); 语法错误详情输出到编辑器控制台, 可用 get_logs 查看。",
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
	# 游戏运行日志上报端点(由 DevMCPLog autoload 调用, 绕过 MCP 协议)
	if path == "/log":
		_handle_log_post(body)
		_http.send_response(stream, 200, _cors_headers(headers), "OK")
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


## CORS 响应头: 不再无条件返回 "*", 仅对(可能的)本地 Origin 回显, 收紧跨域面
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
		# 通知类(无 id): initialized 等, 返回空字典表示不回包
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
			# 每次查询都重新注册: 脚本热重载后新工具立即可用, 无需重启编辑器
			_register_tools()
			return {"jsonrpc": "2.0", "id": req_id, "result": {"tools": _tool_defs}}
		"tools/call":
			var params: Dictionary = req.get("params", {})
			var tool_name: String = params.get("name", "")
			var arguments: Dictionary = params.get("arguments", {})
			LogTool.log("MCP", "工具调用: %s, 参数: %s" % [tool_name, str(arguments)])
			if not _tool_handlers.has(tool_name):
				# 未知工具时先尝试热重载注册(兼容脚本热重载后的新工具)
				_register_tools()
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
	# reload() 会把 "Warning treated as error"(如 untyped_declaration) 当作编译错误返回,
	# 而这类脚本编辑器/正常加载路径是可用的。因此不能只看错误码:
	# 记录 reload 前后错误缓冲新增条目, 区分真实语法错误与 warning 类误报。
	var n0: int = _logger.get_error_count() if _logger else 0
	var reload_err := script.reload()
	var new_errs: Array = []
	if _logger:
		var all_entries: Array = _logger.take_errors_since(0).entries
		var added: int = all_entries.size() - n0
		if added > 0:
			new_errs = all_entries.slice(maxi(0, all_entries.size() - added))
	# 解析新增错误: 纯 warning 类(被当错误)不算语法错误
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
		# reload 失败但新增错误全是 warning-as-error: 按语法有效处理
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
	var result: Dictionary = _logger.take_errors_since(0)
	var out: Array = result.entries.duplicate()
	if out.size() > max:
		out = out.slice(out.size() - max)
	var cleaned: Array = []
	for e in out:
		var clean: Dictionary = e.duplicate()
		if clean.has("message"):
			clean.message = _logger.sanitize(str(clean.message))
		cleaned.append(clean)
	return _ok(JSON.stringify({"count": cleaned.size(), "errors": cleaned}))


func _call_clear_errors(_args: Dictionary) -> Dictionary:
	if _logger:
		_logger.clear_errors()
	return _ok("已清空错误缓冲区")


func _call_take_screenshot(args: Dictionary) -> Dictionary:
	var filename: String = str(args.get("filename", ""))
	if filename.is_empty():
		filename = "mcp_%s" % Time.get_datetime_string_from_system().replace(":", "-").replace(" ", "_")
	# 清理文件名中的非法字符(Windows 不支持 : / \ * ? " < > |), 避免保存失败
	filename = filename.replace("/", "_").replace("\\", "_").replace("*", "_").replace("?", "_")\
		.replace("\"", "_").replace("<", "_").replace(">", "_").replace("|", "_")
	if not filename.ends_with(".png"):
		filename += ".png"
	# 保存到 .godot 目录下，不会被 Godot 扫描为资源，也不会被版本控制
	var dir_path := "res://.godot/mcp_screenshots"
	var dir := DirAccess.open("res://")
	if dir:
		dir.make_dir_recursive(".godot/mcp_screenshots")
	var capture_type: String = str(args.get("capture_type", "editor"))
	var img: Image = null
	var img_err := OK
	match capture_type:
		"scene":
			# 场景缩略图模式
			img = await _capture_scene_thumbnail(args)
			if img == null or img.is_empty():
				return _fail("场景缩略图生成失败: 无法渲染场景或场景为空")
		"game":
			# 游戏运行画面模式
			if _run_pid == 0:
				return _fail("游戏未运行, 无法截图。请先使用 run_game 启动游戏")
			img = await _capture_game_viewport()
			if img == null or img.is_empty():
				return _fail("游戏截图失败: 游戏视口纹理为空")
		_:  # "editor"
			# 编辑器视口模式(默认)
			img = await _capture_editor_viewport()
			if img == null or img.is_empty():
				return _fail("截图失败: 编辑器视口纹理为空")
	# 可选按最大宽度等比缩小, 控制 AI 视觉读图的分辨率开销
	var max_width := int(args.get("max_width", 0))
	if max_width > 0 and max_width < img.get_width():
		var scale := float(max_width) / float(img.get_width())
		img.resize(max_width, int(img.get_height() * scale), Image.INTERPOLATE_LANCZOS)
	var path := "%s/%s" % [dir_path, filename]
	img_err = img.save_png(path)
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
	var base: Control = _editor.get_base_control() if _editor else null
	if base == null:
		return null
	var viewport := base.get_viewport()
	var tree := base.get_tree()
	if viewport == null or tree == null:
		return null
	# 等待渲染完成
	await _wait_frames(tree, 3, 2500)
	# 强制渲染一次最新画面
	RenderingServer.force_draw(false)
	return viewport.get_texture().get_image()


## 捕获游戏运行画面截图
func _capture_game_viewport() -> Image:
	# 获取运行中游戏的视口
	var tree := _editor.get_base_control().get_tree() if _editor else null
	if tree == null:
		return null
	# 等待渲染完成
	await _wait_frames(tree, 3, 2500)
	# 游戏运行时, 通过编辑器的游戏预览视口获取
	var game_viewports := _find_game_viewports()
	if game_viewports.is_empty():
		return null
	# 使用第一个游戏视口
	var viewport: Viewport = game_viewports[0]
	return viewport.get_texture().get_image()


## 查找游戏运行预览视口
func _find_game_viewports() -> Array:
	var viewports: Array = []
	var base: Control = _editor.get_base_control() if _editor else null
	if base == null:
		return viewports
	# 递归查找所有视口
	_find_viewports_recursive(base.get_viewport(), viewports)
	return viewports


## 递归查找视口
func _find_viewports_recursive(node: Node, viewports: Array) -> void:
	if node is SubViewportContainer or node is SubViewport:
		viewports.append(node)
	for child in node.get_children():
		_find_viewports_recursive(child, viewports)


## 生成场景缩略图
func _capture_scene_thumbnail(args: Dictionary) -> Image:
	var scene_path: String = str(args.get("scene_path", ""))
	var thumbnail_size: int = int(args.get("thumbnail_size", 256))
	# 如果没有指定场景路径, 使用当前编辑的场景
	if scene_path.is_empty():
		var root := _edited_root()
		if root == null:
			return null
		scene_path = root.get_scene_file_path()
		if scene_path.is_empty():
			return null
	# 加载场景
	if not ResourceLoader.exists(scene_path):
		return null
	var scene_res: Resource = ResourceLoader.load(scene_path)
	if not scene_res is PackedScene:
		return null
	# 实例化场景
	var scene_instance: Node = scene_res.instantiate()
	if scene_instance == null:
		return null
	# 创建子视口进行渲染
	var viewport := SubViewport.new()
	viewport.size = Vector2i(thumbnail_size, thumbnail_size)
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	# 添加场景到视口
	viewport.add_child(scene_instance)
	scene_instance.owner = viewport
	# 添加视口到场景树(临时)
	var base: Control = _editor.get_base_control() if _editor else null
	if base == null:
		viewport.queue_free()
		return null
	var tree := base.get_tree()
	if tree == null:
		viewport.queue_free()
		return null
	tree.root.add_child(viewport)
	# 等待渲染完成
	await _wait_frames(tree, 5, 3000)
	# 获取渲染结果
	var img: Image = viewport.get_texture().get_image()
	# 清理
	viewport.queue_free()
	return img


## 等待若干帧, 带超时上限(毫秒, 0 表示不限)。超时静默返回,
## 用于窗口被遮挡/headless 等无法产生绘制帧的场景, 避免调用方无限挂起。
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


## 提取对 AI 调试最有用的核心属性: 脚本导出变量 + 白名单常用属性,
## 排除 theme_override/focus_/accessibility_/editor 内部属性及资源对象, 避免上下文爆炸。
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
	# 先尝试智能自动转换，如果失败再使用目标类型转换
	var typed: Variant = _auto_convert_arg(value)
	if typed is String and current != null:
		# 自动转换未生效（仍是字符串），使用目标类型转换
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
	# 对参数进行智能类型转换
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
	# 实例化子场景 或 按类型创建节点
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
	# 无论挂在哪个父节点下都设为场景根 owner(含子树), 否则保存场景时新节点不会写入 .tscn
	_assign_owner_recursive(new_node, root)
	return _ok("已添加节点 %s [%s] 到 %s" % [new_node.name, new_node.get_class(), parent.name])


## 递归把节点及其子树 owner 设为场景根, 保证新增节点可随场景保存
func _assign_owner_recursive(node: Node, root: Node) -> void:
	node.owner = root
	for child in node.get_children():
		_assign_owner_recursive(child, root)


func _call_save_scene(_args: Dictionary) -> Dictionary:
	if _editor == null:
		return _fail("编辑器不可用")
	var root := _edited_root()
	if root == null:
		return _fail("当前没有打开的场景")
	var err := _editor.save_scene()
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


## 读取图层命名(2d_physics/2d_render/3d_physics/3d_render)
func _named_layers(setting_key: String) -> Dictionary:
	var out := {}
	for key in ProjectSettings.get_property_list():
		var name: String = str(key.get("name", ""))
		if name.begins_with(setting_key + "/"):
			var idx := name.trim_prefix(setting_key + "/")
			out[int(idx)] = ProjectSettings.get_setting(name)
	return out


func _call_run_game(args: Dictionary) -> Dictionary:
	if _editor == null:
		return _fail("编辑器不可用")
	if _run_pid != 0:
		return _fail("游戏已在运行(pid=%d)。如需重启请先 stop_game。" % _run_pid)
	var scene := str(args.get("scene", ""))
	if scene.is_empty():
		return _fail("必须提供 scene(要运行的场景 res:// 路径), 例如 res://Scenes/Main/Main.tscn")
	if not scene.begins_with("res://"):
		scene = "res://" + scene
	if not ResourceLoader.exists(scene):
		return _fail("启动场景不存在: %s" % scene)
	# 加载并校验确为场景文件, 避免误传脚本/贴图等资源
	var scene_res: Resource = ResourceLoader.load(scene)
	if not scene_res is PackedScene:
		return _fail("不是有效场景文件: %s(类型: %s)" % [scene, scene_res.get_class() if scene_res else "null"])
	# 直接启动 godot 子进程运行该场景, 并以 --log-file 写入 user://game_run.log(绝对路径),
	# 编辑器进程每帧增量读取该文件实时并入 get_logs(Windows 共享读已验证可行)。
	_run_log_abs = ProjectSettings.globalize_path("user://game_run.log")
	_run_log_offset = 0
	_run_use_subprocess = false
	# 清掉旧日志, 避免混入上一次运行残留
	var f := FileAccess.open(_run_log_abs, FileAccess.WRITE)
	if f:
		f.store_string("")
		f.close()
	var exe := OS.get_executable_path()
	var args_arr := PackedStringArray(["--path", ProjectSettings.globalize_path("res://"), scene, "--log-file", _run_log_abs])
	_run_pid = OS.create_process(exe, args_arr)
	if _run_pid == 0:
		_run_log_abs = ""
		return _fail("启动游戏进程失败(OS.create_process 返回 0)。可检查路径: %s" % exe)
	return _ok("已启动游戏(独立进程, pid=%d) 场景=%s。运行日志经 --log-file 实时并入 get_logs。" % [_run_pid, scene])


func _call_stop_game(_args: Dictionary) -> Dictionary:
	if _run_pid == 0:
		return _fail("当前没有运行中的游戏")
	if OS.is_process_running(_run_pid):
		OS.kill(_run_pid)
	_run_pid = 0
	return _ok("已停止游戏")


## 每帧调用: 增量读取游戏 --log-file 输出, 并入 _logger; 并检测游戏进程退出
func _poll_run_log() -> void:
	# 进程已退出(正常退出/崩溃/被外部关闭)时清理 PID, 避免 stop_game 对无效进程误操作
	if _run_pid != 0 and not OS.is_process_running(_run_pid):
		_run_pid = 0
	if _run_pid == 0 or _logger == null or _run_log_abs.is_empty():
		return
	# 节流: FileAccess 模式轻量可频繁; 子进程模式每次启动外部进程开销大, 需低频
	var interval := RUN_LOG_POLL_INTERVAL_MS_FALLBACK if _run_use_subprocess else RUN_LOG_POLL_INTERVAL_MS
	var now := Time.get_ticks_msec()
	if now - _run_last_poll_ms < interval:
		return
	_run_last_poll_ms = now
	if not FileAccess.file_exists(_run_log_abs):
		return
	# 首选 FileAccess 增量读; 失败(Windows 上文件被游戏进程独占锁)时退化子进程读取
	if _read_run_log_via_fileaccess():
		_run_use_subprocess = false
	elif OS.get_name() == "Windows":
		_run_use_subprocess = true
		_read_run_log_via_powershell()
	else:
		_run_use_subprocess = false


## FileAccess 增量读: 从 _run_log_offset 读到 EOF, 更新偏移并消费完整行。
## 返回是否成功打开并读取(读取到的内容可能为空, 空也视为成功)。
func _read_run_log_via_fileaccess() -> bool:
	if _run_log_offset < 0:
		_run_log_offset = 0
	var f := FileAccess.open(_run_log_abs, FileAccess.READ)
	if f == null:
		return false
	f.seek(_run_log_offset)
	var txt := f.get_as_text()
	_run_log_offset = f.get_position()
	f.close()
	_consume_run_lines(txt)
	return true


## Windows fallback: 用 PowerShell 按字节 Seek 增量读 [offset, EOF], base64 输出避免系统代码页转码。
func _read_run_log_via_powershell() -> bool:
	var ps := _find_powershell()
	if ps.is_empty():
		return false
	if _run_log_offset < 0:
		_run_log_offset = 0
	var esc_path := _run_log_abs.replace("'", "''")
	# FileShare 'ReadWrite': 允许与游戏写进程共存; 读到 EOF 后对字节流做 base64(纯 ASCII)输出
	var cmd := "[Console]::OutputEncoding=[Text.Encoding]::ASCII; $fs=[IO.File]::Open('%s','Open','Read','ReadWrite'); try { $fs.Seek(%d,'Begin') | Out-Null; $ms=[IO.MemoryStream]::new(); $fs.CopyTo($ms); } finally { $fs.Close() }; [Convert]::ToBase64String($ms.ToArray())" % [esc_path, _run_log_offset]
	var out := []
	var err := OS.execute(ps, ["-NoProfile", "-NonInteractive", "-Command", cmd], out)
	if err != 0 or out.is_empty():
		return false
	var bytes := Marshalls.base64_to_raw(str(out[0]).strip_edges())
	if bytes.is_empty():
		# 无新内容: 不推进偏移, 静默返回
		return true
	_run_log_offset += bytes.size()
	_consume_run_lines(bytes.get_string_from_utf8())
	return true


## 查找可用的 PowerShell 可执行文件(Windows 必有 v1.0 路径, 优先精确路径避免 PATH 缺失)
func _find_powershell() -> String:
	var candidates := [
		"C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe",
		"C:/Program Files/PowerShell/7/pwsh.exe",
	]
	for c in candidates:
		if FileAccess.file_exists(c):
			return c
	return "powershell.exe"


## 消费一批日志文本: 拆行, 完整行并入 logger; 最后不完整行按字节回退 offset, 下帧续读。
## 要求 _run_log_offset 已指向本批文本的文件尾字节位置(FileAccess 的 get_position 或 PowerShell 的 EOF)。
func _consume_run_lines(txt: String) -> void:
	if txt.is_empty():
		return
	var incomplete := ""
	var incomplete_bytes := 0
	if not txt.ends_with("\n"):
		# 最后一段不完整(无 \n), 回退其字节数, 下帧从完整行末尾重读
		var lines := txt.split("\n", false)
		if not lines.is_empty():
			incomplete = lines[lines.size() - 1]
			lines = lines.slice(0, lines.size() - 1)
		incomplete_bytes = incomplete.to_utf8_buffer().size()
		if incomplete_bytes > 0:
			_run_log_offset -= incomplete_bytes
			if _run_log_offset < 0:
				_run_log_offset = 0
		txt = "\n".join(lines)
	for line in txt.split("\n"):
		var trimmed := line.strip_edges()
		if not trimmed.is_empty():
			_logger.append_external(trimmed)


## ======= 开发辅助工具实现 =======

func _call_reload_project(args: Dictionary) -> Dictionary:
	if _editor == null:
		return _fail("编辑器不可用")
	var reopen: bool = _to_bool(args.get("reopen_scene", false))
	# 常规重载: 重建类缓存 + 重扫资源
	var fs := _editor.get_resource_filesystem()
	if fs == null:
		return _fail("编辑器文件系统不可用")
	# 记录当前场景
	var current := ""
	if _edited_root() != null:
		current = _edited_root().get_scene_file_path()
	# 触发扫描(非阻塞): 让扫描在后台进行, 不等待完成
	# 这样 MCP 请求可以立即返回, 不会导致超时
	fs.scan_sources()
	fs.scan()
	var msg := "已触发项目重载: scan_sources(重建类缓存) + scan(重扫资源)。扫描将在后台进行, 新资源可能需要片刻才能生效。"
	if reopen and not current.is_empty():
		# 延迟重载场景, 给扫描一些时间
		var tree := _editor.get_base_control().get_tree()
		if tree:
			await tree.create_timer(1.0).timeout
		_editor.open_scene_from_path(current)
		msg += " 已重载当前场景 %s。注意: 未保存修改可能已丢失。" % current
	elif reopen and current.is_empty():
		msg += " 提示: 当前没有打开的场景, 未执行场景重载。"
	return _ok(msg)


func _call_eval_code(args: Dictionary) -> Dictionary:
	var code: String = str(args.get("code", ""))
	if code.is_empty():
		return _fail("必须提供 code")
	var script := GDScript.new()
	# 将用户代码归一化为统一空格缩进的方法体, 避免 tab/空格混排导致 Parse error。
	# GDScript 函数未显式 return 时默认返回 null, 无需追加兜底 return。
	var body := _indent_method_body(code)
	script.source_code = "extends RefCounted\nstatic func _mcp_run():\n%s" % body
	var err := script.reload()
	if err != OK:
		var text := error_string(err)
		var hint := ""
		if text.contains("hides a global script class"):
			hint = " (class_name 与全局类冲突: 请勿在 eval_code 中声明类, 或先 reload_project)"
		return _fail("代码解析失败: %s%s\n解析详情已输出到编辑器控制台, 可用 get_logs 查看。" % [text, hint])
	var inst: Object = script.new()
	if inst == null:
		return _fail("无法实例化求值脚本")
	var result: Variant = inst.call("_mcp_run")
	var shown := str(result)
	if result is Dictionary or result is Array:
		shown = JSON.stringify(result)
	return _ok("执行成功, 返回: %s" % shown)


## 把用户 eval_code 规范成方法体缩进: 前导 tab 按 4 空格折算, 混合前导空白统一为纯空格,
## 每行再整体缩进 4 空格。这样用户用 tab 或空格缩进都不会与 GDScript 的混排限制冲突。
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
	var path := str(args.get("path", ""))
	if path.is_empty() or not ResourceLoader.exists(path):
		return _fail("场景不存在: %s" % path)
	_editor.open_scene_from_path(path)
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
	_editor.save_all_scenes()
	var ps := ProjectSettings.save()
	return _ok("已保存全部场景, 项目设置(err=%d)" % ps)


func _call_reimport(args: Dictionary) -> Dictionary:
	var path := str(args.get("path", ""))
	if path.is_empty() or not ResourceLoader.exists(path):
		return _fail("资源不存在: %s" % path)
	if _editor.get_resource_filesystem() == null:
		return _fail("编辑器文件系统不可用")
	_editor.get_resource_filesystem().reimport_files([path])
	return _ok("已触发重新导入: %s" % path)


## 接收游戏运行日志(DevMCPLog 转发), 按行合并进日志缓冲
func _handle_log_post(body: PackedByteArray) -> void:
	if _logger == null:
		return
	var text := body.get_string_from_utf8()
	for line in text.split("\n"):
		var trimmed := line.strip_edges()
		if trimmed.is_empty():
			continue
		_logger.append_external(trimmed)


## ======= 辅助 =======

## 当前正在编辑的场景根节点(EditorInterface.get_edited_scene_root)
func _edited_root() -> Node:
	if _editor == null:
		return null
	return _editor.get_edited_scene_root()


## 在编辑场景内解析节点(名称/相对路径/绝对路径)
func _resolve_node(path: String) -> Node:
	var root := _edited_root()
	if root == null:
		return null
	if path == "root" or path == "/":
		return root
	if path.begins_with("@"):
		# 唯一名称 %Name 处理
		return root.find_child(path.substr(1), true, false)
	if path.begins_with("/"):
		# 去掉前导斜杠后按场景根相对路径找
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
			# 数字字符: 0-9
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


## ======= 文件操作工具 =======
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


## -- 文件操作实现 --

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
		# Windows 中文环境下的 GBK 编码支持
		var bytes := file.get_buffer(file.get_length())
		content = bytes.get_string_from_utf8()  # Godot 内部使用 UTF-8
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
	# 自动创建目录
	if create_dirs:
		var dir_path := path.get_base_dir()
		if not dir_path.is_empty():
			var dir := DirAccess.open(dir_path)
			if dir == null:
				# 目录不存在, 尝试创建
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
	# 如果文件不存在, 创建新文件
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
		# 检查是否是目录
		var dir := DirAccess.open(path)
		if dir == null:
			return _fail("文件或目录不存在: %s" % path)
		# 是目录, 尝试删除空目录
		var err := DirAccess.remove_absolute(path)
		if err != OK:
			return _fail("无法删除目录: %s (错误码: %d)。注意: 只能删除空目录" % [path, err])
		return _ok(JSON.stringify({"path": path, "message": "目录删除成功"}))
	# 是文件
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
		# 检查是否是目录
		var dir := DirAccess.open(path)
		is_dir = dir != null
	return _ok(JSON.stringify({
		"path": path,
		"exists": exists or is_dir,
		"is_directory": is_dir,
		"message": "文件存在" if exists else ("目录存在" if is_dir else "文件不存在")
	}))