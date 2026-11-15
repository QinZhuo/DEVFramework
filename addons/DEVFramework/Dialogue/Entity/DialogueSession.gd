## 一次对话的运行实例: 游标 + 推进 + 生命周期。
##
## 只发信号, 不碰任何 UI —— 表现层(View/DialoguePresenter)订阅它。
class_name DialogueSession extends RefCounted

## 开播(带第一行)
signal started(line: DialogueLineDef)
## 换行
signal line_changed(line: DialogueLineDef, index: int)
## 整段播完(非 loop)
signal finished
## 被外部中止
signal cancelled

var script: DialogueScriptDef
var index := -1
var is_running := false

## 播放上下文(项目自定义: 玩家/商店/教程步骤 ...), presenter 可读取
var context := {}


func _init(dialogue_script: DialogueScriptDef = null) -> void:
	script = dialogue_script


func start(ctx: Dictionary = {}) -> bool:
	if script == null or script.is_empty():
		return false
	context = ctx
	index = 0
	is_running = true
	started.emit(current())
	line_changed.emit(current(), index)
	return true


func current() -> DialogueLineDef:
	if script == null or index < 0 or index >= script.lines.size():
		return null
	return script.lines[index]


func current_text() -> String:
	var line := current()
	return line.get_display_text() if line else ""


## 推进到下一行; 返回是否还有下一行(播完返回 false 并 emit finished)
func advance() -> bool:
	if not is_running:
		return false
	index += 1
	if script != null and index < script.lines.size():
		line_changed.emit(current(), index)
		return true
	if script != null and script.loop and not script.lines.is_empty():
		index = 0
		line_changed.emit(current(), index)
		return true
	is_running = false
	finished.emit()
	return false


func cancel() -> void:
	if not is_running:
		return
	is_running = false
	cancelled.emit()


func is_finished() -> bool:
	return not is_running
