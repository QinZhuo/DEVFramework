## 分组任务实体 — 由 GroupTaskDef 驱动，管理多个子任务完成。
class_name GroupTask extends Task

var _child_entities: Array[Task] = []
var _active_child_index: int = 0
var _completed_count: int = 0


func activate(data) -> void:
	super(data)
	if is_completed:
		return
	# 已有子实体时(重复 activate / 先 load_data 后 activate)从存档进度继续, 不重建子任务
	if _child_entities.is_empty():
		_activate_children(data)
	else:
		_resume_children(data)

func deactivate() -> void:
	for child in _child_entities:
		child.deactivate()
	super()

func get_current_desc() -> String:
	if _active_child_index < _child_entities.size():
		return _child_entities[_active_child_index].get_current_desc()
	return def.get_desc(null)

func get_progress() -> Vector2i:
	return Vector2i(_completed_count, _child_entities.size())

## 当前活跃子任务的 def
var active_child_def: TaskDef:
	get:
		var group := def as GroupTaskDef
		if not group or _active_child_index >= _child_entities.size():
			return null
		return group.tasks[_active_child_index]

## 当前活跃子任务实体
var active_child_entity: Task:
	get:
		if _active_child_index >= _child_entities.size():
			return null
		return _child_entities[_active_child_index]


func _activate_children(data) -> void:
	var group := def as GroupTaskDef
	if not group:
		return
	for i in group.tasks.size():
		var sub_def: TaskDef = group.tasks[i]
		var child := Task.create(sub_def)
		_child_entities.append(child)
		child.completed.connect(_on_child_completed.bind(i))
		if group.mode == GroupTaskDef.Mode.SEQUENTIAL and i > 0:
			continue
		child.activate(data)
		if group.mode == GroupTaskDef.Mode.COMPLETE_ANY:
			break

## 从当前进度恢复子任务激活(只激活"该激活的"那几个, 已完成的不重跑)
func _resume_children(data) -> void:
	var group := def as GroupTaskDef
	if not group:
		return
	match group.mode:
		GroupTaskDef.Mode.SEQUENTIAL:
			if _active_child_index < _child_entities.size():
				_child_entities[_active_child_index].activate(data)
		GroupTaskDef.Mode.ANY_ORDER:
			for child in _child_entities:
				if not child.is_completed:
					child.activate(data)
		GroupTaskDef.Mode.COMPLETE_ANY:
			# 原语义: 只激活首个未完成的子任务, 任一完成即结束
			for child in _child_entities:
				if not child.is_completed:
					child.activate(data)
					break

func _on_child_completed(child_index: int) -> void:
	var group := def as GroupTaskDef
	if not group:
		return
	_completed_count += 1
	match group.mode:
		GroupTaskDef.Mode.SEQUENTIAL:
			_active_child_index = child_index + 1
			if _active_child_index < _child_entities.size():
				_child_entities[_active_child_index].activate(_data)
			else:
				complete()
		GroupTaskDef.Mode.ANY_ORDER:
			if _completed_count >= _child_entities.size():
				complete()
		GroupTaskDef.Mode.COMPLETE_ANY:
			complete()
	entity_changed.emit()
	progress_changed.emit()

func save_data() -> Dictionary:
	var dict: Dictionary = {
		def = _def_to_data(),
		is_completed = is_completed,
		children = [],
	}
	for child in _child_entities:
		dict.children.append(child.save_data())
	return dict

func load_data(dict: Dictionary, data = null) -> void:
	if data != null:
		_data = data
	is_completed = dict.get("is_completed", false)
	var children: Array = dict.get("children", [])
	_ensure_children()                      # 按 def 建齐子实体(幂等, 重复调用不重建)
	for i in children.size():
		if i < _child_entities.size():
			_child_entities[i].load_data(children[i])
	_recompute_progress()
	if _active_child_index >= _child_entities.size() and not is_completed:
		complete()          # 子任务已全部完成(或空组): 收尾, 与 _on_child_completed 一致
	if is_completed:
		entity_changed.emit()
		progress_changed.emit()
		return
	# 上下文尚未提供时只恢复数据, 等调用方 activate(data) 由 _resume_children 从进度继续
	if _data != null:
		for child in _child_entities:
			child.deactivate()
		_child_entities[_active_child_index].activate(_data)
	entity_changed.emit()
	progress_changed.emit()


## 按 def 建立缺失的子实体(已存在则复用, 保证 activate/load_data 可重复调用)
func _ensure_children() -> void:
	var group := def as GroupTaskDef
	if not group:
		return
	for i in group.tasks.size():
		if i < _child_entities.size():
			continue
		var child := Task.create(group.tasks[i])
		_child_entities.append(child)
		child.completed.connect(_on_child_completed.bind(i))

## 依据子任务完成状态重算进度游标(游标 = 首个未完成子任务; 全完成时为 size)
func _recompute_progress() -> void:
	_completed_count = 0
	_active_child_index = _child_entities.size()
	for i in _child_entities.size():
		if _child_entities[i].is_completed:
			_completed_count += 1
		elif _active_child_index == _child_entities.size():
			_active_child_index = i
