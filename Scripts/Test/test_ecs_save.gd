extends TestCase

## 存档格式(列式)与组件迁移图(边缓存)的契约。
##
## 为什么钉这两条:
## 1) 列式存档把"每实体一个 Dictionary + Variant 数组"换成"实体 id 数组 + 每字段一条 Packed 数组",
##    8000 实体从 55.8ms 降到 1ms 量级; 格式一旦退回逐实体会立刻在这里红。
## 2) 迁移图边缓存把"每次 add/remove 线性扫全部 archetype"换成查一条边;
##    缓存一旦算错, 表现是实体被搬进错误的块(数据串行/丢组件), 所以用"反复加删 + 校验旧数据"锁住。

const SAVE_VERSION := 1


func _w() -> ECSWorld:
	var w := ECSWorld.new(false)
	w.register_component(PTCompA)
	w.register_component(PTCompB)
	return w


## 存档必须是列式: entities = PackedInt32Array, columns = {字段: Packed 数组}
func test_save_is_columnar() -> void:
	var w := _w()
	for i in 5:
		var e := w.create_entity()
		w.add_component(e, PTCompA)
		w.set_field(e, PTCompA, &"x", i)

	var snap := w.serialize()
	assert_eq(int(snap["version"]), SAVE_VERSION, "存档版本应为列式")
	var cd: Dictionary = (snap["components"] as Array)[0]
	assert_true(cd["entities"] is PackedInt32Array, "实体 id 应是 PackedInt32Array(每实体一个 Dictionary 是旧格式)")
	assert_eq((cd["entities"] as PackedInt32Array).size(), 5, "5 个实体")
	var cols: Dictionary = cd["columns"]
	assert_true(cols.has(&"x"), "应含字段列 x")
	assert_true(cols[&"x"] is PackedInt32Array, "字段列应是 Packed 数组")
	assert_eq((cols[&"x"] as PackedInt32Array).size(), 5, "列长度必须等于实体数")


## 多组件往返: 实体数、各组件行数、每行字段值都要对得上
func test_save_roundtrip_multi_component() -> void:
	var w := _w()
	for i in 6:
		var e := w.create_entity()
		w.add_component(e, PTCompA)
		w.add_component(e, PTCompB)
		w.set_field(e, PTCompA, &"x", i)
		w.set_field(e, PTCompB, &"x", i * 10)

	var snap := w.serialize()
	var w2 := _w()
	var ids := w2.deserialize(snap)
	assert_eq(ids.size(), 6, "实体数一致")
	assert_eq(w2.query_rows(PTCompA).size(), 6, "A 行数一致")
	assert_eq(w2.query_rows(PTCompB).size(), 6, "B 行数一致")

	var ax: PackedInt32Array = w2.get_column(PTCompA, &"x")
	var bx: PackedInt32Array = w2.get_column(PTCompB, &"x")
	for i in 6:
		assert_eq(ax[i], i, "第 %d 行 A.x" % i)
		assert_eq(bx[i], i * 10, "第 %d 行 B.x" % i)


## 反复加/删同一组件 = 反复走迁移图的两条边; 已有组件的数据不能被搬错或丢失
func test_migration_graph_keeps_data() -> void:
	var w := _w()
	var e := w.create_entity()
	w.add_component(e, PTCompA)
	w.set_field(e, PTCompA, &"x", 3.0)
	w.set_field(e, PTCompA, &"y", 4.0)

	for i in 5:
		w.add_component(e, PTCompB)
		assert_eq(w.query_rows(PTCompB).size(), 1, "第 %d 轮加组件后应可查" % i)
		w.remove_component(e, PTCompB)
		assert_eq(w.query_rows(PTCompB).size(), 0, "第 %d 轮删组件后不应可查" % i)
		assert_approx(float(w.get_field(e, PTCompA, &"x")), 3.0, "往返迁移后 x 必须保留")
		assert_approx(float(w.get_field(e, PTCompA, &"y")), 4.0, "往返迁移后 y 必须保留")
	assert_eq(w.query_rows(PTCompA).size(), 1, "实体最终仍属于 A 块")


## 多实体 + 多路径: 不同源块加同一组件应汇聚到同一个目标块(边缓存按源块区分)
func test_migration_graph_shares_target_archetype() -> void:
	var w := _w()
	var only_a := w.create_entity()
	w.add_component(only_a, PTCompA)
	var only_b := w.create_entity()
	w.add_component(only_b, PTCompB)

	w.add_component(only_a, PTCompB)   # 源块 A → AB
	w.add_component(only_b, PTCompA)   # 源块 B → AB
	assert_eq(w.query_rows(PTCompA).size(), 2, "两个实体都应含 A")
	assert_eq(w.query_rows(PTCompB).size(), 2, "两个实体都应含 B")

	w.remove_component(only_a, PTCompA)  # AB → B
	w.remove_component(only_b, PTCompA)  # AB → B
	assert_eq(w.query_rows(PTCompA).size(), 0, "A 应已全部移除")
	assert_eq(w.query_rows(PTCompB).size(), 2, "B 仍应保留两个")
