class_name test_tutorial
extends TestCase

## 教程模块回归 — FocusMask(多目标点亮/输入收口/子视口与移动目标) + TutorialGuide(步骤 → 聚焦表现) + 纯 Task 驱动。


func test_screen_rect_control() -> void:
	# Control 目标的屏幕矩形换算(可交互区/气泡定位的几何基础)
	var tree := Engine.get_main_loop() as SceneTree
	var ctrl := Control.new()
	tree.root.add_child(ctrl)
	ctrl.position = Vector2(100, 80)
	ctrl.size = Vector2(200, 100)
	await tree.process_frame
	var rect := FocusMask.screen_rect(ctrl)
	assert_true(rect.position.is_equal_approx(Vector2(100, 80)) \
			and rect.size.is_equal_approx(Vector2(200, 100)),
			"Control 屏幕矩形应与布局一致, 实际: %s" % rect)
	ctrl.queue_free()


func test_screen_rect_node2d_sprite() -> void:
	# Node2D 目标体量: 子级 Sprite2D 的视觉尺寸换算为屏幕矩形
	var tree := Engine.get_main_loop() as SceneTree
	var node2d := Node2D.new()
	node2d.position = Vector2(100, 100)
	tree.root.add_child(node2d)
	var sprite := Sprite2D.new()
	sprite.texture = ImageTexture.create_from_image(Image.create(64, 64, false, Image.FORMAT_RGBA8))
	node2d.add_child(sprite)
	await tree.process_frame
	var rect := FocusMask.screen_rect(node2d)
	assert_true(rect.size.is_equal_approx(Vector2(64, 64)), "Node2D 应取子级精灵体量, 实际: %s" % rect)
	assert_true(rect.position.is_equal_approx(Vector2(68, 68)), "精灵体量应随节点位置平移, 实际: %s" % rect)
	node2d.queue_free()


func test_screen_rect_2d_in_subviewport() -> void:
	# 子视口里的 2D 控件: 先取子视口坐标, 再按 SubView3D 的贴图面投影回主视口
	var tree := Engine.get_main_loop() as SceneTree
	var screen := _make_screen(tree, Vector2(1.0, 0.75), Vector2i(200, 150))
	var viewport: SubViewport = screen.viewport
	var ui := Control.new()
	ui.size = Vector2(200, 150)
	viewport.add_child(ui)
	var ctrl := Control.new()
	ctrl.position = Vector2(40, 45)
	ctrl.size = Vector2(120, 60)
	ui.add_child(ctrl)
	await tree.process_frame

	var rect := FocusMask.screen_rect(ctrl)
	var expected := screen.viewport_rect_to_screen(ctrl.get_global_rect())
	assert_false(rect.size == Vector2.ZERO, "子视口内的 2D 目标应能算出屏幕矩形")
	assert_true(rect.is_equal_approx(expected), "应换算到主视口坐标, got=%s want=%s" % [rect, expected])
	assert_false(rect.is_equal_approx(ctrl.get_global_rect()), "不能直接返回子视口坐标, 必须经过贴图面投影")
	var quad_rect := screen.viewport_rect_to_screen(Rect2(Vector2.ZERO, Vector2(viewport.size)))
	assert_true(quad_rect.grow(1.0).encloses(rect), "换算结果应落在贴图面内")
	_free_screen(screen)


func test_screen_rect_3d_in_subviewport() -> void:
	# 子视口里的 3D 物体: 先用子视口相机投影, 再按贴图面换算回主视口
	var tree := Engine.get_main_loop() as SceneTree
	var screen := _make_screen(tree, Vector2(1.0, 0.75), Vector2i(200, 150))
	var viewport: SubViewport = screen.viewport
	viewport.own_world_3d = true
	var cam := Camera3D.new()
	cam.position = Vector3(0, 0, 2)
	viewport.add_child(cam)
	cam.current = true
	var box := BoxMesh.new()
	box.size = Vector3(0.5, 0.5, 0.5)
	var cube := MeshInstance3D.new()
	cube.mesh = box
	viewport.add_child(cube)
	await tree.process_frame

	var rect := FocusMask.screen_rect(cube)
	var aabb := cube.global_transform * box.get_aabb()
	var sub_rect := Rect2()
	for i in 8:
		var p := cam.unproject_position(aabb.get_endpoint(i))
		sub_rect = sub_rect.expand(p) if i > 0 else Rect2(p, Vector2.ZERO)
	var expected := screen.viewport_rect_to_screen(sub_rect)
	assert_false(rect.size == Vector2.ZERO, "子视口内的 3D 目标应能算出屏幕矩形")
	assert_true(rect.is_equal_approx(expected), "应换算到主视口坐标, got=%s want=%s" % [rect, expected])
	_free_screen(screen)


func test_step_completes_on_node_signal() -> void:
	# 纯 Task 外部驱动(无 Guide): 完成条件 = NodeSignalDef 订阅 Button.pressed
	var tree := Engine.get_main_loop() as SceneTree
	var host := _make_host(tree, "TutHost")
	var btn := _add_button(host, "Btn", Rect2(20, 20, 160, 60))
	await tree.process_frame

	var step_def := TutorialStepDef.new()
	step_def.signals = [_signal_def("Btn")]
	var done := [false]
	var task := _make_flow([step_def]).create_entity() as GroupTask
	task.completed.connect(func(): done[0] = true)
	task.activate({"root": host})
	assert_true(task.active_child_entity != null, "教程启动后应有活跃步骤")
	btn.pressed.emit()
	await tree.process_frame
	assert_true(done[0], "按钮信号触发后教程应完成")
	host.queue_free()


func test_mask_focuses_multiple_targets() -> void:
	# 多目标高亮: 每个目标一块可交互区, 区外锁定, 点任一目标即推进
	var tree := Engine.get_main_loop() as SceneTree
	FocusMaskTool.reset()
	var host := _make_host(tree, "TutMulti")
	var btn1 := _add_button(host, "Btn1", Rect2(60, 60, 160, 60))
	var btn2 := _add_button(host, "Btn2", Rect2(400, 320, 120, 80))
	await tree.process_frame

	var step := TutorialStepDef.new()
	_add_target(step, "Btn1", 0.0)
	_add_target(step, "Btn2", 8.0)
	step.signals = [_signal_def("Btn2"), _signal_def("Btn1")]

	var guide := _make_guide(host)
	await tree.process_frame
	var task := guide.start(_make_flow([step]), host)

	var mask := FocusMaskTool.get_mask()
	assert_true(mask != null and mask.is_active(), "启动后应有遮罩")
	assert_eq(mask.get_hit_rects().size(), 2, "两个目标应各有一块可交互区域")
	assert_true(mask.is_blocking(), "有目标时应锁定区外输入")
	assert_true(mask.get_parent() is CanvasLayer, "遮罩应自动挂在 CanvasLayer 上")
	assert_true(btn1.has_focus(), "焦点应交给第一个可聚焦目标")
	var rects := mask.get_hit_rects()
	assert_true(rects[0].has_point(btn1.get_global_rect().get_center()), "第一块可交互区域应覆盖 Btn1")
	assert_false(rects[0].has_point(Vector2(5, 5)), "Btn1 之外的区域不应可交互")
	# 新的实现不碰目标本身(屏幕空间合成), 所以目标节点的 z_index 与布局都不应被改动
	assert_eq(btn1.z_index, 0, "目标节点不应被提层(合成在屏幕空间完成), 实际 z=%d" % btn1.z_index)
	assert_true(mask._spot != null and mask._spot.visible, "应有一层屏幕空间合成")
	assert_true(mask._spot.z_index < FocusMask.TIP_Z, "气泡必须画在合成之上")

	btn2.pressed.emit()
	await tree.process_frame
	assert_true(task.is_completed, "点击任一高亮目标应推进完成")
	assert_false(mask.is_active(), "完成后遮罩应清除")
	host.queue_free()


func test_targets_follow_moving_target() -> void:
	# 移动目标: 可交互区每帧按目标当前位置重算(演示里的"缓慢移动按钮")
	var tree := Engine.get_main_loop() as SceneTree
	FocusMaskTool.reset()
	var host := _make_host(tree, "TutMoving")
	var ctrl := Control.new()
	ctrl.name = "Moving"
	host.add_child(ctrl)
	ctrl.position = Vector2(120, 100)
	ctrl.size = Vector2(160, 60)
	await tree.process_frame

	var step := TutorialStepDef.new()
	_add_target(step, "Moving", 0.0)
	var guide := _make_guide(host)
	await tree.process_frame
	guide.start(_make_flow([step]), host)
	var mask := FocusMaskTool.get_mask()
	var before := mask.get_hit_rects()[0]

	ctrl.position += Vector2(70, 40)
	await tree.process_frame
	var after := mask.get_hit_rects()[0]
	assert_true(after.position.is_equal_approx(before.position + Vector2(70, 40)),
			"可交互区应跟随目标移动, before=%s after=%s" % [before, after])
	host.queue_free()


func test_pure_tip_modes() -> void:
	# 无目标步骤的两种语义: 有信号 = 只提示不遮挡; 无信号 = 全屏变暗点任意处继续
	var tree := Engine.get_main_loop() as SceneTree
	FocusMaskTool.reset()
	var host := _make_host(tree, "TutPureTip")
	_add_button(host, "Btn", Rect2(20, 20, 160, 60))
	await tree.process_frame

	var step_wait := TutorialStepDef.new()
	step_wait.signals = [_signal_def("Btn")]
	var step_click := TutorialStepDef.new()

	var guide := _make_guide(host)
	await tree.process_frame

	guide.start(_make_flow([step_wait]), host)
	var mask := FocusMaskTool.get_mask()
	assert_false(mask.is_blocking(), "无目标有信号: 不遮挡输入")
	assert_true(is_zero_approx(mask.dim_color.a), "无目标有信号: 不绘制暗区")

	var click_task := guide.start(_make_flow([step_click]), host)
	assert_true(mask.is_active() and mask.is_blocking(), "无目标无信号: 应全屏遮挡")
	assert_true(mask.dim_color.a > 0.0, "无目标无信号: 应绘制暗区")
	mask._input(_press(Vector2(10, 10)))
	assert_true(click_task.is_completed, "点击任意处应完成该步骤")
	host.queue_free()


func test_advance_by_action_and_funnel_signals() -> void:
	# 键盘/手柄继续键推进 + 漏斗埋点信号(step_started / step_completed / stopped)
	var tree := Engine.get_main_loop() as SceneTree
	FocusMaskTool.reset()
	var host := _make_host(tree, "TutAction")
	await tree.process_frame

	var guide := _make_guide(host)
	await tree.process_frame
	var started := []
	var done_steps := []
	var stopped := [false]
	guide.step_started.connect(func(s: Task): started.append(s))
	guide.step_completed.connect(func(s: Task): done_steps.append(s))
	guide.stopped.connect(func(): stopped[0] = true)

	var flow := _make_flow([TutorialStepDef.new(), TutorialStepDef.new()])
	var task := guide.start(flow, host)
	assert_eq(started.size(), 1, "首步进入应发 step_started")

	var ev := InputEventAction.new()
	ev.action = &"ui_accept"
	ev.pressed = true
	FocusMaskTool.get_mask()._input(ev)
	assert_eq(done_steps.size(), 1, "按继续键应完成当前步骤")
	assert_eq(started.size(), 2, "应推进到第二步")
	assert_eq(task.get_progress(), Vector2i(1, 2), "进度应为 1/2")

	FocusMaskTool.get_mask()._input(ev)
	assert_eq(done_steps.size(), 2, "第二步同样可按键推进")
	assert_true(task.is_completed, "全部步骤完成后任务应完成")

	var restarted := guide.start(flow, host)
	guide.stop()
	assert_true(stopped[0], "stop() 应发 stopped(漏斗'中途放弃')")
	assert_false(restarted.is_active, "stop 后任务应停用")
	assert_false(FocusMaskTool.is_active(), "stop 后遮罩应清除")
	host.queue_free()


func test_save_data_roundtrip() -> void:
	# 进度持久化: 真实 .tres 流程存档 → Task.restore 一步还原, 进度不回退
	var tree := Engine.get_main_loop() as SceneTree
	var host := _make_host(tree, "TutSave")
	await tree.process_frame

	var flow: GroupTaskDef = load("res://Assets/Def/Tutorial/Tutorial_Start.tres")
	var task := flow.create_entity() as GroupTask
	task.activate({"root": host})
	assert_eq(task.get_progress(), Vector2i(0, 8), "初始进度应为 0/8")

	task.active_child_entity.complete()  # 完成第一步 → 推进到第二步
	await tree.process_frame
	var saved := task.save_data()
	assert_eq(saved.get("def", ""), "Tutorial/Tutorial_Start.tres", "存档应记录 Def 相对路径")
	assert_eq(saved.get("children", []).size(), 8, "存档应包含全部步骤")
	assert_true(saved.children[0].get("is_completed", false), "存档应记录第一步已完成")
	assert_eq(task.get_progress(), Vector2i(1, 8), "完成一步后进度应为 1/8")

	var restored := Task.restore(saved, {"root": host}) as GroupTask
	assert_true(restored != null, "存档应能还原出任务实体")
	assert_eq(restored.def.resource_path, flow.resource_path, "还原后的 def 应与存档一致")
	assert_eq(restored.get_progress(), Vector2i(1, 8), "还原后应保留进度 1/8")
	assert_true(restored.active_child_entity != null and not restored.active_child_entity.is_completed,
			"还原后应停在第 2 步, 不重跑已完成的第 1 步")
	host.queue_free()


# ------------------------------------------------------------

func _make_host(tree: SceneTree, host_name: String) -> Node:
	var host := Node.new()
	host.name = host_name
	tree.root.add_child(host)
	return host


func _add_button(host: Node, btn_name: String, rect: Rect2) -> Button:
	var btn := Button.new()
	btn.name = btn_name
	btn.focus_mode = Control.FOCUS_ALL
	btn.position = rect.position
	btn.size = rect.size
	host.add_child(btn)
	return btn


## 子视口贴面: 主相机 + SubView3D + 其子 SubViewport(结构约定同演示)
func _make_screen(tree: SceneTree, panel_size: Vector2, vp_size: Vector2i) -> SubView3D:
	var cam := Camera3D.new()
	cam.position = Vector3(0, 0, 4)
	tree.root.add_child(cam)
	cam.current = true

	var screen := SubView3D.new()
	var quad := QuadMesh.new()
	quad.size = panel_size
	screen.mesh = quad
	tree.root.add_child(screen)
	var viewport := SubViewport.new()
	viewport.size = vp_size
	screen.add_child(viewport)
	screen.viewport = viewport
	return screen


func _free_screen(screen: SubView3D) -> void:
	screen.queue_free()
	var root := (Engine.get_main_loop() as SceneTree).root
	var cam := root.get_camera_3d()
	if cam and cam.get_parent() == root:
		cam.queue_free()


func _make_guide(host: Node) -> TutorialGuide:
	var guide := TutorialGuide.new()
	guide.name = "TutorialGuide"
	host.add_child(guide)
	return guide


func _signal_def(node_path: String) -> NodeSignalDef:
	var sig := NodeSignalDef.new()
	sig.node_path = NodePath(node_path)
	sig.signal_name = &"pressed"
	return sig


func _add_target(step: TutorialStepDef, node_path: String, padding: float) -> void:
	var target := TutorialTargetDef.new()
	target.node_path = NodePath(node_path)
	target.padding = padding
	step.targets.append(target)


func _make_flow(steps: Array) -> GroupTaskDef:
	var flow := GroupTaskDef.new()
	flow.mode = GroupTaskDef.Mode.SEQUENTIAL
	for step in steps:
		flow.tasks.append(step)
	return flow


func _press(pos: Vector2) -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = pos
	return ev
