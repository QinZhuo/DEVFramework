extends TestCase

## 矩阵探针: 多组件 × 多字段类型 × prefab × 批量 × 存档 × 空间索引。
##
## 为什么需要它(而不是靠现有用例): 上次"列扁平化"重构把 `cols`(总字段数) 当成
## "组件数"去索引, `instantiate` 直接越界把编辑器打崩(0xc0000005 @ 0x1ca42), 而当时
## 230 项测试全绿 —— 因为没有一个用例同时具备"多组件 + 多字段 + prefab + instantiate"。
## 这份用例就是那类组合的最小覆盖: 任何列偏移/行对齐错误都会在值断言上立刻红。

const Move := preload("res://Scripts/Entity/ECS/ECSDemoMoveComponent.gd")

const N := 500


func _mk_world() -> Dictionary:
	var w := ECSWorld.new(false)
	w.register_component(Move)      # pos:Vector2, vel:Vector2, color:Color
	w.register_component(PTCompA)   # x,y,z,min_v,max_v: int
	var pf := w.create_prefab()
	w.prefab_add(pf, Move, {})
	w.prefab_add(pf, PTCompA, {})
	return {"world": w, "prefab": pf}


## instantiate + overrides: 每个字段的值都要落在正确的列/行上。
func test_instantiate_multi_component_values() -> void:
	var b := _mk_world()
	var w: ECSWorld = b["world"]
	var pf: int = b["prefab"]
	w.instantiate(pf, N, {
		Move: {"pos": Vector2(3, 4), "vel": Vector2(0.5, -0.5), "color": Color(1, 0, 0, 1)},
		PTCompA: {"x": 11, "y": 22, "z": 33, "min_v": 1, "max_v": 99},
	})
	var ents := w.query_entities(Move, [PTCompA], [])
	assert_eq(ents.size(), N, "两个组件都在的实体数")

	var pos: PackedVector2Array = w.get_column(Move, &"pos")
	var vel: PackedVector2Array = w.get_column(Move, &"vel")
	var col: PackedColorArray = w.get_column(Move, &"color")
	assert_eq(pos.size(), N, "pos 列长度")
	var ok := true
	for i in N:
		if pos[i] != Vector2(3, 4) or vel[i] != Vector2(0.5, -0.5) or col[i] != Color(1, 0, 0, 1):
			ok = false
			break
	assert_true(ok, "Vector2/Color 覆盖值必须逐行一致(错列/错行会在这里暴露)")

	for f in [&"x", &"y", &"z", &"min_v", &"max_v"]:
		# 字段是 float → 拿到的是 PackedFloat32Array(不要写死成 Int32, 那是靠类型猜的)
		var c = w.get_column(PTCompA, f)
		assert_eq(int(c.size()), N, "%s 列长度" % f)
		var want: int = int({&"x": 11, &"y": 22, &"z": 33, &"min_v": 1, &"max_v": 99}[f])
		assert_eq(int(c[0]), want, "%s 首行" % f)
		assert_eq(int(c[N - 1]), want, "%s 末行" % f)


## columns_of 一次取 8 列(2 组件 × 3+5 字段): 长度与值都要对。
func test_columns_of_multi_field() -> void:
	var b := _mk_world()
	var w: ECSWorld = b["world"]
	w.instantiate(b["prefab"], 64, {Move: {"pos": Vector2(7, 8)}})
	var cols := w.columns_of(Move, [&"pos", &"vel", &"color"])
	assert_eq(cols.size(), 3, "Move 三列")
	assert_eq((cols[&"pos"] as PackedVector2Array).size(), 64, "pos 行数")
	assert_eq((cols[&"pos"] as PackedVector2Array)[63], Vector2(7, 8), "覆盖值落在末行")
	var ints := w.columns_of(PTCompA, [&"x", &"y", &"z", &"min_v", &"max_v"])
	assert_eq(ints.size(), 5, "PTCompA 五列")


## 整列写 Vector2/Color(曾经整列写成 0 的路径) + 批量算子回读。
func test_write_columns_vector_types() -> void:
	var b := _mk_world()
	var w: ECSWorld = b["world"]
	w.instantiate(b["prefab"], 32)
	var want := PackedVector2Array()
	var want_c := PackedColorArray()
	for i in 32:
		want.append(Vector2(i, i * 2))
		want_c.append(Color(0.1 * i, 0.2, 0.3, 1.0))
	w.set_columns_of(Move, {&"pos": want, &"color": want_c})
	var got: PackedVector2Array = w.get_column(Move, &"pos")
	var got_c: PackedColorArray = w.get_column(Move, &"color")
	var ok := true
	for i in 32:
		if got[i] != want[i] or got_c[i] != want_c[i]:
			ok = false
			break
	assert_true(ok, "整列写 Vector2/Color 必须能原样读回")

	var rows: PackedInt32Array = w.query_rows(PTCompA)
	w.batch_apply_rows(PTCompA, rows, PTCompA, &"x", 0, 1.0, 5.0)   # +5
	var x = w.get_column(PTCompA, &"x")
	assert_eq(int(x.size()), 32, "x 列长度")
	assert_true(int(x[0]) == 5 and int(x[31]) == 5, "批量 +5 后每行都是 5(初始 0)")


## 存档往返: 多组件多字段全等(列错位在 serialize/deserialize 会放大)。
func test_serialize_roundtrip_multi_component() -> void:
	var b := _mk_world()
	var w: ECSWorld = b["world"]
	w.instantiate(b["prefab"], 40, {
		Move: {"pos": Vector2(1.5, 2.5), "color": Color(0, 1, 0, 1)},
		PTCompA: {"x": 7, "y": 8},
	})
	var snap: Dictionary = w.serialize()
	var w2 := ECSWorld.new(false)
	w2.register_component(Move)
	w2.register_component(PTCompA)
	w2.deserialize(snap)
	assert_true(_same(snap, w2.serialize()), "读档后逐字段相等")


## 空间索引建在 Move.pos 上: 多组件世界里也要能正确查(不能把别的块算进来)。
func test_spatial_on_move_component() -> void:
	var b := _mk_world()
	var w: ECSWorld = b["world"]
	w.instantiate(b["prefab"], 100, {
		Move: {"pos": Vector2(0, 0)},
		PTCompA: {"x": 1},
	})
	# 再造 10 个只有 Move 的实体(不同块), 空间索引必须都覆盖
	var pf2 := w.create_prefab()
	w.prefab_add(pf2, Move, {})
	w.instantiate(pf2, 10, {Move: {"pos": Vector2(50, 50)}})

	assert_true(w.spatial_enable(Move, &"pos", 8.0), "启用空间索引")
	var near: PackedInt32Array = w.spatial_query_rect(Vector2(-1, -1), Vector2(1, 1))
	assert_eq(near.size(), 100, "原点附近应有 100 个")
	var far: PackedInt32Array = w.spatial_query_radius(Vector2(50, 50), 1.0)
	assert_eq(far.size(), 10, "另一块里应有 10 个")


func _same(a: Dictionary, c: Dictionary) -> bool:
	var ac: Array = a.get("components", [])
	var cc: Array = c.get("components", [])
	if ac.size() != cc.size():
		return false
	for i in ac.size():
		var ca: Dictionary = ac[i]
		var cb: Dictionary = cc[i]
		if ca.get("name") != cb.get("name"):
			return false
		var fa: Dictionary = ca.get("columns", {})
		var fb: Dictionary = cb.get("columns", {})
		if fa.size() != fb.size():
			return false
		for f in fa:
			if fa[f] != fb.get(f):
				return false
	return true
