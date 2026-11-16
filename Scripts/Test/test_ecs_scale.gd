extends TestCase

## 规模回归闸门: 20k 实体的关键路径必须留在"同一个数量级"。
##
## 为什么需要它: 之前所有性能结论都来自临时 eval, 一次改动把 query_rows 从 4µs 变成 40µs
## 没有任何测试会红 —— 这只是"感觉没变慢"。这里用**宽松阈值**(实测值的 ~8~10 倍)做闸门:
## 只抓"数量级回退", 不追求跨机器的微秒精度(那会让 CI 随机失败)。
##
## 实测基线(20k 实体, release 库, 本机): query_rows 3µs / columns_of×5 19µs(首轮冷缓存 43µs) /
## batch_apply_rows 48µs / serialize 0.09ms / instantiate(1000) 0.03ms /
## 层级 set_parent_many(10000) 2.9ms。
## 阈值仍取实测的 ~10~20 倍: 只抓数量级回退(如列聚合从 19µs 退到 300µs), 不追求跨机器精度。

const N := 20000
const BUDGET_QUERY_US := 60.0         # 实测 3µs
const BUDGET_COLS5_US := 400.0        # 实测 19µs(冷缓存首轮 43µs)
const BUDGET_BATCH_US := 600.0        # 实测 48µs
const BUDGET_SERIALIZE_MS := 1.0      # 实测 0.09ms
const BUDGET_INSTANTIATE_MS := 10.0   # 实测 0.03ms(1000 个)
const BUDGET_HIER_BULK_MS := 50.0     # 实测 2.9ms(10000 个); 退化成逐条是 81ms → 会红
const BUDGET_SCATTER_US := 400.0      # 实测 8µs; 曾因"长度校验拿含 prefab 的行数比源数组"退化成 49ms → 会红


func _build_world(n: int) -> Dictionary:
	var w := ECSWorld.new(false)
	w.register_component(PTCompA)
	var pf := w.create_prefab()
	w.prefab_add(pf, PTCompA, {"x": 1, "y": 2, "z": 3, "min_v": 4, "max_v": 5})
	w.instantiate(pf, n)
	return {"world": w, "prefab": pf}


func test_scale_hot_paths_within_budget() -> void:
	var built := _build_world(N)
	var w: ECSWorld = built["world"]
	var fields := [&"x", &"y", &"z", &"min_v", &"max_v"]

	var q := PerfTool.bench(func() -> void: w.query_rows(PTCompA), 15, 5)
	assert_true(q.p50_ms * 1000.0 < BUDGET_QUERY_US,
			"query_rows 20k 超预算: %.0fµs (阈值 %.0f)" % [q.p50_ms * 1000.0, BUDGET_QUERY_US])

	var c5 := PerfTool.bench(func() -> void: w.columns_of(PTCompA, fields), 15, 5)
	assert_true(c5.p50_ms * 1000.0 < BUDGET_COLS5_US,
			"columns_of×5 超预算: %.0fµs (阈值 %.0f)" % [c5.p50_ms * 1000.0, BUDGET_COLS5_US])

	var rows: PackedInt32Array = w.query_rows(PTCompA)
	var ba := PerfTool.bench(func() -> void: w.batch_apply_rows(PTCompA, rows, PTCompA, &"x", 0, 1.0, 0.5), 15, 5)
	assert_true(ba.p50_ms * 1000.0 < BUDGET_BATCH_US,
			"batch_apply_rows 超预算: %.0fµs (阈值 %.0f)" % [ba.p50_ms * 1000.0, BUDGET_BATCH_US])

	var ser := PerfTool.bench(func() -> void: w.serialize(), 8, 3)
	assert_true(ser.p50_ms < BUDGET_SERIALIZE_MS,
			"serialize 20k 超预算: %.2fms (阈值 %.1f)" % [ser.p50_ms, BUDGET_SERIALIZE_MS])

	var pf: int = built["prefab"]
	var inst := PerfTool.bench(func() -> void: w.instantiate(pf, 1000), 5, 2)
	assert_true(inst.p50_ms < BUDGET_INSTANTIATE_MS,
			"instantiate(1000) 超预算: %.2fms (阈值 %.1f)" % [inst.p50_ms, BUDGET_INSTANTIATE_MS])


## 大规模下"批量写 + 单列读"的值必须对得上(性能改动最容易在这里悄悄写错)。
func test_scale_values_are_consistent() -> void:
	var built := _build_world(5000)
	var w: ECSWorld = built["world"]
	var rows: PackedInt32Array = w.query_rows(PTCompA)
	assert_eq(rows.size(), 5000, "行集大小")

	# 整列写(语义明确): 全部改成 11
	var write := PackedInt32Array()
	write.resize(5000)
	for i in 5000:
		write[i] = 11
	w.set_columns_of(PTCompA, {&"x": write})
	var col: PackedInt32Array = w.get_column(PTCompA, &"x")
	assert_eq(col.size(), 5000, "列长度")
	var ok := true
	for i in 5000:
		if col[i] != 11:   # 初值 1 + 10
			ok = false
			break
	assert_true(ok, "批量 +10 之后每行都应是 11")

	# 存档 → 重建 → 值一致
	var snap: Dictionary = w.serialize()
	var w2 := ECSWorld.new(false)
	w2.register_component(PTCompA)
	w2.deserialize(snap)
	var col2: PackedInt32Array = w2.get_column(PTCompA, &"x")
	assert_eq(col2.size(), 5000, "读档后列长度")
	assert_eq(col2[0], 11, "读档首行")
	assert_eq(col2[4999], 11, "读档末行")


## 批量写列的闸门: 含 prefab 的块(instantiate 的常态)必须走"按段 memcpy"。
## 曾经的退化: 长度校验拿**含 prefab 的总行数**去比源数组 → 永远"源不够长" → 逐行兜底,
## 而兜底里每行又重算一次 ecs_value_count(values) → 20k 一行 set_columns_of 要 44~49ms。
func test_scatter_with_prefab_within_budget() -> void:
	var built := _build_world(N)   # prefab 与 20000 个实例同块
	var w: ECSWorld = built["world"]
	var col := PackedInt32Array()
	col.resize(N)
	for i in N:
		col[i] = i % 100
	var s := PerfTool.bench(func() -> void: w.set_columns_of(PTCompA, {&"x": col}), 15, 5)
	var back: PackedInt32Array = w.get_column(PTCompA, &"x")
	assert_eq(back.size(), N, "列长度")
	assert_true(back[0] == 0 and back[12345] == 45 and back[N - 1] == 99,
			"含 prefab 时写入值错位(prefab 行应与源数组解耦)")
	assert_true(s.p50_ms * 1000.0 < BUDGET_SCATTER_US,
			"set_columns_of(20k, 含 prefab) 超预算: %.0fµs (阈值 %.0f)" % [s.p50_ms * 1000.0, BUDGET_SCATTER_US])

	# 短源数组: 有值写值、缺的写默认值, 且绝不能越界读
	w.set_columns_of(PTCompA, {&"x": PackedInt32Array([7])})
	var s2: PackedInt32Array = w.get_column(PTCompA, &"x")
	assert_eq(s2[0], 7, "首个值应写入")
	assert_eq(s2[N - 1], 0, "缺失行应写默认值(不是脏内存)")


## 层级批量挂父: 语义必须与逐条一致(组件 target + 反向索引都要对)。
func test_hierarchy_bulk_matches_sequential() -> void:
	var w := ECSWorld.new(false)
	var root := w.create_entity()
	var kids := PackedInt32Array()
	kids.resize(500)
	for i in 500:
		kids[i] = w.create_entity()
	w.set_parent_many(kids, root)
	assert_eq(w.child_count(root), 500, "批量挂父后子节点数")
	assert_eq(w.get_parent(kids[7]), root, "组件 target 必须同步")
	assert_eq(w.get_children(root).size(), 500, "反向索引必须同步")

	# 逐条版对照(另一个父), 两边的结果形态必须一致
	var root2 := w.create_entity()
	var kids2 := PackedInt32Array()
	kids2.resize(500)
	for i in 500:
		kids2[i] = w.create_entity()
		w.set_parent(kids2[i], root2)
	assert_eq(w.child_count(root2), 500, "逐条挂父后子节点数")

	# 重挂: 批量换父要把旧父的子列表摘干净
	w.set_parent_many(kids, root2)
	assert_eq(w.child_count(root), 0, "批量重挂后旧父应为空")
	assert_eq(w.child_count(root2), 1000, "新父应收下全部")


## 层级批量挂父的性能闸门: 1 万个子节点必须走批量(逐条是 81ms, 会超这个阈值)。
func test_hierarchy_bulk_perf() -> void:
	var w := ECSWorld.new(false)
	var root := w.create_entity()
	var kids := PackedInt32Array()
	kids.resize(10000)
	for i in 10000:
		kids[i] = w.create_entity()
	var b := PerfTool.bench(func() -> void: w.set_parent_many(kids, root), 3, 1)
	assert_eq(w.child_count(root), 10000, "批量挂父结果")
	assert_true(b.p50_ms < BUDGET_HIER_BULK_MS,
			"set_parent_many(10000) 超预算: %.1fms (阈值 %.0f, 逐条实现是 81ms)" % [b.p50_ms, BUDGET_HIER_BULK_MS])


## 确定性: 同样初始化 + 同样操作序列 → 两个世界的存档逐字段相等。
func test_scale_determinism() -> void:
	var a := _build_world(2000)
	var b := _build_world(2000)
	var wa: ECSWorld = a["world"]
	var wb: ECSWorld = b["world"]
	var rows: PackedInt32Array = wa.query_rows(PTCompA)
	wa.batch_apply_rows(PTCompA, rows, PTCompA, &"y", 0, 3.0, 1.0)
	wb.batch_apply_rows(PTCompA, wb.query_rows(PTCompA), PTCompA, &"y", 0, 3.0, 1.0)
	assert_true(wa.snapshot_diff(wa.serialize(), wb.serialize()).is_empty(),
			"同输入的两个世界存档必须完全一致(联机/回放前提)")
