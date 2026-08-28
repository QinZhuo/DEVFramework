## 教程工具 — 纯静态: 桥接 Task 流程 ⇄ TutorialGuide 表现, 无 Node 生命周期。
##
## 完全外部调用管理(对齐 Task 系统): 项目自己持有 Guide(挂自己的 UI 树)与 task(RefCounted),
## 本类只提供"播放桥接 + 渲染封装"的静态方法, 不创建也不管理任何场景树节点。
##
## 典型用法(便利路径, play 自动创建 layer+guide 挂 host):
##   var task: GroupTask = TutorialTool.play(flow, self, {"theme": theme})
##   task.completed.connect(_on_finish)
##
## 完全外部路径(Guide 由项目自己挂载管理):
##   var layer := CanvasLayer.new(); add_child(layer)
##   var guide := TutorialGuide.new(); guide.set_anchors_preset(Control.PRESET_FULL_RECT); layer.add_child(guide)
##   guide.hole_clicked.connect(func(): TutorialTool.on_hole_clicked(task, guide))
##   var task: GroupTask = TutorialTool.play(flow, self, {}, guide)
##
## 播放生命周期全部由外部驱动: task.entity_changed / task.completed 已由 play 桥接到 guide 渲染。
class_name TutorialTool


## 开始播放: 创建任务实体并桥接"Task 推进 → Guide 渲染"。
## [param flow] 教程流程(GroupTaskDef, 步骤为 TutorialStepDef; SEQUENTIAL)
## [param host] 教程宿主(目标路径/信号解析相对它)
## [param opts] {skippable, pause_tree, theme, guide_scene}
## [param guide] 外部 Guide(空 = 自动创建 TutorialLayer + TutorialGuide 挂到 host)
## [return] GroupTask 实体(RefCounted, 由外部持有; 完成时自动 blur guide 并恢复暂停)
static func play(flow: GroupTaskDef, host: Node, opts: Dictionary = {}, guide: TutorialGuide = null) -> GroupTask:
	if guide == null:
		guide = _make_guide(host, opts)
	var task := flow.create_entity() as GroupTask
	task.entity_changed.connect(_dispatch_step.bind(task, guide, host))
	task.completed.connect(_finish.bind(task, guide, host, opts))
	if opts.get("pause_tree", false):
		host.get_tree().paused = true
		guide.process_mode = Node.PROCESS_MODE_ALWAYS
	task.activate(_make_context(host))
	_dispatch_step(task, guide, host)
	return task


## 创建并挂载默认 TutorialGuide(挂到 host 下的 TutorialLayer)
static func _make_guide(host: Node, opts: Dictionary) -> TutorialGuide:
	var layer := CanvasLayer.new()
	layer.name = "TutorialLayer"
	layer.layer = 100
	host.add_child(layer)
	var guide: TutorialGuide
	var guide_scene: PackedScene = opts.get("guide_scene")
	if guide_scene:
		guide = guide_scene.instantiate()
	else:
		guide = TutorialGuide.new()
	guide.name = "TutorialGuide"
	var theme: Theme = opts.get("theme")
	if theme:
		guide.theme = theme
	guide.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(guide)
	return guide


## 任务上下文(目标/信号解析用)
static func _make_context(host: Node) -> Dictionary:
	return {"root": host}


## 桥接: Task 推进信号 → 渲染当前步骤到 Guide
static func _dispatch_step(task: GroupTask, guide: TutorialGuide, host: Node) -> void:
	if task.is_completed:
		guide.blur()
		return
	var step := task.active_child_entity
	if step and not step.is_completed:
		render_step(guide, step, host)


## 渲染单个步骤到 Guide(外部手动桥接时也可直接调用)
static func render_step(guide: TutorialGuide, step: Task, host: Node) -> void:
	var step_def := step.def as TutorialStepDef
	guide.blur()
	var target: Node = null
	if step_def and step_def.target:
		target = step_def.target.resolve(host)
	guide.focus(target, step_def.target if step_def else null,
			step_def.block_input if step_def else true,
			step_def.click_to_complete if step_def else false,
			tip_text(step, step_def))


## 提示文本: 步骤 def 的 tip_text 优先, 否则用翻译描述(tr(名称_desc))
static func tip_text(step: Task, step_def: TutorialStepDef) -> String:
	if step_def and not step_def.tip_text.is_empty():
		return step_def.tip_text
	return step.get_current_desc()


## 当前活跃步骤(无则 null)
static func current_step(task: GroupTask) -> Task:
	return task.active_child_entity if task else null


## 跳过当前步骤(task 的 skippable 由调用方判定后调用)
static func skip(task: GroupTask) -> void:
	var step := current_step(task)
	if step:
		step.complete()


## Guide 孔内点击(click_to_complete 步骤的完成兜底; 需外部连接 guide.hole_clicked)
static func on_hole_clicked(task: GroupTask, guide: TutorialGuide) -> void:
	var step := current_step(task)
	if step == null:
		return
	var step_def := step.def as TutorialStepDef
	if step_def and step_def.click_to_complete:
		step.complete()


## 完成清理: 隐藏 Guide + 恢复暂停
static func _finish(task: GroupTask, guide: TutorialGuide, host: Node, opts: Dictionary) -> void:
	guide.blur()
	if opts.get("pause_tree", false):
		host.get_tree().paused = false