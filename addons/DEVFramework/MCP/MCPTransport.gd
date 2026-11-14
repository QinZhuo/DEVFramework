@tool
extends RefCounted

## ======= HTTP / SSE 传输层 =======
##
## 由 MCPDevServer 以 preload 常量 `MCPTransport` 引用。**必须 @tool 且不声明 class_name**
## （同 MCPResult / MCPRouter / MCPRuntime）。
##
## 边界：只做"字节进、字节出" —— 方法/鉴权/Origin 校验、协议版本协商与逐请求声明校验、
## 旧式 SSE 会话投递、CORS 头。JSON-RPC 方法分派（tools/list、tools/call、resources/*）
## 仍在服务器侧：那部分与工具注册表、多实例转发强耦合。
##
## 协议常量也归这里（服务器 re-export 同名 const，故调用点零改动）——它们描述的是
## "HTTP 头与 _meta 怎么声明版本"，属于传输层语义，不是工具语义。

const MCPFormat := preload("res://addons/DEVFramework/MCP/MCPFormat.gd")

const SETTING_TOKEN := "dev_framework/mcp/token"
const PROTOCOL_VERSION := "2025-03-26"
const SUPPORTED_PROTOCOL_VERSIONS := ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26"]
const META_VERSION_KEY := "io.modelcontextprotocol/protocolVersion"
const META_CLIENT_CAPS_KEY := "io.modelcontextprotocol/clientCapabilities"
const META_REQUIRED_SINCE := "2026-07-28"
const HEADER_VERSION := "mcp-protocol-version"

const ERR_PARSE := -32700
const ERR_INVALID_PARAMS := -32602
const ERR_TRANSPORT_REJECTED := -32000
const ERR_HEADER_MISMATCH := -32020
const ERR_UNSUPPORTED_VERSION := -32022

## MCPDevServer（Variant：跨编译代次不信任类型标注）
var server = null


func _init(owner) -> void:
	server = owner


## HTTP 入口：所有请求（POST / GET / OPTIONS / /hub/*）都从这里进。
func on_request(method: String, path: String, query: String, headers: Dictionary, body: PackedByteArray, stream) -> void:
	# MCP 服务器已关闭时忽略请求（编辑器重启期间）
	if server._http == null:
		return
	if method == "OPTIONS":
		server._http.send_response(stream, 204, _cors_headers(headers), "")
		return
	# 实例间内部端点(/hub/*): 不走 MCP 协议, 也不参与版本协商。
	# 只由中枢应答 —— 成员收到这类请求说明调用方把中枢端口记错了, 回 404 让问题可见。
	if path.begins_with("/hub/"):
		server._serve_hub_path(method, path, headers, body, stream)
		return
	if method == "GET":
		_serve_sse(stream, headers)
		return
	if method != "POST":
		server._send_rpc_error(stream, 405, headers, null, ERR_TRANSPORT_REJECTED, "Method Not Allowed", {}, {"Allow": "POST, GET, OPTIONS"})
		return
	# 鉴权: 可选 Bearer token(dev_framework/mcp/token, 非空时启用)
	var token: String = ProjectSettings.get_setting(SETTING_TOKEN, "")
	if not token.is_empty():
		var auth := str(headers.get("authorization", ""))
		if auth != "Bearer " + token:
			server._send_rpc_error(stream, 401, headers, null, ERR_TRANSPORT_REJECTED, "Unauthorized")
			return
	# 校验 Origin: 拦截浏览器/外部站点的跨域调用(eval_code 可执行任意代码, 防本机 RCE)。
	# 无 Origin(本地 CLI/工具)或本机 Origin 放行。
	var origin := str(headers.get("origin", "")).to_lower()
	if not origin.is_empty() and not (origin.begins_with("http://127.0.0.1") or origin.begins_with("http://localhost") or origin.begins_with("http://0.0.0.0")):
		server._send_rpc_error(stream, 403, headers, null, ERR_TRANSPORT_REJECTED, "Forbidden")
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if parsed == null or not parsed is Dictionary:
		server._send_rpc_error(stream, 400, headers, null, ERR_PARSE, "Parse error")
		return
	var req: Dictionary = parsed
	# 协议版本协商(2026-07-28 起逐请求声明)。两处都缺省才回落 PROTOCOL_VERSION ——
	# 旧客户端两个都不发, 走老握手, 行为与改动前完全一致。
	var proto := str(headers.get(HEADER_VERSION, ""))
	var meta_version := ""
	var rparams: Variant = req.get("params", null)
	var meta := {}
	if rparams is Dictionary:
		var raw_meta: Variant = (rparams as Dictionary).get("_meta", null)
		if raw_meta is Dictionary:
			meta = raw_meta
			meta_version = str(meta.get(META_VERSION_KEY, ""))
	if not meta_version.is_empty() and not proto.is_empty() and meta_version != proto:
		# 规范要求二者必须一致, 不一致直接 400: 放行会让"头说 A 体说 B"的请求按错误版本解析。
		# data 里回两个实际收到的值和可用版本: 客户端据此能自行改对后重试。
		server._send_rpc_error(stream, 400, headers, req.get("id", null), ERR_HEADER_MISMATCH,
			"Header mismatch: %s 与 _meta 声明的版本不一致" % HEADER_VERSION,
			{"supported": SUPPORTED_PROTOCOL_VERSIONS, "header": proto, "meta": meta_version})
		return
	# declared 与 effective 必须分开: declared = 客户端实际声明了什么(只读, 用于一致性与规范判定);
	# effective = 本次按哪一版解析(降级只改它)。把降级结果写回 declared 会让"服务端降级"被当成
	# "客户端声明", 后续 _meta 必填校验就会凭空要求它补一个它从没支持过的字段。
	var declared := proto if not proto.is_empty() else meta_version
	var rpc_method := str(req.get("method", ""))
	var effective := declared
	if not declared.is_empty() and not SUPPORTED_PROTOCOL_VERSIONS.has(declared):
		if rpc_method == "initialize" or not bool(server._version_negotiated):
			# 协商降级而不是报错: 握手期报错等于失联(客户端不会重试、也不会换版本)。
			effective = server._negotiate_version(declared)
			LogTool.log("MCP", "%s 请求的协议版本 %s 不受支持, 协商降级为 %s (支持: %s)" % [rpc_method, declared, effective, str(SUPPORTED_PROTOCOL_VERSIONS)])
		else:
			# 协商完成后仍发陌生版本: 说明它跳过了握手或中途换了版本, 按猜测的版本解析只会错。
			# 这里必须打日志 —— 否则客户端界面报错而服务端日志里既没有这条也没有 POST 记录。
			LogTool.log("MCP", "拒绝 %s: 协议版本 %s 不受支持 (支持: %s)" % [rpc_method, declared, str(SUPPORTED_PROTOCOL_VERSIONS)])
			server._send_rpc_error(stream, 400, headers, req.get("id", null), ERR_UNSUPPORTED_VERSION,
				"Unsupported protocol version",
				{"supported": SUPPORTED_PROTOCOL_VERSIONS, "requested": declared})
			return
	# 2026-07-28 起: 声明了该版本的请求, 其 _meta 必须**同时**带 protocolVersion 与
	# clientCapabilities, 缺任一即 malformed(回 -32602 + HTTP 400)。
	#
	# 刻意用 Invalid params 而不是 ERR_UNSUPPORTED_VERSION: 请求可能完全合法, 只是没说清版本,
	# 客户端把字段补上就能继续。两点收窄避免误伤现有客户端: 只对声明了 META_REQUIRED_SINCE 的
	# 请求生效; 跳过 initialize(它正是用来协商版本的, 要求它先声明版本是循环依赖)。
	# 判定用 declared 而非 effective: 刚被降级到这个版本的客户端不该被要求补 _meta。
	if declared == META_REQUIRED_SINCE and rpc_method != "initialize":
		var missing: Array[String] = []
		if meta_version.is_empty():
			missing.append(META_VERSION_KEY)
		if not meta.has(META_CLIENT_CAPS_KEY):
			missing.append(META_CLIENT_CAPS_KEY)
		if not missing.is_empty():
			server._send_rpc_error(stream, 400, headers, req.get("id", null), ERR_INVALID_PARAMS,
				"Missing required _meta field(s): %s" % ", ".join(missing),
				{"missing": missing, "required": [META_VERSION_KEY, META_CLIENT_CAPS_KEY]})
			return
	# 两处都没声明版本(老客户端)才回落 PROTOCOL_VERSION; 降级过的 effective 本身必是受支持版本
	if effective.is_empty():
		effective = PROTOCOL_VERSION
	# 提前取 sessionId: 旧式 SSE 会话投递的请求要把响应改走 SSE 流, 且日志需与会话对应
	var sid := query_param(query, "sessionId")
	# 默认只记**首次**版本协商那一条; 全量开关打开时才记其余请求。
	# **initialize 必须用 _version_negotiated 收窄**: 客户端每次重连都会重发 initialize,
	# 无条件打会让 IDE 一抖动就是一串同内容日志, 而协商结果并不会每次都变。
	if bool(server._log_rpc) or (rpc_method == "initialize" and not bool(server._version_negotiated)):
		LogTool.log("MCP", "POST %s | 版本 %s | 会话 %s" % [rpc_method, effective, sid if not sid.is_empty() else "-"])
	var response: Dictionary = await server._handle_jsonrpc(req, effective)
	if rpc_method == "initialize" and not response.is_empty():
		server._version_negotiated = true
	# JSON-RPC 通知(无 id)按 MCP 规范回 202 空响应
	if response.is_empty():
		server._http.send_response(stream, 202, {}, "")
		return
	var json := MCPFormat.json_safe(JSON.stringify(response))
	# 旧式 SSE 会话投递的请求: 响应必须回写到它开的那条 SSE 流, POST 上只回 202。
	# 若直接在 POST 上回 JSON, 旧式客户端永远读不到响应(它不读 POST 的 body),
	# 现象是"显示已连接但所有工具都超时"。会话已失效时才降级回 Streamable HTTP 直回。
	if server._http.has_sse_session(sid):
		if server._http.send_sse_message(sid, json):
			server._http.send_response(stream, 202, {}, "")
			return
		LogTool.log("MCP", "旧式 SSE 会话 %s 已失效, 降级为 Streamable HTTP 直回" % sid)
	server._http.send_response(stream, 200, _cors_headers(headers), json)


## GET /mcp → 开启旧式 HTTP+SSE 会话。
##
## 规范要求新旧两个端点并存: POST 走 Streamable HTTP, GET 走旧式 SSE。未声明 transportType 的
## 客户端默认按旧式 SSE 连接, 会先 GET 等 endpoint 事件 —— 对 GET 回 405 时它**直接放弃**,
## 一次 POST 都不发, 界面永远停在"连接中"(实测)，所以这里必须真把流开出来。
func _serve_sse(stream, headers: Dictionary) -> void:
	var endpoint := _endpoint_url()
	# 已完成握手的客户端走 Streamable HTTP, 它此刻开的流只是通知/保活通道, 永不承载请求 ——
	# 若套上未使用回收就会把它当废弃流掐断, 客户端随即重开, 形成"断流-重连"死循环。
	var sid: String = server._http.open_legacy_sse(stream, _sse_headers(headers), endpoint, not bool(server._version_negotiated))
	if sid.is_empty():
		# 开不了流(并发已满/连接已断) → 回 405, 客户端仍可退回纯 Streamable HTTP
		server._send_rpc_error(stream, 405, headers, null, ERR_TRANSPORT_REJECTED, "Method Not Allowed", {}, {"Allow": "POST, GET, OPTIONS"})
		return
	# 默认**不记**这条: 客户端每次重连都会走一遍这里, 实测 IDE 抖动就是一串同内容日志。
	# 要记就只取 sid 前 8 位 —— 完整 uuid 没有可读价值, 却会挤掉后面的诊断信息。
	if bool(server._log_rpc):
		LogTool.log("MCP", "GET /mcp 通告 endpoint=%s, 会话 %s" % [endpoint, sid.substr(0, 8)])


## SSE 响应头。与 _cors_headers 分开: 那里是"一次 JSON-RPC 往返"的响应头(带 Mcp-Session-Id),
## 这里开的是旧式 SSE 流, 身份由通告出去的 endpoint 里的 sessionId 决定, 再附会话头只会误导客户端。
func _sse_headers(headers: Dictionary) -> Dictionary:
	var h := {
		"Access-Control-Allow-Methods": "POST, GET, OPTIONS",
		"Access-Control-Allow-Headers": "Authorization, Content-Type, Mcp-Session-Id",
	}
	var origin := str(headers.get("origin", ""))
	if not origin.is_empty():
		h["Access-Control-Allow-Origin"] = origin
	return h


## 通告给旧式客户端的 POST 地址。必须绝对 URL: 部分旧客户端原样使用它, 相对路径会被当成不可用。
func _endpoint_url() -> String:
	return "http://127.0.0.1:%d/mcp" % server._http.get_port()


## 从 query 串取参数值(键名大小写不敏感)。旧式 SSE 传输把 sessionId 放在 query 上。
static func query_param(query: String, key: String) -> String:
	for pair in query.split("&", false):
		var kv := pair.split("=", true, 1)
		if kv.size() == 2 and kv[0].strip_edges().to_lower() == key.to_lower():
			return kv[1].uri_decode()
	return ""


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
