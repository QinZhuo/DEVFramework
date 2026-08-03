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
		_append_error({"time": Time.get_ticks_msec(), "message": message, "is_error": true, "type": "stderr", "stack": []})
	else:
		_messages.append({"time": Time.get_ticks_msec(), "message": message, "is_error": false})
		if _messages.size() > CAPACITY:
			_messages.pop_front()
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


## 获取新增日志(自 last_index 起), 返回 [entries, new_index]
## 供工具轮询增量读取
func take_logs_since(last_index: int) -> Dictionary:
	_mutex.lock()
	var new_entries: Array = []
	for i in range(last_index, _messages.size()):
		new_entries.append(_messages[i])
	var result := {"entries": new_entries, "next": _messages.size()}
	_mutex.unlock()
	return result


## 获取新增错误
func take_errors_since(_last_index: int) -> Dictionary:
	_mutex.lock()
	var n := _errors.size()
	var result := {"entries": _errors.duplicate(), "next": n, "cleared": _errors.is_empty()}
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