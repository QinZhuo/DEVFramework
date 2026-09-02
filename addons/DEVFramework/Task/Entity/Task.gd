@abstract
## 任务实体抽象基类。子类：SignalTask（信号驱动）、GroupTask（分组）。
##
## 存档约定: save_data() 只存"Def 路径 + 完成状态", 不存运行时信号连接。
## 读档用 Task.restore(dict, data) 一步重建(含子任务树), 或 task.load_data(dict) 就地恢复。
class_name Task extends Entity

var def: TaskDef:
	set(value):
		def = value
		entity_changed.emit()

signal completed()
## 进度变化(子任务推进/计数累加) —— 供 UI(进度条/"第 2/5 步")刷新。
## 与 entity_changed 的区别: 后者表示"当前指向的 def 变了", 前者表示"完成进度变了"。
signal progress_changed()

var is_completed: bool = false

var _data
var _handler: Callable
var _active: bool = false


static func create(task_def: TaskDef) -> Task:
	return task_def.create_entity()


## 由存档重建任务实体(含 def 与子任务结构), 无需先 activate。
## [param dict] save_data() 的返回值
## [param data] 可选上下文; 提供则立即激活到存档进度, 否则由调用方稍后 activate(data)(会从存档进度继续, 不重跑已完成步骤)
## [return] 还原出的任务; def 缺失或资源加载失败返回 null
static func restore(dict: Dictionary, data = null) -> Task:
	var task_def := _def_from_data(dict)
	if task_def == null:
		LogTool.warn("任务", "存档中的 def 无法还原, 丢弃该任务: ", dict.get("def", ""))
		return null
	var task := create(task_def)
	task.load_data(dict, data)
	return task


## 激活（子类覆写具体逻辑）
func activate(data) -> void:
	if _active:
		deactivate()
	_active = true
	_data = data

## 停用
func deactivate() -> void:
	if not _active:
		return
	_active = false
	if _handler.is_valid():
		_handler = Callable()

## 手动完成
func complete() -> void:
	if is_completed:
		return
	is_completed = true
	deactivate()
	completed.emit()

## 当前描述的文本
func get_current_desc() -> String:
	return def.get_desc(null)

## 完成进度: x = 已完成数, y = 总数。无子进度的任务为 0/1 或 1/1。
func get_progress() -> Vector2i:
	return Vector2i(1 if is_completed else 0, 1)

## 序列化
func save_data() -> Dictionary:
	return {def = _def_to_data(), is_completed = is_completed}

## 反序列化(就地恢复到存档进度; def 由 restore() 负责还原, 这里不动)。
## [param dict] save_data() 的返回值
## [param data] 上下文; 为空时沿用 activate() 传入的上下文(可先载档、后激活)
func load_data(dict: Dictionary, data = null) -> void:
	if data != null:
		_data = data
	is_completed = dict.get("is_completed", false)


# --- 存档辅助 ---

## Def → 存档值(相对 res://Assets/Def/ 的短路径; 无路径的内置 Def 无法还原)
func _def_to_data():
	if def == null:
		return ""
	if def.resource_path.is_empty():
		# 运行时 new 出来 / 内嵌 SubResource 的 Def 没有资源路径, 存档后无法还原
		LogTool.warn("任务", "Def 无资源路径, 存档后无法还原: ", def)
		return ""
	return def.save_data()

## 存档值 → TaskDef(兼容直接内嵌 Def 对象与路径两种写法)
static func _def_from_data(dict: Dictionary) -> TaskDef:
	var raw = dict.get("def")
	if raw is TaskDef:
		return raw
	if raw is String and not (raw as String).is_empty():
		return Def.load_data(raw) as TaskDef
	return null
