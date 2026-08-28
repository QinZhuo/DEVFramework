## 教程运行器 — 播放任意 GroupTaskDef(纯任务树), 驱动 TutorialGuide 控件表现。
##
## 流程完全复用任务系统: 步骤 = TutorialStepDef(继承 SignalTaskDef, 信号触发即完成),
## 其 target/tip/拦截字段是表现配置; TutorialTool 只做"观察 GroupTask 推进 + 驱动 TutorialGuide"。
## 播放选项(skippable/pause_tree/theme/guide_scene)由 opts 指定; 存档复用 Task 系统, 由项目接入。
##
## 用法:
##   TutorialTool.start(flow, host, opts)
##     flow: GroupTaskDef, 步骤为 TutorialStepDef(SEQUENTIAL)
##     opts: {skippable: true, pause_tree: false,
##            guide_scene: PackedScene(TutorialGuide 子类), theme: Theme}
##   tool.step_changed.connect(...)
##   tool.tutorial_completed.connect(...)
##   tool.skip()                    # opts.skippable 时生效
##   tool.save_data()/load_data()   # 复用 Task 系统存档
class_name TutorialTool extends Node

## 当前步骤切换(已激活且未完成)
signal step_changed(step: Task)
## 教程完成(含跳完最后一步)
signal tutorial_completed()

var _flow: GroupTaskDef
var _opts: Dictionary
var _context: Dictionary
var _task: GroupTask
var _guide: TutorialGuide
var _prev_paused := false


## 启动教程(host 为教程宿主, 目标路径/信号解析均相对它; context 额外上下文传给 SignalDef)
static func start(flow: GroupTaskDef, host: Node, opts: Dictionary = {}, context: Dictionary = {}) -> TutorialTool:
	var tool := TutorialTool.new()
	tool.name = "TutorialTool"
	tool._flow = flow
	tool._opts = opts
	tool._context = context
	host.add_child(tool)
	return tool


func _ready() -> void:
	_setup_guide()
	var data := _context.duplicate()
	data["root"] = get_parent()
	data["tutorial"] = self
	_task = _flow.create_entity() as GroupTask
	_task.entity_changed.connect(_on_task_changed)
	_task.completed.connect(_on_completed)
	if _opts.get("pause_tree", false):
		_prev_paused = get_tree().paused
		get_tree().paused = true
		process_mode = Node.PROCESS_MODE_ALWAYS
	_task.activate(data)
	_on_task_changed()


## 当前活跃步骤(无则 null)
func current_step() -> Task:
	return _task.active_child_entity if _task else null


## 跳过当前步骤(opts.skippable 时生效)
func skip() -> void:
	if not _opts.get("skippable", true):
		return
	var step := current_step()
	if step:
		step.complete()


## 导出进度(复用 Task 系统存档, 供项目存档系统整合)
func save_data() -> Dictionary:
	return _task.save_data() if _task else {}


## 恢复进度(复用 Task 系统存档)
func load_data(dict: Dictionary) -> void:
	if _task:
		_task.load_data(dict)


func _setup_guide() -> void:
	var layer := CanvasLayer.new()
	layer.name = "TutorialLayer"
	layer.layer = 100
	add_child(layer)
	var guide_scene: PackedScene = _opts.get("guide_scene")
	if guide_scene:
		_guide = guide_scene.instantiate()
	else:
		_guide = TutorialGuide.new()
	_guide.name = "TutorialGuide"
	var theme: Theme = _opts.get("theme")
	if theme:
		_guide.theme = theme
	_guide.set_anchors_preset(Control.PRESET_FULL_RECT)
	_guide.hole_clicked.connect(_on_hole_clicked)
	layer.add_child(_guide)


func _on_task_changed() -> void:
	if _task == null or _task.is_completed:
		return
	var step := current_step()
	if step and not step.is_completed:
		_show_step(step)


func _show_step(step: Task) -> void:
	var step_def := step.def as TutorialStepDef
	_guide.blur()
	var target: Node = null
	if step_def and step_def.target:
		target = step_def.target.resolve(get_parent())
	var tip_text := _tip_text(step, step_def)
	_guide.focus(target, step_def.target if step_def else null,
			step_def.block_input if step_def else true,
			step_def.click_to_complete if step_def else false, tip_text)
	step_changed.emit(step)


## 提示文本: 步骤 def 的 tip_text 优先, 否则用翻译描述(tr(名称_desc))
func _tip_text(step: Task, step_def: TutorialStepDef) -> String:
	if step_def and not step_def.tip_text.is_empty():
		return step_def.tip_text
	return step.get_current_desc()


func _on_hole_clicked() -> void:
	var step := current_step()
	if step == null:
		return
	var step_def := step.def as TutorialStepDef
	if step_def and step_def.click_to_complete:
		step.complete()


func _on_completed() -> void:
	_guide.blur()
	if _opts.get("pause_tree", false):
		get_tree().paused = _prev_paused
	tutorial_completed.emit()
	queue_free()