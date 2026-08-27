class_name test_pcg
extends TestCase

## PCG 模块回归桥接 — 将 Scripts/Test/pcg/ 下的静态用例接入 TestRunner 套件。
## PCT*.run() 已改为返回 bool（内部自行聚合 all_ok 并打印明细），此处只判定与报告。


func test_constraint() -> void:
	assert_true(PCTConstraintTest.run(), "PCG 约束测试存在失败项，详见输出日志")


func test_determinism() -> void:
	assert_true(PCTDeterminismTest.run(), "PCG 确定性测试存在失败项，详见输出日志")


func test_native() -> void:
	assert_true(PCGNativeTest.run(), "原生库自检存在失败项，详见输出日志")
