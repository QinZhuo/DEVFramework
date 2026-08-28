## 教程运行器 — 播放任意 GroupTaskDef(纯任务树), 驱动遮罩/箭头/提示等表现层。
##
## 流程完全复用任务系统: 步骤 = TutorialStepDef(继承 SignalTaskDef, 信号触发即完成),
## 其 target/tip/拦截字段是表现配置; TutorialTool 只做"观察 GroupTask 推进 + 渲染当前步骤表现"。
## 播放选项(skippable/pause_tree/自定义视图)由 opts 指定; 存档复用 Task 系统, 由项目接入。
##
## 用法:
##   TutorialTool.start(flow, host, opts)
##     flow: GroupTaskDef, 步骤为 TutorialStepDef(SEQUENTIAL)
##     opts: {skippable: true, pause_tree: false,
##            overlay_scene/tip_scene/arrow_scene: PackedScene}
##   tool.step_changed.connect(...)
##   tool.tutorial_completed.connect(...)
##   tool.skip()                    # opts.skippable 时生效
##   tool.save_data()/load_data()   # 复用 Task 系统存档
class_name TutorialTool extends Node

## 当前步骤切换(已激活且未完成)
signal step_changed(step: Task)
## 教程完成(含跳完最后一步)
signal tutorial_completed()

const DEFAULT_OVERLAY := preload("res://addons/DEVFramework/Task/View/TutorialOverlay.tscn")
const DEFAULT_TIP := preload("res://addons/DEVFramework/Task/View/TutorialTip.tscn")
const DEFAULT_ARROW := preload("res://addons/DEVFramework/Task/View/TutorialArrow.tscn")

var _flow: GroupTaskDef
var _opts: Dictionary
var _context: Dictionary
var _task: GroupTask
var _overlay: TutorialOverlay
var _tip: TutorialTip
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
	_setup_views()
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


func _process(_delta: float) -> void:
	if _tip and _tip.visible:
		var vp_size := get_viewport().get_visible_rect().size
		_tip.place(_overlay.get_hole_rect(), vp_size)


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


func _setup_views() -> void:
	var overlay_scene: PackedScene = _opts.get("overlay_scene")
	_overlay = (overlay_scene if overlay_scene else DEFAULT_OVERLAY).instantiate()
	_overlay.hole_clicked.connect(_on_hole_clicked)
	add_child(_overlay)
	var arrow_scene: PackedScene = _opts.get("arrow_scene")
	_overlay.set_arrow((arrow_scene if arrow_scene else DEFAULT_ARROW).instantiate())
	var tip_scene: PackedScene = _opts.get("tip_scene")
	_tip = (tip_scene if tip_scene else DEFAULT_TIP).instantiate()
	_overlay.add_child(_tip)


func _on_task_changed() -> void:
	if _task == null or _task.is_completed:
		return
	var step := current_step()
	if step and not step.is_completed:
		_show_step(step)


func _show_step(step: Task) -> void:
	var step_def := step.def as TutorialStepDef
	_overlay.blur()
	var target: Node = null
	if step_def and step_def.target:
		target = step_def.target.resolve(get_parent())
	_overlay.focus(target, step_def.target if step_def else null,
			step_def.block_input if step_def else true,
			step_def.click_to_complete if step_def else false)
	_tip.show_tip(_tip_text(step, step_def))
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
	_overlay.blur()
	_tip.visible = false
	if _opts.get("pause_tree", false):
		get_tree().paused = _prev_paused
	tutorial_completed.emit()
	queue_free()