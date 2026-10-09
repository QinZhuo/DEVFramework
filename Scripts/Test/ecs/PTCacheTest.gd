class_name PTCacheTest
extends RefCounted

## ECS 缓存正确性回归(对应两处"静默陈旧数据"修复):
## 1) query_all_rows 行集缓存: 命令缓冲 flush / Prefab 实例化 / 反序列化等结构变更后必须自动失效;
## 2) ECSQuery 规范化条件缓存: 查询对象被池化复用、条件改变时不得跨帧残留。
##
## 静默性说明: 这两类缺陷都不会报错, 只会让系统遍历到错误的实体集合 —— 故用"内容"而非"数量"断言锁定。

static func run() -> bool:
	var all_ok := true
	all_ok = _test_all_rows_cache() and all_ok
	all_ok = _test_norm_conds_reuse() and all_ok
	return all_ok


## 结构变更(命令缓冲 / prefab 实例化 / 反序列化)后无条件行集必须变新
static func _test_all_rows_cache() -> bool:
	var w := ECSWorld.new(false)
	w.register_component(PTCompA)

	var e0 := w.create_entity()
	w.add_component(e0, PTCompA)
	var before := w.query_all_rows(PTCompA).size()   # 建立缓存: 1 行

	# 经命令缓冲新增一个带 PTCompA 的实体 → flush 后应变 new
	var e1 := w.create_entity()
	w.cmd_add_component(e1, PTCompA)
	w.cmd_flush()
	var after_cmd := w.query_all_rows(PTCompA).size()

	# prefab 实例化 3 个 → 再增 3
	var pf := w.create_prefab()
	w.prefab_add(pf, PTCompA, {"x": 7})
	w.instantiate(pf, 3)
	var after_inst := w.query_all_rows(PTCompA).size()

	# 反序列化进一个"已建过缓存"的新世界 → 行集必须变新
	var snap: Dictionary = w.serialize()
	var w2 := ECSWorld.new(false)
	w2.register_component(PTCompA)
	var warm2 := w2.query_all_rows(PTCompA).size()   # 建缓存(应为 0)
	w2.deserialize(snap)
	var after_de := w2.query_all_rows(PTCompA).size()

	var ok := before == 1 \
			and after_cmd == before + 1 \
			and after_inst == after_cmd + 3 \
			and warm2 == 0 and after_de == after_inst
	print("[Cache] all_rows before=", before, " after_cmd=", after_cmd,
			" after_inst=", after_inst, " after_deser=", after_de, " ok=", ok)
	return ok


## 同一查询对象复用(框架 for_each 对象池即如此)且条件改变时, 规范化条件必须跟着变
static func _test_norm_conds_reuse() -> bool:
	var w := ECSWorld.new(false)
	w.register_component(PTCompA)
	for i in 6:
		var e := w.create_entity()
		w.add_component(e, PTCompA)
		w.set_field(e, PTCompA, &"x", i)

	var xa: PackedInt32Array = w.get_column(PTCompA, &"x")

	# 复用同一个查询对象(不 new 新的) —— 这正是对象池的行为
	var q = load("res://addons/DEVFramework/ECS/ECSQuery.gd").new()
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
	var content_ok := not rows2.is_empty()
	for r in rows2:
		if xa[r] <= 3:
			content_ok = false
	var op_ok: bool = int(c2[0]["op"]) == ECSWorld.CondOp.GREATER_THAN and int(c2[0]["value"]) == 3
	var ok := rows1.size() == 2 and content_ok and op_ok
	print("[Cache] norm_conds rows1=", rows1.size(), " rows2=", rows2.size(),
			" op_ok=", op_ok, " rows2=", rows2, " ok=", ok)
	return ok
