class_name PTParallelTest
extends RefCounted

## 并行调度自检入口(临时测试): 
##   世界注册 4 个系统: A/B/C 互不访问(应并行), Shared 与 A 冲突(应串行其后)。
##   运行 12 帧后打印分组统计。

static func run() -> void:
	var w := ECSWorld.new(false)
	w.parallel_enabled = true
	w.parallel_min_systems = 2
	w.register_component(PTCompA)
	w.register_component(PTCompB)
	w.register_component(PTCompC)
	w.register_system(PTSysA.new(), 10)
	w.register_system(PTSysB.new(), 9)
	w.register_system(PTSysC.new(), 8)
	w.register_system(PTSharedSys.new(), 7)
	for i in 12:
		w.tick(0.016)
	print("--- parallel stats: ", w.debug_parallel_stats())
	# 校验: A/B/C 应出现过非主线程 ID(真正并行); 主线程 ID 单独取
	var main_id := OS.get_thread_caller_id()
	print("[PTTest] main_thread=%d" % main_id)
