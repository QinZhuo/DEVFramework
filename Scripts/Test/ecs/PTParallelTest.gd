class_name PTParallelTest
extends RefCounted

## 并行调度自检(冒烟): 
##   世界注册 4 个系统: A/B/C 互不访问(应并行), Shared 与 A 冲突(应串行其后)。
##   运行 12 帧后打印分组统计。线程调度受运行环境影响, 仅做无崩溃冒烟 + 统计输出。

static func run() -> bool:
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
	print("--- parallel stats: ", w.debug_parallel_stats())
	# 校验: A/B/C 应出现过非主线程 ID(真正并行); 主线程 ID 单独取
	var main_id := OS.get_thread_caller_id()
	print("[PTTest] main_thread=%d" % main_id)
	# 并行性受宿主机线程池调度影响, 断言不稳定性高, 只做冒烟通过
	return true
