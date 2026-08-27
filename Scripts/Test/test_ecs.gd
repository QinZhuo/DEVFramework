class_name test_ecs
extends TestCase

## ECS 模块回归桥接 — 将 Scripts/Test/ecs/ 下的静态用例接入 TestRunner 套件。
## PT*.run() 已改为返回 bool（内部自行聚合断言并打印明细），此处只判定与报告。


func test_aligned_query() -> void:
	assert_true(PTAlignedTest.run(), "ECS 跨组件对齐/查询缓存自检失败，详见输出日志")


func test_query_chain() -> void:
	assert_true(PTQueryTest.run(), "ECS 查询链自检失败，详见输出日志")


func test_dsl() -> void:
	assert_true(PTDSLTest.run(), "ECS 规则层 DSL 自检失败，详见输出日志")


func test_hooks() -> void:
	assert_true(PTHooksTest.run(), "ECS 生命周期钩子自检失败，详见输出日志")


func test_parallel_smoke() -> void:
	assert_true(PTParallelTest.run(), "ECS 并行调度冒烟测试失败，详见输出日志")
