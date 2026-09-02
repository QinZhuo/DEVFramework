class_name test_tutorial
extends TestCase

## 教程模块回归 — TutorialStepDef(继承 SignalTaskDef)表现配置 + 纯 Task 外部驱动(无运行器)。


func test_screen_rect_control() -> void:
	# Control 目标的屏幕矩形换算(遮罩挖孔的几何基础)
	var tree := Engine.get_main_loop() as SceneTree
	var ctrl := Control.new()
	tree.root.add_child(ctrl)
	ctrl.position = Vector2(100, 80)
	ctrl.size = Vector2(200, 100)
	await tree.process_frame
	var rect := TutorialTargetDef.get_screen_rect(ctrl)
	assert_true(rect.position.is_equal_approx(Vector2(100, 80)) \
			and rect.size.is_equal_approx(Vector2(200, 100)),
			"Control 屏幕矩形应与布局一致, 实际: %s" % rect)
	ctrl.queue_free()


func test_step_completes_on_node_signal() -> void:
	# 外部驱动: 纯 Task, 完成条件 = SignalTask + NodeSignalDef 订阅 Button.pressed
	var tree := Engine.get_main_loop() as SceneTree
	var host := Node.new()
	host.name = "TutHost"
	tree.root.add_child(host)
	await tree.process_frame
	var btn := Button.new()
	btn.name = "Btn"
	host.add_child(btn)
	await tree.process_frame

	var sig := NodeSignalDef.new()
	sig.node_path = NodePath("Btn")
	sig.signal_name = &"pressed"
	var step_def := TutorialStepDef.new()
	step_def.signals = [sig]
	step_def.target = TutorialTargetDef.new()
	step_def.target.node_path = NodePath("Btn")
	var flow := GroupTaskDef.new()
	flow.mode = GroupTaskDef.Mode.SEQUENTIAL
	flow.tasks = [step_def]

	var done := [false]
	var task := flow.create_entity() as GroupTask
	task.completed.connect(func(): done[0] = true)
	task.activate({"root": host})

	assert_true(task.active_child_entity != null, "教程启动后应有活跃步骤")
	btn.pressed.emit()
	for i in 60:
		if done[0]:
			break
		await tree.process_frame
	assert_true(done[0], "按钮信号触发后教程应完成")
	host.queue_free()


func test_start_helper() -> void:
	# 便捷路径: guide.start(flow, host) 一行启动, 内部完成桥接, 完成后自动 blur
	var tree := Engine.get_main_loop() as SceneTree
	var host := Node.new()
	host.name = "TutHost2"
	tree.root.add_child(host)
	await tree.process_frame
	var btn := Button.new()
	btn.name = "Btn"
	host.add_child(btn)
	await tree.process_frame

	var sig := NodeSignalDef.new()
	sig.node_path = NodePath("Btn")
	sig.signal_name = &"pressed"
	var step_def := TutorialStepDef.new()
	step_def.signals = [sig]
	step_def.target = TutorialTargetDef.new()
	step_def.target.node_path = NodePath("Btn")
	var flow := GroupTaskDef.new()
	flow.mode = GroupTaskDef.Mode.SEQUENTIAL
	flow.tasks = [step_def]

	var layer := CanvasLayer.new()
	host.add_child(layer)
	var guide := TutorialGuide.new()
	guide.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(guide)
	await tree.process_frame

	var done := [false]
	var task := guide.start(flow, host)
	task.completed.connect(func(): done[0] = true)
	assert_true(guide._active, "start 后应处于聚焦渲染状态")
	btn.pressed.emit()
	for i in 60:
		if done[0]:
			break
		await tree.process_frame
	assert_true(done[0] and not guide._active, "完成后 Guide 应自动 blur(不再绘制遮罩)")
	host.queue_free()


func test_screen_rect_node2d_sprite() -> void:
	# Node2D 目标体量: 子级 Sprite2D 的视觉尺寸换算为屏幕矩形(2D 精灵挖孔准确)
	var tree := Engine.get_main_loop() as SceneTree
	var node2d := Node2D.new()
	node2d.position = Vector2(100, 100)
	tree.root.add_child(node2d)
	var sprite := Sprite2D.new()
	sprite.texture = ImageTexture.create_from_image(Image.create(64, 64, false, Image.FORMAT_RGBA8))
	node2d.add_child(sprite)
	await tree.process_frame
	var rect := TutorialTargetDef.get_screen_rect(node2d)
	# Sprite2D 默认 centered: 局部 (-32,-32,64,64), 经画布变换到 (68,68,64,64)
	assert_true(rect.size.is_equal_approx(Vector2(64, 64)), \
			"Node2D 应取子级精灵体量, 实际: %s" % rect)
	assert_true(rect.position.is_equal_approx(Vector2(68, 68)), \
			"精灵体量应随节点位置平移, 实际: %s" % rect)
	node2d.queue_free()


func test_stop_helper() -> void:
	# stop(): 提前结束/跳过教程, 取消聚焦并停用任务(不触发 completed)
	var tree := Engine.get_main_loop() as SceneTree
	var host := Node.new()
	host.name = "TutStop"
	tree.root.add_child(host)
	await tree.process_frame
	var btn := Button.new()
	btn.name = "Btn"
	host.add_child(btn)
	await tree.process_frame

	var sig := NodeSignalDef.new()
	sig.node_path = NodePath("Btn")
	sig.signal_name = &"pressed"
	var step_def := TutorialStepDef.new()
	step_def.signals = [sig]
	step_def.target = TutorialTargetDef.new()
	step_def.target.node_path = NodePath("Btn")
	var flow := GroupTaskDef.new()
	flow.mode = GroupTaskDef.Mode.SEQUENTIAL
	flow.tasks = [step_def]

	var layer := CanvasLayer.new()
	host.add_child(layer)
	var guide := TutorialGuide.new()
	guide.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(guide)
	await tree.process_frame

	var completed := [false]
	var task := guide.start(flow, host)
	task.completed.connect(func(): completed[0] = true)
	assert_true(guide._active, "start 后应聚焦渲染")
	guide.stop()
	assert_false(guide._active, "stop 后不再绘制遮罩")
	assert_false(task.is_active, "stop 后任务应停用")
	assert_false(completed[0], "stop 不应触发 completed")
	host.queue_free()


func test_step_started_signal() -> void:
	# step_started: 每进入一个步骤发一次(供外部绑定步骤 UI/进度)
	var tree := Engine.get_main_loop() as SceneTree
	var host := Node.new()
	host.name = "TutSteps"
	tree.root.add_child(host)
	await tree.process_frame
	var btn := Button.new()
	btn.name = "Btn"
	host.add_child(btn)
	await tree.process_frame

	var sig := NodeSignalDef.new()
	sig.node_path = NodePath("Btn")
	sig.signal_name = &"pressed"
	var step1 := TutorialStepDef.new()
	step1.signals = [sig]
	var step2 := TutorialStepDef.new()
	step2.signals = [sig]
	var flow := GroupTaskDef.new()
	flow.mode = GroupTaskDef.Mode.SEQUENTIAL
	flow.tasks = [step1, step2]

	var layer := CanvasLayer.new()
	host.add_child(layer)
	var guide := TutorialGuide.new()
	guide.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(guide)
	await tree.process_frame

	var started := []
	guide.step_started.connect(func(step: Task): started.append(step))
	guide.start(flow, host)
	assert_eq(started.size(), 1, "首步进入应发 step_started")
	btn.pressed.emit()
	for i in 60:
		if started.size() >= 2:
			break
		await tree.process_frame
	assert_eq(started.size(), 2, "第二步进入应再发 step_started")
	host.queue_free()


func test_pure_tip_modes() -> void:
	# 锁定语义自动推导(无 target 的纯提示步骤):
	#   - 有信号 → 不遮挡, 等信号推进(不拦截界面操作)
	#   - 无信号 → "点任意处继续", 画暗区并强制点击
	var tree := Engine.get_main_loop() as SceneTree
	var host := Node.new()
	host.name = "TutPureTip"
	tree.root.add_child(host)
	await tree.process_frame

	var sig := NodeSignalDef.new()
	sig.node_path = NodePath("Btn")
	sig.signal_name = &"pressed"
	var step_waits := TutorialStepDef.new()   # 无 target + 有信号
	step_waits.signals = [sig]
	var step_click := TutorialStepDef.new()   # 无 target + 无信号
	var flow_waits := GroupTaskDef.new()
	flow_waits.mode = GroupTaskDef.Mode.SEQUENTIAL
	flow_waits.tasks = [step_waits]
	var flow_click := GroupTaskDef.new()
	flow_click.mode = GroupTaskDef.Mode.SEQUENTIAL
	flow_click.tasks = [step_click]

	var layer := CanvasLayer.new()
	host.add_child(layer)
	var guide := TutorialGuide.new()
	guide.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(guide)
	await tree.process_frame

	guide.start(flow_waits, host)
	assert_false(guide.is_blocking(), "无 target 有信号: 纯提示不遮挡输入")
	assert_eq(guide._dim_top.mouse_filter, Control.MOUSE_FILTER_IGNORE, \
			"无 target 有信号: 暗区不拦截输入")

	guide.start(flow_click, host)
	assert_true(guide.is_blocking(), "无 target 无信号: 点任意处继续, 应遮挡输入")
	assert_eq(guide._dim_top.mouse_filter, Control.MOUSE_FILTER_STOP, \
			"无 target 无信号: 暗区应拦截全屏点击")
	host.queue_free()


func test_save_data_roundtrip() -> void:
	# 进度持久化: 真实 .tres 流程存档 → Task.restore 一步还原(含 def 与子任务树), 进度不回退。
	# 用 .tres 而非动态 Def: 只有带 resource_path 的 Def 才能被存档记录并还原。
	var tree := Engine.get_main_loop() as SceneTree
	var host := Node.new()
	host.name = "TutSave"
	tree.root.add_child(host)
	await tree.process_frame

	var flow: GroupTaskDef = load("res://Assets/Def/Tutorial/Tutorial_Start.tres")
	var task := flow.create_entity() as GroupTask
	task.activate({"root": host})
	assert_eq(task.get_progress(), Vector2i(0, 2), "初始进度应为 0/2")

	task.active_child_entity.complete()          # 完成第一步 → 推进到第二步
	await tree.process_frame
	var saved := task.save_data()
	assert_eq(saved.get("def", ""), "Tutorial/Tutorial_Start.tres", "存档应记录 Def 相对路径")
	assert_eq(saved.get("children", []).size(), 2, "存档应包含全部步骤")
	assert_true(saved.children[0].get("is_completed", false), "存档应记录第一步已完成")
	assert_eq(task.get_progress(), Vector2i(1, 2), "完成一步后进度应为 1/2")

	var restored := Task.restore(saved, {"root": host}) as GroupTask
	assert_true(restored != null, "存档应能还原出任务实体")
	assert_eq(restored.def.resource_path, flow.resource_path, "还原后的 def 应与存档一致")
	assert_eq(restored.get_progress(), Vector2i(1, 2), "还原后应保留进度 1/2")
	assert_true(restored.active_child_entity != null \
					and not restored.active_child_entity.is_completed,
			"还原后应停在第 2 步, 不重跑已完成的第 1 步")
	host.queue_free()