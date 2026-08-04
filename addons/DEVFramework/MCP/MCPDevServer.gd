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

## 运行中游戏进程管理(独立进程 + --log-file 合并进 get_logs)
var _run_pid := 0             # >0 表示游戏在运行
var _run_log_path := "user://mcp_run.log"
var _run_log_offset := 0      # get_logs 增量读取的字节偏移

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


func _add_tool(name: String, desc: String, input_schema: Dictionary, handler: Callable) -> void:
	_tool_handlers[name] = handler
	_tool_defs.append({"name": name, "description": desc, "inputSchema": input_schema})


## ======= 工具实现 =======

## -- 脚本/资源验证 --
func _register_validate_tools() -> void:
	_add_tool("validate_script",
		"验证一个 GDScript 脚本的语法与可编译性(不执行)。返回是否有效及错误明细(含行号/信息)。可传 'path'(res://路径) 读取磁盘脚本, 或 'code'(源码文本)直接验证。",
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
		"捕获编辑器当前视口(编辑器窗口)的截图并保存到本地(user://mcp_screenshots/)。返回截图文件路径、像素尺寸与占用字节。AI 可通过文件路径读取分析画面。可选 max_width 限制最大宽度以降采样(减少 AI 读图开销)。",
		{"type": "object", "properties": {
			"filename": {"type": "string", "description": "截图文件名(不含路径), 默认自动按时间命名"},
			"max_width": {"type": "integer", "description": "可选: 若截图宽度超过该值则等比缩小以便 AI 读图(默认不缩放)"},
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
		{"type": "object", "properties": {"reopen_scene": {"type": "boolean", "description": "是否重载当前编辑场景, 默认 false(注意: 未保存修改会丢失)"}}},
		_call_reload_project)

	_add_tool("eval_code",
		"在编辑器进程中执行一段 GDScript 代码(常用于查值/调工具/验证逻辑)。代码中可显式 return 返回值; print 输出会进入 get_logs。注意: 语法错误详情输出到编辑器控制台, 可用 get_logs 查看。",
		{"type": "object", "properties": {"code": {"type": "string", "description": "要执行的 GDScript 代码(方法体内容, 缩进由服务器处理)"}}},
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
	if method == "OPTIONS":
		_http.send_response(stream, 204, {"Access-Control-Allow-Origin": "*", "Access-Control-Allow-Methods": "POST, GET, OPTIONS", "Access-Control-Allow-Headers": "*"}, "")
		return
	if method != "POST":
		_http.send_response(stream, 405, {"Allow": "POST, OPTIONS", "Content-Type": "application/json"}, "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32000,\"message\":\"Method Not Allowed\"},\"id\":null}")
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
	_http.send_response(stream, 200, {"Content-Type": "application/json", "Access-Control-Allow-Origin": "*", "Mcp-Session-Id": _make_session_id(headers)}, json)


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
	# 注意: 不设置 resource_path——直接指定已加载资源的路径会触发
	# "Another resource is loaded from path" 冲突并污染错误缓冲
	# 用 reload() 的返回值判断语法错误(reload 对无效脚本返回非 OK 错误码)
	# 且不做 can_instantiate 检查: 纯工具/抽象类脚本不可实例化并不代表语法错误
	var reload_err := script.reload()
	if reload_err == OK:
		return _ok(JSON.stringify({
			"valid": true,
			"message": "脚本语法有效",
			"error_latin": 0,
			"error_text": "",
		}))
	var text := error_string(reload_err)
	var hint := ""
	if text.contains("hides a global script class"):
		hint = " (class_name 与全局类缓存冲突: 若是新脚本, 先调用 reload_project 刷新类缓存后再试)"
	var msg := "解析失败: %s%s" % [text, hint]
	return _ok(JSON.stringify({
		"valid": false,
		"message": msg,
		"error_line": 0,
		"error_text": text,
		"hint": hint.strip_edges().trim_prefix(" (").trim_suffix(")"),
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
	var recursive: bool = bool(args.get("recursive", false))
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
	var result := _logger.take_logs_since(since)
	var entries: Array = result.entries
	var out: Array = []
	for e in entries:
		if not keyword.is_empty() and keyword not in str(e.message):
			continue
		out.append(e)
		if out.size() >= max:
			break
	return _ok(JSON.stringify({"next": result.next, "count": out.size(), "logs": out}))


func _call_get_errors(args: Dictionary) -> Dictionary:
	if _logger == null:
		return _fail("错误捕获器未就绪")
	var max: int = int(args.get("max", 100))
	var result := _logger.take_errors_since(0)
	var out: Array = result.entries.duplicate()
	if out.size() > max:
		out = out.slice(out.size() - max)
	return _ok(JSON.stringify({"count": out.size(), "errors": out}))


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
	var dir_path := "user://mcp_screenshots"
	var dir := DirAccess.open("user://")
	if dir:
		dir.make_dir_recursive("mcp_screenshots")
	var base: Control = _editor.get_base_control() if _editor else null
	if base == null:
		return _fail("无法获取编辑器基座控件")
	var viewport := base.get_viewport()
	var tree := base.get_tree()
	if viewport == null:
		return _fail("无法获取编辑器视口")
	if tree == null:
		return _fail("编辑器场景树不可用")
	# 等待渲染完成(截图需要 GPU 回读)。关键: 用 tree.process_frame 而非 RenderingServer.frame_post_draw,
	# process_frame 在窗口最小化/被遮挡/headless 时仍会触发, 不会像 frame_post_draw 那样挂起导致 MCP 请求超时;
	# 并附硬性时限兜底, 任何异常情况都在时限内返回。
	await _wait_frames(tree, 3, 2500)
	# 若尚未绘制过(如刚启动/窗口被遮挡), 强制渲染一次最新画面再回读
	RenderingServer.force_draw(false)
	var img: Image = viewport.get_texture().get_image()
	if img == null or img.is_empty():
		return _fail("截图失败: 编辑器视口纹理为空")
	# 可选按最大宽度等比缩小, 控制 AI 视觉读图的分辨率开销
	var max_width := int(args.get("max_width", 0))
	if max_width > 0 and max_width < img.get_width():
		var scale := float(max_width) / float(img.get_width())
		img.resize(max_width, int(img.get_height() * scale), Image.INTERPOLATE_LANCZOS)
	var path := "%s/%s" % [dir_path, filename]
	var err := img.save_png(path)
	if err != OK:
		return _fail("保存截图失败: 错误码 %d" % err)
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(path)
	return _ok(JSON.stringify({
		"path": ProjectSettings.globalize_path(path),
		"res_path": path,
		"width": img.get_width(),
		"height": img.get_height(),
		"bytes": bytes.size() if bytes else 0,
	}))


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
	var include_props: bool = bool(args.get("include_properties", false))
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
		var props: Dictionary = {}
		for p in node.get_property_list():
			var pname: String = str(p.name)
			if p.usage & PROPERTY_USAGE_EDITOR or pname in ["name", "position", "rotation", "scale", "visible", "modulate", "process_mode"]:
				if node.get(pname) != null:
					props[pname] = node.get(pname)
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
		"properties": {},
	}
	for p in node.get_property_list():
		var pname: String = str(p.name)
		if p.usage & PROPERTY_USAGE_EDITOR or pname in ["name", "position", "rotation", "scale", "visible", "process_mode", "modulate"]:
			info.properties[pname] = node.get(pname)
	return _ok(JSON.stringify(info))


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
	var typed := _coerce_value(value, typeof(current))
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
	var result: Variant = node.callv(method, args_arr)
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
	if root == new_node or parent == root:
		new_node.owner = root
	return _ok("已添加节点 %s [%s] 到 %s" % [new_node.name, new_node.get_class(), parent.name])


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
	if _run_pid != 0:
		return _fail("游戏已在运行(PID %d)。如需重启请先 stop_game。" % _run_pid)
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
	var exe := OS.get_executable_path()
	var args_arr := ["--path", ProjectSettings.globalize_path("res://"), "--log-file", ProjectSettings.globalize_path(_run_log_path), scene]
	# 清空旧日志并重置偏移
	var f := FileAccess.open(_run_log_path, FileAccess.WRITE)
	if f:
		f.store_string("")
		f.close()
	_run_log_offset = 0
	var pid := OS.create_process(exe, args_arr)
	if pid <= 0:
		return _fail("启动游戏失败(create_process 返回 %d)" % pid)
	_run_pid = pid
	return _ok("已启动游戏 PID=%d 场景=%s。运行日志已并入 get_logs。" % [pid, scene])


func _call_stop_game(_args: Dictionary) -> Dictionary:
	if _run_pid == 0:
		return _fail("当前没有运行中的游戏")
	var pid := _run_pid
	_run_pid = 0
	OS.kill(pid)
	return _ok("已停止游戏 PID=%d" % pid)


## ======= 开发辅助工具实现 =======

func _call_reload_project(args: Dictionary) -> Dictionary:
	if _editor == null:
		return _fail("编辑器不可用")
	var fs := _editor.get_resource_filesystem()
	if fs == null:
		return _fail("编辑器文件系统不可用")
	var tree := _editor.get_base_control().get_tree()
	if tree == null:
		return _fail("编辑器场景树不可用")
	var reopen: bool = bool(args.get("reopen_scene", false))
	var current := ""
	if _edited_root() != null:
		current = _edited_root().get_scene_file_path()
	# 先重建源文件缓存(新增/修改的 .gd 与 class_name 注册), 再重扫全部资源; 等待后台扫描完成
	fs.scan_sources()
	await _await_scan(fs, tree)
	var sources_done := not fs.is_scanning()
	fs.scan()
	await _await_scan(fs, tree)
	var msg := "已触发项目重载: scan_sources(重建类缓存, 新 class_name 已注册) + scan(重扫资源)。"
	if not sources_done or fs.is_scanning():
		msg += " 注意: 扫描仍在后台进行(新增资源可能需要片刻才能生效)。"
	if reopen and not current.is_empty():
		_editor.open_scene_from_path(current)
		msg += " 已重载当前场景 %s。注意: 未保存修改可能已丢失。" % current
	elif reopen and current.is_empty():
		msg += " 提示: 当前没有打开的场景, 未执行场景重载。"
	return _ok(msg)


## 等待 EditorFileSystem 后台扫描完成。用墙钟时限而非帧数:
## 帧数在低帧率/编辑器卡顿时会远超 MCP 客户端超时, 导致 tools/call 请求超时挂起。
## 每次最多等约 5 秒, 超时立即返回(未完成的扫描留待后台继续, 不影响后续调用)。
func _await_scan(fs: EditorFileSystem, tree: SceneTree) -> void:
	var deadline := Time.get_ticks_msec() + 5000
	while fs.is_scanning() and Time.get_ticks_msec() < deadline:
		await tree.process_frame


func _call_eval_code(args: Dictionary) -> Dictionary:
	var code: String = str(args.get("code", ""))
	if code.is_empty():
		return _fail("必须提供 code")
	var script := GDScript.new()
	# 缩进每个输入行, 组成方法体; 末尾追加 return null 兜底
	var body := code.replace("\n", "\n\t")
	script.source_code = "extends RefCounted\nstatic func _mcp_run():\n\t%s\n\treturn null" % body
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
	if bool(args.get("save", true)):
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


## 每帧调用: 把运行中游戏的日志文件增量合并进 _logger
func _poll_run_log() -> void:
	if _run_pid == 0 or _logger == null:
		return
	if not FileAccess.file_exists(_run_log_path):
		return
	var f := FileAccess.open(_run_log_path, FileAccess.READ)
	if f == null:
		return
	f.seek(_run_log_offset)
	var data := f.get_as_text()
	_run_log_offset = f.get_position()
	f.close()
	if data.is_empty():
		return
	for line in data.split("\n"):
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


## 将传入值转换为目标类型(处理 Vector2/Vector3/Color 等字符串)
func _coerce_value(value: Variant, target_type: int) -> Variant:
	if value is String:
		var s: String = value
		match target_type:
			TYPE_VECTOR2:
				if s.count(",") == 1:
					var parts := s.split(",")
					return Vector2(float(parts[0]), float(parts[1]))
			TYPE_VECTOR3:
				if s.count(",") == 2:
					var parts := s.split(",")
					return Vector3(float(parts[0]), float(parts[1]), float(parts[2]))
			TYPE_COLOR:
				if s.count(",") == 3:
					var parts := s.split(",")
					return Color(float(parts[0]), float(parts[1]), float(parts[2]), float(parts[3]))
			TYPE_INT:
				return int(s)
			TYPE_FLOAT:
				return float(s)
			TYPE_BOOL:
				return s == "true"
	return value