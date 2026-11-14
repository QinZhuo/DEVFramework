extends TestCase

## ECSSystem 是纯运行时对象（RefCounted，不继承 Def，也没有配置资源层）：
## 1) 调度状态是实例私有的 —— 同一系统类型在多个世界互不影响
## 2) register_system 不传优先级时取 system.priority
## 3) interval / rate / fixed_step 的帧调度语义
## 4) World 只负责建世界，系统由 _setup_world 注册


class Ticker extends ECSSystem:
	var runs := 0

	func _run(_ctx: ECSSystemContext, _delta: float) -> void:
		runs += 1


class TickerWorld extends World:
	func _setup_world(world: ECSWorld) -> void:
		world.register_system(Ticker.new())


func test_system_is_def_free() -> void:
	var system := Ticker.new()
	assert_false(system.has_method(&"get_root_def"), "系统不应继承 Def")
	assert_false(system.has_method(&"duplicate"), "系统不是 Resource，不需要靠复制拿独立实例")


func test_schedule_state_is_per_instance() -> void:
	var a := Ticker.new()
	var b := Ticker.new()
	a.interval = 0.5
	b.interval = 0.5
	assert_eq(a._schedule(0.3), -1.0, "未到 interval 不应运行")
	assert_eq(b._schedule(0.3), -1.0, "b 不应继承 a 的进度（否则这里会是 0.3）")
	assert_eq(a._schedule(0.3), 0.3, "a 累计到阈值应运行")


func test_rate_skips_frames() -> void:
	var system := Ticker.new()
	system.rate = 2
	assert_eq(system._schedule(0.016), -1.0, "rate=2 时首帧不跑")
	assert_eq(system._schedule(0.016), 0.016, "rate=2 时次帧跑")


func test_fixed_step_wins_over_interval() -> void:
	var system := Ticker.new()
	system.fixed_step = 0.02
	system.interval = 1.0
	assert_eq(system._schedule(0.01), -1.0, "未攒够固定步长不跑")
	assert_eq(system._schedule(0.015), 0.02, "运行时 delta 应是固定步长")


func test_priority_used_when_not_passed() -> void:
	var world := ECSWorld.new(false)
	var system := Ticker.new()
	system.priority = 42
	world.register_system(system)
	assert_eq(world.scheduler().get_priority(system), 42, "不传优先级时应取 system.priority")


func test_world_setup_registers_runtime_systems() -> void:
	var w1 := TickerWorld.new()
	var e1 := w1.init_world()
	var w2 := TickerWorld.new()
	var e2 := w2.init_world()
	var sys1 := e1.get_systems()
	var sys2 := e2.get_systems()
	assert_eq(sys1.size(), 1, "应注册 1 个系统")
	assert_true(sys1[0] != sys2[0], "两个世界应各自 new 一份")
	w1.free()
	w2.free()
