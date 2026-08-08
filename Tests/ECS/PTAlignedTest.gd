class_name PTAlignedTest
extends RefCounted

## ② 跨组件对齐行号(query_aligned) + ③ 查询缓存增量失效 自检。

static func run() -> void:
	var w := ECSWorld.new(false)
	w.register_component(PTCompA)
	w.register_component(PTCompB)
	w.register_component(PTCompC)
	var ids: Array[int] = []
	for i in 50:
		var e := w.create_entity()
		w.add_component(e, PTCompA)
		w.add_component(e, PTCompB)
		w.set_field(e, PTCompA, &"x", i)
		w.set_field(e, PTCompB, &"x", i * 10)
		ids.append(e)
	for i in ids.size():
		if i % 7 == 0:
			w.add_component(ids[i], PTCompC)

	# ---- ② query_aligned ----
	var aligned = w.query_aligned(PTCompA, [PTCompB])
	var rows_a: PackedInt32Array = aligned[0]
	var rows_b: PackedInt32Array = aligned[1]
	var ok := true
	for k in rows_a.size():
		if w.entity_of_row(PTCompA, rows_a[k]) != w.entity_of_row(PTCompB, rows_b[k]):
			ok = false
	print("[Aligned] count=", rows_a.size(), " aligned_same_entity=", ok,
			" haveB=", rows_b.size())
	# 过滤 without
	var filt = w.query_aligned(PTCompA, [PTCompB], [PTCompC])
	print("[Aligned] withoutC=", filt[0].size())   # 期望 50 - 8 = 42
	# 对齐数据正确性: 用对齐行号读列, 交叉核对 hp/pos 一致
	var xa: PackedInt32Array = w.get_column(PTCompA, &"x")
	var xb: PackedInt32Array = w.get_column(PTCompB, &"x")
	var cross_ok := true
	for k in rows_a.size():
		if xb[rows_b[k]] != xa[rows_a[k]] * 10:
			cross_ok = false
	print("[Aligned] cross_column_ok=", cross_ok)

	# ---- ③ 缓存增量失效 ----
	# 1) 同签名查询命中: 缓存条目不增长
	w.query_rows(PTCompA, [], [])
	var s0 := w._query_cache.size()
	w.query_rows(PTCompA, [], [])
	print("[Cache] same_query_hits=", w._query_cache.size() == s0)
	# 2) add PTCompC 只失效 C 缓存, PTCompA 缓存保持(数量应不变)
	var cnt_a0: int = w.query_rows(PTCompA, [], []).size()
	w.add_component(ids[1], PTCompC)
	var cnt_a1: int = w.query_rows(PTCompA, [], []).size()
	print("[Cache] addC_keeps_A=", cnt_a1 == cnt_a0)
	# 3) add PTCompA(新实体) 必须使 A 缓存失效并更新数量
	var ne := w.create_entity()
	w.add_component(ne, PTCompA)
	w.set_field(ne, PTCompA, &"x", 999)
	var cnt_a2: int = w.query_rows(PTCompA, [], []).size()
	print("[Cache] addA_updates=", cnt_a2 == cnt_a0 + 1)
	# 4) destroy 全局失效, 查询结果更新
	var cnt_a3: int = w.query_rows(PTCompA, [], []).size()
	w.destroy_entity(ids[2])
	var cnt_a4: int = w.query_rows(PTCompA, [], []).size()
	print("[Cache] destroy_updates=", cnt_a4 == cnt_a3 - 1)
