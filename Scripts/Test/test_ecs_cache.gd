extends TestCase

## ECS 缓存正确性回归(对应两处"静默陈旧数据"修复):
## 1) 行集缓存: 命令缓冲 flush / Prefab 实例化 / 反序列化等结构变更后必须自动失效;
## 2) ECSQuery 规范化条件缓存: 查询对象被池化复用、条件改变时不得跨帧残留。
##
## 静默性说明: 这两类缺陷都不会报错, 只会让系统遍历到错误的实体集合 —— 故用"内容"而非"数量"断言锁定。


## 结构变更(命令缓冲 / prefab 实例化 / 反序列化)后无条件行集必须变新
func test_all_rows_cache_follows_structure() -> void:
	var w := ECSWorld.new(false)
	w.register_component(PTCompA)

	var e0 := w.create_entity()
	w.add_component(e0, PTCompA)
	var before := w.query_rows(PTCompA).size()   # 建立缓存: 1 行

	# 经命令缓冲新增一个带 PTCompA 的实体 → flush 后应变新
	var e1 := w.create_entity()
	w.cmd_add_component(e1, PTCompA)
	w.cmd_flush()
	var after_cmd := w.query_rows(PTCompA).size()

	# prefab 实例化 3 个 → 再增 3
	var pf := w.create_prefab()
	w.prefab_add(pf, PTCompA, {"x": 7})
	w.instantiate(pf, 3)
	var after_inst := w.query_rows(PTCompA).size()

	# 反序列化进一个"已建过缓存"的新世界 → 行集必须变新
	var snap: Dictionary = w.serialize()
	var w2 := ECSWorld.new(false)
	w2.register_component(PTCompA)
	var warm2 := w2.query_rows(PTCompA).size()   # 建缓存(应为 0)
	w2.deserialize(snap)
	var after_de := w2.query_rows(PTCompA).size()

	assert_eq(before, 1, "初始 1 行")
	assert_eq(after_cmd, before + 1, "命令缓冲 flush 后行集应变新")
	assert_eq(after_inst, after_cmd + 3, "prefab 实例化 3 个后应再增 3")
	assert_eq(warm2, 0, "空世界预热为 0")
	assert_eq(after_de, after_inst, "反序列化后行集必须变新")

	# 值也要原样搬过去(填充路径已改为直接写列, 必须仍按字段对齐)
	var src_col: PackedInt32Array = w.get_column(PTCompA, &"x")
	var dst_col: PackedInt32Array = w2.get_column(PTCompA, &"x")
	assert_eq(dst_col.size(), src_col.size(), "反序列化后列长度应一致")
	for i in mini(src_col.size(), dst_col.size()):
		assert_eq(dst_col[i], src_col[i], "第 %d 行的值必须与存档一致" % i)


## 同一查询对象复用(框架 for_each 对象池即如此)且条件改变时, 规范化条件必须跟着变
func test_norm_conds_not_reused_across_queries() -> void:
	var w := ECSWorld.new(false)
	w.register_component(PTCompA)
	for i in 6:
		var e := w.create_entity()
		w.add_component(e, PTCompA)
		w.set_field(e, PTCompA, &"x", i)

	var xa: PackedInt32Array = w.get_column(PTCompA, &"x")

	# 复用同一个查询对象(不 new 新的) —— 这正是对象池的行为
	var q: ECSQuery = load("res://addons/DEVFramework/ECS/System/ECSQuery.gd").new()
	q._init_rule(w, PTCompA)

	# 第一轮: x < 2
	q.where(&"x").less_than(2)
	var c1: Array = q.get_norm_conditions()
	var rows1: PackedInt32Array = w.batch_collect_norm(PTCompA, [], [], [c1])[0]

	# 复用同一对象做第二轮: x > 3(条件已变, 规范化缓存必须失效)
	q._reset(w, PTCompA)
	q.where(&"x").greater_than(3)
	var c2: Array = q.get_norm_conditions()
	var rows2: PackedInt32Array = w.batch_collect_norm(PTCompA, [], [], [c2])[0]

	# 断言"内容": 第二轮必须只含 x > 3 的行(陈旧条件会返回 x < 2 的行)
	var stale_rows: Array[int] = []
	for r in rows2:
		if xa[r] <= 3:
			stale_rows.append(xa[r])
	assert_eq(rows1.size(), 2, "x < 2 应有 2 行")
	assert_true(not rows2.is_empty(), "x > 3 应有行")
	assert_true(stale_rows.is_empty(), "第二轮混入了 <= 3 的行: %s (规范化条件残留)" % str(stale_rows))
	assert_eq(int(c2[0]["op"]), ECSWorld.CondOp.GREATER_THAN, "复用后条件操作符应更新")
	assert_eq(int(c2[0]["value"]), 3, "复用后条件值应更新")
