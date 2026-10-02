class_name test_pcg
extends TestCase

## PCG 模块回归桥接 — 将 Scripts/Test/pcg/ 下的静态用例接入 TestRunner 套件。
## PCT*.run() / PCGSdf*.run() 已改为返回 bool（内部自行聚合 all_ok 并打印明细），此处只判定与报告。
##
## PCG 现在是纯 3D 生成运行时，六层各自的测试边界：
##   PCTDeterminismTest确定性：同 seed 必复现（栅格 / WFC 固定格 / 分块 / 管线）
##   PCGNativeTest             原生库（PCGCave3D / PCGWFC3D）自检
##   PCGSdfGenTest             场与网格：烘焙闭环、seed 确定性、纯局部空间
##   PCGSdfLayoutTest          布局：贴地 / 朝向 / 避让 / 存档（全程不生成真实几何）
##   PCGSdfWorldTest           端到端：独立生成器 + 组装器的整体结构性质
##   PCGSdfSlotTest            材质槽位：填充 / 覆盖 / 夹紧 / 窄带（只操作场，毫秒级）
##   PCGSdfStyleTest           风格包 + 双产物：配置完整性、体素开关、下发链路
##   PCGSdfDioramaTest         微缩小场景：簇式落位语义、体素边长一致、分帧一致、存档


func test_determinism() -> void:
	assert_true(PCTDeterminismTest.run(), "PCG 确定性测试存在失败项，详见输出日志")


func test_native() -> void:
	assert_true(PCGNativeTest.run(), "原生库自检存在失败项，详见输出日志")


func test_sdf_gen() -> void:
	assert_true(PCGSdfGenTest.run(), "PCG 场/网格生成测试存在失败项，详见输出日志")


func test_sdf_layout() -> void:
	assert_true(PCGSdfLayoutTest.run(), "PCG 布局测试存在失败项，详见输出日志")


func test_sdf_world() -> void:
	assert_true(PCGSdfWorldTest.run(), "PCG 世界组装测试存在失败项，详见输出日志")


## 槽位是"不用贴图分件上色"的唯一数据通道，且出错不报错 —— 必须有回归。
func test_sdf_slot() -> void:
	assert_true(PCGSdfSlotTest.run(), "PCG 槽位测试存在失败项，详见输出日志")


## 风格包出问题的共同点是**静默**（该出现的单体没出现、该出的体素没出），
## 所以这组断言的价值全在"逐条核对数量与产物"，而不是只看一个总布尔。
func test_sdf_style() -> void:
	assert_true(PCGSdfStyleTest.run(), "PCG 风格包测试存在失败项，详见输出日志")


## 微缩小场景同样如此：少一类道具时组装器不报错，只是画面"安静地少东西"。
## 这组额外盯住两条只有簇式布局才有的性质 —— 环带 angle 是相位（否则同类叠在一起）、
## 全场体素边长一致（否则"统一正方体"不成立）。
func test_sdf_diorama() -> void:
	assert_true(PCGSdfDioramaTest.run(), "PCG 微缩场景测试存在失败项，详见输出日志")


## 性能基准不是断言，只打印耗时。名字不带 test_ 前缀的用例不会被 runner 自动执行，
## 需要时用 headless 手动调用 PCTBenchmarkTest.run()。