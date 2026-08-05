@tool
## MCP 日志与错误捕获器 — 继承 Godot 4.5+ 的 Logger
## 捕获引擎内所有 print 消息(_log_message)与错误(含 GDScript 栈追踪 _log_error)
## 采用线程安全(Mutex)环形缓冲, 供 MCP 工具读取
class_name MCPLogger extends Logger

const CAPACITY := 2000        # 环形缓冲容量(日志条目数)
const ERROR_CAPACITY := 500   # 错误条目容量(含栈追踪, 占空间)

## 日志条目结构: {"time":int毫秒, "message":String, "is_error":bool}
var _messages: Array = []
var _errors: Array = []
var _base_index := 0          # 已从 _messages 头部丢弃的逻辑消息数(环形缓冲逻辑索引)
var _msg_index := 0
var _err_index := 0
var _mutex := Mutex.new()


func _init() -> void:
	pass


## 由 _log_message 调用 — 捕获普通 print / printerr(text流)
func _log_message(message: String, error: bool) -> void:
	_mutex.lock()
	if error:
		# printerr 输出也计入错误列表末尾, 方便统一查看
		_push_error({"time": Time.get_ticks_msec(), "message": _strip_ansi(message), "is_error": true, "type": "stderr", "stack": []})
	else:
		_messages.append({"time": Time.get_ticks_msec(), "message": _strip_ansi(message), "is_error": false})
		if _messages.size() > CAPACITY:
			_messages.pop_front()
			_base_index += 1
	_mutex.unlock()


## 由 _log_error 调用(捕获 push_error/脚本错误/assert 等, 含栈追踪)
func _log_error(
		function: String,
		file: String,
		line: int,
		code: String,
		rationale: String,
		editor_notify: bool,
		error_type: int,
		script_backtraces: Array[ScriptBacktrace]
) -> void:
	var bt_texts: Array = []
	for bt in script_backtraces:
		var lines: Array = []
		for i in bt.get_frame_count():
			var label: String = bt.get_frame_function(i)
			var src: String = bt.get_frame_file(i)
			var ln: int = bt.get_frame_line(i)
			lines.append("    at %s (%s:%d)" % [label, src, ln])
		bt_texts.append({"language": bt.get_language_name(), "frames_raw": bt.format(), "lines": lines})
	_mutex.lock()
	_push_error({
		"time": Time.get_ticks_msec(),
		"message": rationale if not rationale.is_empty() else code,
		"type": _error_type_name(error_type),
		"function": function,
		"file": file,
		"line": line,
		"code": code,
		"stack": bt_texts,
	})
	_mutex.unlock()


func _error_type_name(t: int) -> String:
	match t:
		Logger.ErrorType.ERROR_TYPE_WARNING: return "warning"
		Logger.ErrorType.ERROR_TYPE_SCRIPT: return "script_error"
		Logger.ErrorType.ERROR_TYPE_SHADER: return "shader_error"
	return "error"


func _push_error(entry: Dictionary) -> void:
	_errors.append(entry)
	if _errors.size() > ERROR_CAPACITY:
		_errors.pop_front()


## 剥离 ANSI 转义序列(颜色码等)。这些控制字符会被 JSON.stringify 原样输出,
## 导致 MCP 工具返回非法 JSON。捕获时统一清洗, 保证 get_logs/get_errors 输出合法。
func _strip_ansi(text: String) -> String:
	if not text.contains(String.chr(27)):
		return text
	var out := ""
	var i := 0
	var len := text.length()
	while i < len:
		var c := text.unicode_at(i)
		if c == 27:
			i += 1
			if i < len and text.unicode_at(i) == 91:
				# CSI 序列: ESC [ 参数… 最终字节(0x40-0x7E)
				i += 1
				while i < len:
					var cc := text.unicode_at(i)
					if cc >= 64 and cc <= 126:
						i += 1
						break
					i += 1
			# 其它 ESC 起始序列直接跳过 ESC 本身
			continue
		out += String.chr(c)
		i += 1
	return out


## 获取新增日志(自 last_index 起), 返回 [entries, new_index]
## 环形缓冲容量满后头部被丢弃, 用逻辑索引(_base_index + 数组偏移)保证增量语义稳定
func take_logs_since(last_index: int) -> Dictionary:
	return _take_filtered(last_index, true, "", false)


## 获取新增日志并过滤: keyword 匹配消息文本(空=不过滤), errors_only=true 只返回错误流
func take_logs_filtered(last_index: int, keyword: String, errors_only: bool) -> Dictionary:
	return _take_filtered(last_index, true, keyword, errors_only)


## 获取新增错误
func take_errors_since(last_index: int) -> Dictionary:
	return _take_filtered(last_index, false, "", false)


## 获取新增错误并过滤: keyword 匹配 message/code/file
func take_errors_filtered(last_index: int, keyword: String) -> Dictionary:
	return _take_filtered(last_index, false, keyword, false)


func _take_filtered(last_index: int, is_log: bool, keyword: String, errors_only: bool) -> Dictionary:
	_mutex.lock()
	var kw := keyword.strip_edges().to_lower()
	var new_entries: Array = []
	var start := last_index
	var src: Array
	if is_log:
		start = maxi(last_index, _base_index)
		src = _messages
	else:
		src = _errors
	for i in range(start, src.size() + ( _base_index if is_log else 0 )):
		var entry: Dictionary = src[i - _base_index if is_log else i]
		if is_log:
			if errors_only and not entry.get("is_error", false):
				continue
			if not kw.is_empty() and not str(entry.get("message", "")).to_lower().contains(kw):
				continue
		else:
			if not kw.is_empty():
				var hay := "%s %s %s" % [
					entry.get("message", ""), entry.get("code", ""), entry.get("file", "")]
				if not hay.to_lower().contains(kw):
					continue
		new_entries.append(entry)
	var next_index := (_base_index + _messages.size()) if is_log else _errors.size()
	var result := {"entries": new_entries, "next": next_index, "cleared": _errors.is_empty()}
	_mutex.unlock()
	return result


## 清空错误缓冲区(调试复位用)
func clear_errors() -> void:
	_mutex.lock()
	_errors.clear()
	_mutex.unlock()


func clear_messages() -> void:
	_mutex.lock()
	_messages.clear()
	_base_index = 0
	_mutex.unlock()


## 供运行游戏日志合并(带来源前缀), 线程安全
func append_external(message: String, prefix: String = "[运行] ") -> void:
	_mutex.lock()
	_messages.append({"time": Time.get_ticks_msec(), "message": prefix + _strip_ansi(message), "is_error": false})
	if _messages.size() > CAPACITY:
		_messages.pop_front()
		_base_index += 1
	_mutex.unlock()


func get_message_count() -> int:
	_mutex.lock()
	var n := _messages.size()
	_mutex.unlock()
	return n


func get_error_count() -> int:
	_mutex.lock()
	var n := _errors.size()
	_mutex.unlock()
	return n


## 公开清洗接口: 供 MCP 工具在输出 JSON 前兜底剥离控制字符
func sanitize(message: String) -> String:
	return _strip_ansi(message)