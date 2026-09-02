@tool
class_name test_task
extends TestCase

## 任务系统本体回归 — 状态机 / 计数目标 / 前置与奖励 / TaskTool / 条件信号过滤

class FakeCondition extends ConditionDef:
	var met := false
	func is_met(_context) -> bool:
		return met

class FakeReward extends EffectDef:
	var applied: Array = []
	func apply(context) -> void:
		applied.append(context)

## 内置测试信号源(相对宿主 root 为 "Src")
class Emitter extends Node:
	signal hit()


func test_status_lifecycle() -> void:
	# INACTIVE → ACTIVE → COMPLETED; 终态不可再激活, complete 幂等
	var task := Task.create(SignalTaskDef.new())
	assert_eq(task.status, TaskDef.Status.INACTIVE, "初始应为 INACTIVE")
	assert_false(task.is_active and task.is_completed, "初始既不活跃也未完成")

	task.activate({"root": null})
	assert_true(task.is_active, "激活后应为 ACTIVE")

	task.complete()
	assert_eq(task.status, TaskDef.Status.COMPLETED, "完成后应为 COMPLETED")
	assert_true(task.is_terminal, "完成应为终态")

	task.activate({"root": null})
	assert_eq(task.status, TaskDef.Status.COMPLETED, "终态不可再激活")
	task.complete()
	assert_eq(task.status, TaskDef.Status.COMPLETED, "重复 complete 幂等")


func test_fail_and_cancel() -> void:
	# 失败/取消均为终态, 只发各自信号不发 completed
	var task := Task.create(SignalTaskDef.new())
	var events := []
	task.completed.connect(func(): events.append("completed"))
	task.failed.connect(func(): events.append("failed"))
	task.cancelled.connect(func(): events.append("cancelled"))

	task.fail()
	assert_eq(task.status, TaskDef.Status.FAILED, "失败后应为 FAILED")
	assert_true(task.is_terminal, "失败应为终态")
	assert_eq(events, ["failed"], "失败只发 failed 不发 completed")

	task.activate({"root": null})
	assert_eq(task.status, TaskDef.Status.FAILED, "终态不可再激活")

	var other := Task.create(SignalTaskDef.new())
	other.cancel()
	assert_eq(other.status, TaskDef.Status.CANCELLED, "取消后应为 CANCELLED")
	assert_true(other.is_terminal, "取消应为终态")


func test_count_task_progress_and_roundtrip() -> void:
	# 计数目标: 信号累加 + 进度查询 + 计数计入存档
	var tree := Engine.get_main_loop() as SceneTree
	var host := Node.new()
	host.name = "CountHost"
	tree.root.add_child(host)
	var src := Emitter.new()
	src.name = "Src"
	host.add_child(src)
	await tree.process_frame

	var sig := NodeSignalDef.new()
	sig.node_path = NodePath("Src")
	sig.signal_name = &"hit"
	var def := CountTaskDef.new()
	def.required = 3
	def.signals = [sig]

	var task := Task.create(def) as CountTask
	task.activate({"root": host})
	assert_eq(task.get_progress(), Vector2i(0, 3), "初始计数应为 0/3")

	src.hit.emit()
	src.hit.emit()
	assert_eq(task.get_progress(), Vector2i(2, 3), "两次触发应累计 2/3")
	assert_false(task.is_completed, "未达标不应完成")

	LogTool.disable_tag("任务")   # 内置 Def 无路径的存档告警在本用例属预期噪音
	var saved := task.save_data()
	var restored := Task.create(def) as CountTask
	restored.load_data(saved, {"root": host})
	LogTool.enable_tag("任务")
	assert_eq(restored.get_progress(), Vector2i(2, 3), "读档应保留计数 2/3")
	assert_true(restored.is_active, "读档(带上下文)应恢复 ACTIVE 并重连信号")

	# 原任务与还原实例都监听同一信号源: 先停用原任务, 其计数应冻结
	task.deactivate()
	assert_eq(task.status, TaskDef.Status.INACTIVE, "停用后应回到 INACTIVE")

	src.hit.emit()
	assert_true(restored.is_completed, "第三次触发应完成还原后的任务")
	assert_eq(restored.get_progress(), Vector2i(3, 3), "完成时计数 3/3")
	assert_eq(task.get_progress(), Vector2i(2, 3), "停用的任务计数不再变化")
	host.queue_free()


func test_count_task_required_one() -> void:
	# required == 1 退化为普通信号任务
	var tree := Engine.get_main_loop() as SceneTree
	var host := Node.new()
	host.name = "CountOne"
	tree.root.add_child(host)
	var src := Emitter.new()
	src.name = "Src"
	host.add_child(src)
	await tree.process_frame

	var sig := NodeSignalDef.new()
	sig.node_path = NodePath("Src")
	sig.signal_name = &"hit"
	var def := CountTaskDef.new()
	def.required = 0            # 下限钳制为 1
	def.signals = [sig]
	assert_eq(def.required, 1, "required 应钳制到下限 1")

	var task := Task.create(def)
	task.activate({"root": host})
	src.hit.emit()
	assert_true(task.is_completed, "required=1 时信号触发即完成")
	host.queue_free()


func test_count_task_with_condition() -> void:
	# 条件计数: ConditionSignalDef 过滤后只累计满足条件的触发
	var tree := Engine.get_main_loop() as SceneTree
	var host := Node.new()
	host.name = "CountCond"
	tree.root.add_child(host)
	var src := Emitter.new()
	src.name = "Src"
	host.add_child(src)
	await tree.process_frame

	var node_sig := NodeSignalDef.new()
	node_sig.node_path = NodePath("Src")
	node_sig.signal_name = &"hit"
	var cond := FakeCondition.new()
	var cond_sig := ConditionSignalDef.new()
	cond_sig.signal_def = node_sig
	cond_sig.condition = cond

	var def := CountTaskDef.new()
	def.required = 2
	def.signals = [cond_sig]
	var task := Task.create(def)
	var ctx := {"root": host}
	task.activate(ctx)

	cond.met = false
	src.hit.emit()
	src.hit.emit()
	assert_eq(task.get_progress(), Vector2i(0, 2), "条件未满足不应计数")

	cond.met = true
	src.hit.emit()
	assert_eq(task.get_progress(), Vector2i(1, 2), "满足条件才计数")
	src.hit.emit()
	assert_true(task.is_completed, "达到目标数量应完成")
	host.queue_free()


func test_prerequisite_blocks_activation() -> void:
	# 前置条件: 未满足拒绝激活(发 blocked), 满足后可激活
	var cond := FakeCondition.new()
	var def := SignalTaskDef.new()
	def.prerequisite = cond
	var task := Task.create(def)
	var blocked := [false]
	task.blocked.connect(func(): blocked[0] = true)

	task.activate({"root": null})
	assert_false(task.is_active, "前置未满足不应激活")
	assert_true(blocked[0], "应发 blocked")

	cond.met = true
	task.activate({"root": null})
	assert_true(task.is_active, "前置满足后应激活")


func test_rewards_apply_on_complete() -> void:
	# 完成奖励: complete 时按序 apply, 且不随重复 complete 重复发放
	var reward := FakeReward.new()
	var def := SignalTaskDef.new()
	def.rewards = [reward]
	var task := Task.create(def)
	var ctx := {"root": null}
	task.activate(ctx)

	task.complete()
	assert_eq(reward.applied.size(), 1, "完成时应发放奖励")
	assert_true(reward.applied[0] == ctx, "奖励上下文应为 activate 传入的对象")

	task.complete()
	assert_eq(reward.applied.size(), 1, "重复 complete 不应重复发奖")


func test_task_tool_registry_and_save_all() -> void:
	# 跟踪表: 注册/终态迁移/查找/聚合存读档
	var tree := Engine.get_main_loop() as SceneTree
	TaskTool.clear()

	var a := Task.create(SignalTaskDef.new())
	var b := Task.create(CountTaskDef.new())
	TaskTool.track(a)
	TaskTool.track(a)                       # 重复注册忽略
	TaskTool.track(b)
	assert_eq(TaskTool.get_active().size(), 2, "活动表应有 2 个任务")

	a.complete()
	assert_eq(TaskTool.get_active().size(), 1, "终态任务应移出活动表")
	assert_eq(TaskTool.get_finished().size(), 1, "终态任务应转入 finished")
	assert_true(TaskTool.find("CountTaskDef") == b, "find 应能按 Def 键定位任务")

	TaskTool.untrack(b)
	assert_eq(TaskTool.get_active().size(), 0, "注销后活动表应为空")
	TaskTool.clear()

	# 聚合存读档: 用真实 .tres 流程(带 Def 路径才能还原)
	var host := Node.new()
	host.name = "ToolHost"
	tree.root.add_child(host)
	await tree.process_frame
	var flow: GroupTaskDef = load("res://Assets/Def/Tutorial/Tutorial_Start.tres")
	var t := flow.create_entity() as GroupTask
	TaskTool.track(t)
	t.activate({"root": host})
	t.active_child_entity.complete()

	var saved := TaskTool.save_all()
	assert_true(saved.has("Tutorial/Tutorial_Start.tres"), "聚合存档应以 Def 相对路径为键")

	var restored := TaskTool.load_all(saved, {"root": host})
	assert_eq(restored.size(), 1, "应还原 1 个任务")
	var rt := restored[0] as GroupTask
	assert_eq(rt.get_progress(), Vector2i(1, 2), "还原后应保留进度 1/2")
	assert_true(TaskTool.get_active().has(rt), "还原的任务应已注册")
	TaskTool.clear()
	host.queue_free()


func test_condition_signal_zero_arg_and_filter() -> void:
	# 回归: 零参信号(如 pressed/hit)必须能经 ConditionSignalDef 连接, 且条件基于连接上下文求值
	var tree := Engine.get_main_loop() as SceneTree
	var host := Node.new()
	host.name = "CondHost"
	tree.root.add_child(host)
	var src := Emitter.new()
	src.name = "Src"
	host.add_child(src)
	await tree.process_frame

	var node_sig := NodeSignalDef.new()
	node_sig.node_path = NodePath("Src")
	node_sig.signal_name = &"hit"
	var cond := FakeCondition.new()
	var cond_sig := ConditionSignalDef.new()
	cond_sig.signal_def = node_sig
	cond_sig.condition = cond

	var calls := [0]
	var cb := func(_d = null): calls[0] += 1
	var ctx := {"root": host}
	cond_sig.connect_signal(ctx, cb)

	src.hit.emit()
	assert_eq(calls[0], 0, "条件未满足不应转发(修复前零参信号根本无法连接)")

	cond.met = true
	src.hit.emit()
	assert_eq(calls[0], 1, "条件满足应转发")

	cond_sig.disconnect_signal(ctx, cb)
	src.hit.emit()
	assert_eq(calls[0], 1, "断开后不应再转发")
	host.queue_free()
