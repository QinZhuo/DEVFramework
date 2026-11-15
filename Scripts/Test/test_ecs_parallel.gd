extends TestCase

## 并行调度契约。
##
## 线程交错本身不可断言(宿主机调度决定), 但**分批结构**可以断言:
## 读写同一组件的系统若被分到同一批, 数据竞争必然发生 —— 这是唯一能被自动化锁住的那一层。


class _WriteA extends ECSSystem:
	func get_system_name() -> String: return "WriteA"
	func required_components() -> Array: return [PTCompA]
	func write_components() -> Array: return [PTCompA]
	func _run(_ctx, _delta) -> void: pass


class _WriteA2 extends ECSSystem:
	func get_system_name() -> String: return "WriteA2"
	func required_components() -> Array: return [PTCompA]
	func write_components() -> Array: return [PTCompA]
	func _run(_ctx, _delta) -> void: pass


class _WriteB extends ECSSystem:
	func get_system_name() -> String: return "WriteB"
	func required_components() -> Array: return [PTCompB]
	func write_components() -> Array: return [PTCompB]
	func _run(_ctx, _delta) -> void: pass


class _Serial extends ECSSystem:
	func get_system_name() -> String: return "Serial"
	func required_components() -> Array: return [PTCompA]
	func can_run_parallel() -> bool: return false
	func _run(_ctx, _delta) -> void: pass


func _make_world() -> ECSWorld:
	var w := ECSWorld.new(false)
	w.parallel_enabled = true
	w.register_component(PTCompA)
	w.register_component(PTCompB)
	return w


## 首帧是强制串行预热(采集访问集合), 第二帧才会真正分批
func _groups_after_warmup(w: ECSWorld) -> Array:
	w.tick(0.016)
	w.tick(0.016)
	return w.scheduler().debug_parallel_groups()


func _group_index(groups: Array, name: String) -> int:
	for i in groups.size():
		if (groups[i] as Array).has(name):
			return i
	return -1


func _same_group(groups: Array, a: String, b: String) -> bool:
	var ia := _group_index(groups, a)
	return ia >= 0 and ia == _group_index(groups, b)


func test_parallel_scheduling_smoke() -> void:
	var w := ECSWorld.new(false)
	w.parallel_enabled = true
	w.register_component(PTCompA)
	w.register_component(PTCompB)
	w.register_component(PTCompC)
	w.register_system(PTSysA.new(), 10)
	w.register_system(PTSysB.new(), 9)
	w.register_system(PTSysC.new(), 8)
	w.register_system(PTSharedSys.new(), 7)

	for i in 12:
		w.tick(0.016)

	var stats: Dictionary = w.debug_parallel_stats()
	assert_true(bool(stats.get("parallel_enabled", false)), "并行开关应生效")
	assert_eq(int(stats.get("tracked_systems", 0)), 4, "4 个系统的访问集合都应被登记")
	assert_true(int(stats.get("effective_threads", 0)) >= 1, "有效线程数应 >= 1")


## 写同一组件的两个系统必须分批(串行); 不同组件的系统应当真的被并起来跑
func test_write_conflict_is_serialized() -> void:
	var w := _make_world()
	w.register_system(_WriteA.new(), 10)
	w.register_system(_WriteA2.new(), 9)
	w.register_system(_WriteB.new(), 8)
	var groups := _groups_after_warmup(w)
	assert_true(not groups.is_empty(), "并行 tick 应产出分批结构")

	# 安全属性(硬要求): 冲突系统绝不能同批 —— 同批即数据竞争
	assert_false(_same_group(groups, "WriteA", "WriteA2"),
			"写同一组件的两个系统不能同批, 否则数据竞争: %s" % str(groups))
	# 并行度(软要求): 不冲突的系统要能被并进同一批, 否则"并行"名存实亡。
	# 具体谁和谁一批取决于调度顺序, 所以只断言"存在多于一个的批", 不钉死配对。
	var widest := 0
	for g in groups:
		widest = maxi(widest, (g as Array).size())
	assert_true(widest >= 2, "应存在同批并行的系统(实际分批: %s)" % str(groups))


## can_run_parallel()=false 的系统必须单独成批(它可能碰场景树等不可并行资源)
func test_non_parallel_system_is_barrier() -> void:
	var w := _make_world()
	w.register_system(_WriteA.new(), 10)
	w.register_system(_Serial.new(), 9)
	var groups := _groups_after_warmup(w)
	var idx := _group_index(groups, "Serial")
	assert_true(idx >= 0, "串行系统应出现在分批结构里: %s" % str(groups))
	if idx >= 0:
		assert_eq((groups[idx] as Array).size(), 1, "串行系统必须独占一批: %s" % str(groups))
	assert_false(_same_group(groups, "WriteA", "Serial"), "串行系统不能与任何系统同批")
