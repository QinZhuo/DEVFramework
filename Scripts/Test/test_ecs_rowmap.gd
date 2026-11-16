extends TestCase

## 行号映射(实体 index → 块内行号)与变更过滤的探针。
##
## 背景: 行号原先存在"每块一张按最大实体下标开的稀疏 row_map"里(内存 4×块数×池大小,
## 且只写 -1 从不缩容), 现在改成全局一张 entity_row_。这类改动最典型的错法是
## **swap-remove 后忘了修正被挪动那一行的行号** —— 症状是"删一个实体, 另一个实体的值串了",
## 而且不报错。所以这里的断言全部是"删/迁之后逐个实体核对值"。

const Move := preload("res://Scripts/Entity/ECS/ECSDemoMoveComponent.gd")


func _world() -> ECSWorld:
	var w := ECSWorld.new(false)
	w.register_component(PTCompA)
	return w


## swap-remove: 删中间那个实体后, 其余实体读到的值必须还是自己的。
func test_row_survives_swap_remove() -> void:
	var w := _world()
	var ents: Array[int] = []
	for i in 5:
		var e := w.create_entity()
		w.add_component(e, PTCompA)
		w.set_field(e, PTCompA, &"x", (i + 1) * 10.0)
		ents.append(e)
	# 删第 2 个(非末尾): 末尾实体会被 swap 到这个位置
	w.destroy_entity(ents[1])
	var expect := {0: 10, 2: 30, 3: 40, 4: 50}
	for i in expect:
		assert_eq(int(w.get_field(ents[i], PTCompA, &"x")), int(expect[i]),
				"实体 #%d 的值被 swap-remove 弄串了" % i)
	assert_false(w.has_component(ents[1], PTCompA), "被删实体不应还有组件")


## 迁移(加/减组件)后, 行号与值都要跟着走。
func test_row_survives_migration() -> void:
	var w := _world()
	w.register_component(Move)
	var ents: Array[int] = []
	for i in 4:
		var e := w.create_entity()
		w.add_component(e, PTCompA)
		w.set_field(e, PTCompA, &"x", float((i + 1) * 7))
		ents.append(e)
	# 只给第 0、2 个加 Move → 它们迁到新块
	w.add_component(ents[0], Move)
	w.add_component(ents[2], Move)
	for i in 4:
		assert_eq(int(w.get_field(ents[i], PTCompA, &"x")), (i + 1) * 7,
				"迁移后实体 #%d 的旧组件值丢了" % i)
	# 再移除 Move → 迁回去, 值仍要对
	w.remove_component(ents[0], Move)
	assert_eq(int(w.get_field(ents[0], PTCompA, &"x")), 7, "二次迁移后值丢了")


## 稀疏/复用 id: 大量创建销毁后再创建, 行号映射仍必须正确。
func test_row_with_id_reuse() -> void:
	var w := _world()
	var keep: Array[int] = []
	for i in 200:
		var e := w.create_entity()
		w.add_component(e, PTCompA)
		w.set_field(e, PTCompA, &"x", float(i))
		if i % 50 == 0:
			keep.append(e)          # 留 4 个
		else:
			w.destroy_entity(e)     # 其余立刻销毁 → id 进空闲表
	# 再建 100 个(会复用刚才的 id)
	for i in 100:
		var e := w.create_entity()
		w.add_component(e, PTCompA)
		w.set_field(e, PTCompA, &"x", 1000.0 + i)
	for e in keep:
		var v := int(w.get_field(e, PTCompA, &"x"))
		assert_true(v % 50 == 0 and v >= 0, "复用 id 后老实体的值被覆盖了: %d" % v)


## 批量实例化 + 局部销毁: 剩下每个实体的列值都要与实体一致。
func test_row_bulk_instantiate_then_destroy() -> void:
	var w := _world()
	var pf := w.create_prefab()
	w.prefab_add(pf, PTCompA, {"x": 1})
	w.instantiate(pf, 100)
	var ents := w.query_entities(PTCompA)
	assert_eq(ents.size(), 100, "实例数")
	# 给每个实体写唯一值
	for i in ents.size():
		w.set_field(ents[i], PTCompA, &"x", float(i))
	# 销毁偶数下标的实体
	var killed := {}
	for i in range(0, ents.size(), 2):
		killed[ents[i]] = true
		w.destroy_entity(ents[i])
	var ok := true
	for i in ents.size():
		if killed.has(ents[i]):
			continue
		if int(w.get_field(ents[i], PTCompA, &"x")) != i:
			ok = false
			break
	assert_true(ok, "批量实例化 + 局部销毁后, 幸存实体的列值错位")


## 查询级变更过滤: 写过的行必须出现在 changed 里, 没写的不出现。
func test_changed_rows_after_write() -> void:
	var w := _world()
	var pf := w.create_prefab()
	w.prefab_add(pf, PTCompA, {})
	w.instantiate(pf, 50)
	var t0 := w.write_tick()
	# 只写前 5 行(整列写会盖全部, 所以用 set_columns_of 写前 5 个? 这里用批量算子做 +1)
	var rows: PackedInt32Array = w.query_rows(PTCompA)
	w.batch_apply_rows(PTCompA, rows, PTCompA, &"x", 0, 1.0, 1.0)
	var changed := w.query_changed_rows(PTCompA, t0)
	assert_eq(changed.size(), 50, "批量写应把 50 行都打上戳")
	assert_true(w.write_tick() > t0, "写序号必须前进")
	# 再也不写 → 相对新 tick 应无变化
	var t1 := w.write_tick()
	assert_eq(w.query_changed_rows(PTCompA, t1).size(), 0, "没写就不该出现变化行")
