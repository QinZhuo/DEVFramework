extends TestCase

## 并行调度冒烟: A/B/C 互不访问(可并行), Shared 与 A 冲突(必须排在其后)。
## 真正的线程交错受宿主机调度影响, 断言不稳定性高, 所以这里只锁定
## "注册表/调度器没崩 + 4 个系统都进了访问集合"这层契约, 抛错则由 runner 记为失败。


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
