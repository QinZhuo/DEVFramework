class_name test_tutorial
extends TestCase

## 教程模块回归 — TutorialStepDef(继承 SignalTaskDef)表现配置 + 纯 Task 流程。


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
	# 完成条件 = 纯 Task 系统: TutorialStepDef 继承 SignalTaskDef, NodeSignalDef 订阅 Button.pressed
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
	step_def.tip_text = "点击按钮"
	var flow := GroupTaskDef.new()
	flow.mode = GroupTaskDef.Mode.SEQUENTIAL
	flow.tasks = [step_def]

	var done := [false]
	var runner := TutorialTool.start(flow, host)
	runner.tutorial_completed.connect(func(): done[0] = true)

	assert_true(runner.current_step() != null, "教程启动后应有活跃步骤")
	btn.pressed.emit()
	for i in 60:
		if done[0]:
			break
		await tree.process_frame
	assert_true(done[0], "按钮信号触发后教程应完成")
	host.queue_free()


func test_save_data_roundtrip() -> void:
	# 进度持久化: GroupTask 存档往返(断点续玩的数据基础)
	var tree := Engine.get_main_loop() as SceneTree
	var host := Node.new()
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

	var runner := TutorialTool.start(flow, host)
	# 第一步: 点击完成后推进到第二步
	btn.pressed.emit()
	await tree.process_frame
	var step := runner.current_step()
	var saved := runner.save_data()
	# 注: 动态创建的 Def 为 built-in, name 读取时回退脚本类名, 故用进度状态断言
	assert_true(step != null and not step.is_completed \
			and saved.children[0].get("is_completed", false), "第一步完成后应推进到第二步")

	assert_true(saved.get("children", []).size() == 2, "存档应包含全部步骤")
	assert_true(saved.children[0].get("is_completed", false), "存档应记录第一步已完成")
	host.queue_free()
