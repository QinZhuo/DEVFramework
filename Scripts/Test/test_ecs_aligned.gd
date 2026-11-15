extends TestCase

## ECS 跨组件对齐(query_aligned) + 查询缓存增量失效。
##
## 两类缺陷都不报错, 只会让系统遍历到错误的实体集合 ⇒ 断言"内容"而不只是"数量"。

const ROWS := 50

var _ids: Array[int] = []


## 50 个实体都有 A/B, 其中 i % 7 == 0 的额外带 C(x: A=i, B=i*10)
func _world() -> ECSWorld:
	var w := ECSWorld.new(false)
	w.register_component(PTCompA)
	w.register_component(PTCompB)
	w.register_component(PTCompC)
	_ids.clear()
	for i in ROWS:
		var e := w.create_entity()
		w.add_component(e, PTCompA)
		w.add_component(e, PTCompB)
		w.set_field(e, PTCompA, &"x", i)
		w.set_field(e, PTCompB, &"x", i * 10)
		if i % 7 == 0:
			w.add_component(e, PTCompC)
		_ids.append(e)
	return w


func test_aligned_rows_map_to_same_entity() -> void:
	var w := _world()
	var aligned := w.query_aligned(PTCompA, [PTCompB])
	var ra: PackedInt32Array = aligned[0]
	var rb: PackedInt32Array = aligned[1]
	assert_eq(ra.size(), ROWS, "所有实体都有 A/B")

	var same := true
	for k in ra.size():
		if w.entity_of_row(PTCompA, ra[k]) != w.entity_of_row(PTCompB, rb[k]):
			same = false
	assert_true(same, "对齐行的实体必须一致")

	var xa: PackedInt32Array = w.get_column(PTCompA, &"x")
	var xb: PackedInt32Array = w.get_column(PTCompB, &"x")
	var cross := true
	for k in ra.size():
		if xb[rb[k]] != xa[ra[k]] * 10:
			cross = false
	assert_true(cross, "按对齐行号取列必须交叉吻合, 否则整列错位")

	var filt := w.query_aligned(PTCompA, [PTCompB], [PTCompC])
	assert_eq(filt[0].size(), 42, "without C: 50 - 8 = 42")


func test_cache_invalidates_on_structural_change() -> void:
	var w := _world()
	w.query_rows(PTCompA, [], [])
	var cache_size := w._query_cache.size()
	w.query_rows(PTCompA, [], [])
	assert_eq(w._query_cache.size(), cache_size, "同签名查询应命中缓存, 条目不再增长")

	var cnt := w.query_rows(PTCompA, [], []).size()
	w.add_component(_ids[1], PTCompC)
	assert_eq(w.query_rows(PTCompA, [], []).size(), cnt, "加 C 只失效 C 缓存, A 缓存应保持")
	assert_eq(cnt, ROWS, "A 查询行数")

	var ne := w.create_entity()
	w.add_component(ne, PTCompA)
	var cnt2 := w.query_rows(PTCompA, [], []).size()
	assert_eq(cnt2, cnt + 1, "新增带 A 的实体必须让 A 缓存失效并更新行数")

	w.destroy_entity(_ids[2])
	assert_eq(w.query_rows(PTCompA, [], []).size(), cnt2 - 1, "销毁实体后缓存同样要跟上")
