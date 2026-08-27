class_name PTQueryTest
extends RefCounted

## 查询链 统一查询链自检: process Callback / sub·mul·div 动作 / must·without / query_aligned_where

static var seen: Array = []

static func _cb(rows: PackedInt32Array, _comp_rows: Dictionary, w: ECSWorld) -> void:
	var xa: PackedInt32Array = w.get_column(PTCompA, &"x")
	for r in rows:
		seen.append(xa[r])

static func run() -> bool:
	var all_ok := true
	var w := ECSWorld.new(false)
	w.register_component(PTCompA)
	w.register_component(PTCompB)
	w.register_component(PTCompC)
	var ids: Array[int] = []
	for i in 20:
		var e := w.create_entity()
		w.add_component(e, PTCompA)
		w.add_component(e, PTCompB)
		w.set_field(e, PTCompA, &"x", i)
		w.set_field(e, PTCompB, &"x", 100 + i)
		ids.append(e)
	for i in ids.size():
		if i % 5 == 0:
			w.add_component(ids[i], PTCompC)

	# ---- query_aligned_where(条件 + 多组件对齐), 用初始干净 x ----
	var aligned: Array = w.query_aligned_where(PTCompA, [], [],
			[{"comp": PTCompA, "field": &"x", "op": ECSWorld.CondOp.GREATER_THAN, "value": 15}],
			[PTCompA, PTCompB])
	var ra: PackedInt32Array = aligned[0]
	var rb: PackedInt32Array = aligned[1]
	var ok := ra.size() == 4
	for k in ra.size():
		if w.entity_of_row(PTCompA, ra[k]) != w.entity_of_row(PTCompB, rb[k]):
			ok = false
	all_ok = all_ok and ok
	print("[Query] aligned_where=", ra.size(), " same_entity=", ok)

	# ---- process Callback: 条件过滤后遍历 ----
	seen.clear()
	var q = load("res://addons/DEVFramework/ECS/ECSQuery.gd").new()
	q._init_rule(w, PTCompA)
	q.where(&"x").less_than(10)
	q.process(PTQueryTest._cb, [PTCompA])
	q.execute()
	var expected := true
	for i in range(10):
		if not seen.has(i):
			expected = false
	all_ok = all_ok and expected
	print("[Query] process_filtered=", expected, " count=", seen.size())

	# ---- 规则动作 mul ----
	var q2 = load("res://addons/DEVFramework/ECS/ECSQuery.gd").new()
	q2._init_rule(w, PTCompA)
	q2.mul(&"x", 2.0)
	q2.execute()
	print("[Query] mul_1=", int(w.get_field(ids[1], PTCompA, &"x")))   # 1*2=2
	# div: ids[4] 原 4 → mul 8 → div 4 → 2
	var q3 = load("res://addons/DEVFramework/ECS/ECSQuery.gd").new()
	q3._init_rule(w, PTCompA)
	q3.div(&"x", 4.0)
	q3.execute()
	print("[Query] div_after=", int(w.get_field(ids[4], PTCompA, &"x")))  # 8/4=2

	# ---- must / without ----
	var rows: PackedInt32Array = w.query_rows(PTCompA, [PTCompB], [PTCompC])
	all_ok = all_ok and rows.size() == 16
	print("[Query] must_without=", rows.size())   # 20 - 4 = 16

	# ---- process 内写列(get_column 改 + set_column 写回) ----
	var q4 = load("res://addons/DEVFramework/ECS/ECSQuery.gd").new()
	q4._init_rule(w, PTCompA)
	q4.process(func(rows: PackedInt32Array, _cr: Dictionary, ww: ECSWorld):
		var xa: PackedInt32Array = ww.get_column(PTCompA, &"x")
		for r in rows:
			xa[r] += 1000
		ww.set_column(PTCompA, &"x", xa)
	, [PTCompA])
	q4.execute()
	all_ok = all_ok and int(w.get_field(ids[0], PTCompA, &"x")) == 1000
	print("[Query] process_write=", int(w.get_field(ids[0], PTCompA, &"x")))   # 0+1000=1000
	return all_ok
