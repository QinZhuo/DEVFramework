extends TestCase

## 统一查询链: process Callback / sub·mul·div 动作 / must·without / query_aligned_where。
## 步骤之间有数据依赖(同一世界被逐步改列), 故保持在一个 test_ 方法内顺序执行。

var _w: ECSWorld
var _ids: Array[int] = []
var _seen: Array = []


func _x(idx: int) -> int:
	return int(_w.get_field(_ids[idx], PTCompA, &"x"))


func _q() -> ECSQuery:
	return load("res://addons/DEVFramework/ECS/System/ECSQuery.gd").new()._init_rule(_w, PTCompA)


func _collect(rows: PackedInt32Array, _comp_rows: Dictionary, w: ECSWorld) -> void:
	var xa: PackedInt32Array = w.get_column(PTCompA, &"x")
	for r in rows:
		_seen.append(xa[r])


func test_query_chain() -> void:
	_w = ECSWorld.new(false)
	_w.register_component(PTCompA)
	_w.register_component(PTCompB)
	_w.register_component(PTCompC)
	for i in 20:
		var e := _w.create_entity()
		_w.add_component(e, PTCompA)
		_w.add_component(e, PTCompB)
		_w.set_field(e, PTCompA, &"x", i)
		_w.set_field(e, PTCompB, &"x", 100 + i)
		_ids.append(e)
	for i in _ids.size():
		if i % 5 == 0:
			_w.add_component(_ids[i], PTCompC)

	# ---- query_aligned_where(条件 + 多组件对齐), 用初始干净的 x ----
	var aligned: Array = _w.query_aligned_where(PTCompA, [], [],
			[{"comp": PTCompA, "field": &"x", "op": ECSWorld.CondOp.GREATER_THAN, "value": 15}],
			[PTCompA, PTCompB])
	var ra: PackedInt32Array = aligned[0]
	var rb: PackedInt32Array = aligned[1]
	assert_eq(ra.size(), 4, "x > 15 应有 4 行(16..19)")
	var same := true
	for k in ra.size():
		if _w.entity_of_row(PTCompA, ra[k]) != _w.entity_of_row(PTCompB, rb[k]):
			same = false
	assert_true(same, "对齐行的实体必须一致")

	# ---- process Callback: 条件过滤后遍历 ----
	_seen.clear()
	var q := _q()
	q.where(&"x").less_than(10)
	q.process(_collect, [PTCompA])
	q.execute()
	var missing: Array[int] = []
	for i in range(10):
		if not _seen.has(i):
			missing.append(i)
	assert_true(missing.is_empty(), "x < 10 应全部被遍历, 缺少: %s" % str(missing))

	# ---- 规则动作 mul / div ----
	var q2 := _q()
	q2.mul(&"x", 2.0)
	q2.execute()
	assert_eq(_x(1), 2, "1 * 2 = 2")
	# ids[4] 原 4 → mul 8 → div 4 → 2
	var q3 := _q()
	q3.div(&"x", 4.0)
	q3.execute()
	assert_eq(_x(4), 2, "8 / 4 = 2")

	# ---- must / without ----
	var rows: PackedInt32Array = _w.query_rows(PTCompA, [PTCompB], [PTCompC])
	assert_eq(rows.size(), 16, "20 - 4 个带 C 的 = 16")

	# ---- process 内写列(get_column 改 + set_column 写回) ----
	var q4 := _q()
	q4.process(func(rows2: PackedInt32Array, _cr: Dictionary, ww: ECSWorld):
		var xa: PackedInt32Array = ww.get_column(PTCompA, &"x")
		for r in rows2:
			xa[r] += 1000
		ww.set_column(PTCompA, &"x", xa)
	, [PTCompA])
	q4.execute()
	assert_eq(_x(0), 1000, "0 + 1000 = 1000")
