extends TestCase

## 空间索引 / 确定性排序 / 快照差分 / 层级销毁语义 —— 四件"能不能做某类游戏"的地基。
##
## 为什么钉这四条:
## 1) 空间索引: 没有它, "半径 5 内的敌人"只能每帧扫全表(RTS/弹幕都卡在这);
## 2) 排序查询: 联机/回放要求两端遍历顺序一致, 必须有确定的并列规则;
## 3) 快照差分: rollback 的最小可用件(只传变化量, 不是整帧状态);
## 4) 层级销毁: destroy_entity 与 destroy_recursive 是**两种刻意保留的语义**, 不能含糊。

const Move := preload("res://Scripts/Entity/ECS/ECSDemoMoveComponent.gd")


## 10×10 网格(间距 2)。矩形取整格、圆取精确距离; 移动后索引自动失效。
func test_spatial_rect_and_radius() -> void:
	var w := ECSWorld.new(false)
	w.register_component(Move)
	var first := -1
	for i in 10:
		for j in 10:
			var e := w.create_entity()
			w.add_component(e, Move)
			w.set_field(e, Move, &"pos", Vector2(i * 2, j * 2))
			if first < 0:
				first = e
	assert_true(w.spatial_enable(Move, &"pos", 4.0), "VECTOR2 字段应可启用空间索引")

	var rect := w.spatial_query_rect(Vector2(-1, -1), Vector2(3, 3))
	assert_eq(rect.size(), 4, "x,y ∈ {0,2} 共 4 个")

	var rad := w.spatial_query_radius(Vector2(0, 0), 2.5)
	assert_eq(rad.size(), 3, "(0,0)(2,0)(0,2) 命中; (2,2)=2.83 超出")

	# 写入后索引自动失效 → 查询必须看到新位置
	w.set_field(first, Move, &"pos", Vector2(50, 50))
	assert_eq(w.spatial_query_radius(Vector2(50, 50), 1.0).size(), 1, "移动后应在新区被查到")
	assert_eq(w.spatial_query_radius(Vector2(0, 0), 1.0).size(), 0, "旧位置不应再命中")

	# 结果必须升序(确定性)
	for i in range(1, rect.size()):
		assert_true(rect[i - 1] < rect[i], "空间查询结果应升序")

	var st := w.spatial_stats()
	assert_true(bool(st.get("enabled", false)), "stats.enabled")
	assert_eq(int(st.get("entities", 0)), 100, "100 个实体全部入格")


## 排序查询: 按字段升/降序, 并列时以实体 id 为次键(两次调用结果必须完全一致)。
func test_query_rows_sorted_is_deterministic() -> void:
	var w := ECSWorld.new(false)
	w.register_component(PTCompA)
	var vals := [5, 1, 3, 1, 9, 3]
	for v in vals:
		var e := w.create_entity()
		w.add_component(e, PTCompA)
		w.set_field(e, PTCompA, &"x", v)

	var rows := w.query_rows_sorted(PTCompA, [], [], &"x")
	assert_eq(rows.size(), 6, "行集大小")
	var col: PackedInt32Array = w.get_column(PTCompA, &"x")
	for i in range(1, rows.size()):
		assert_true(col[rows[i - 1]] <= col[rows[i]], "升序: 第 %d 个值不应大于后一个" % i)

	var rows_again := w.query_rows_sorted(PTCompA, [], [], &"x")
	assert_eq(rows, rows_again, "同样的世界状态必须给出同样的顺序(可回放)")

	var desc := w.query_rows_sorted(PTCompA, [], [], &"x", true)
	assert_true(col[desc[0]] >= col[desc[desc.size() - 1]], "降序首项 >= 末项")


## 快照差分: 只报变化的字段行; apply_diff 能把值写回。
func test_snapshot_diff_and_apply() -> void:
	var w := ECSWorld.new(false)
	w.register_component(PTCompA)
	var ids: Array[int] = []
	for i in 8:
		var e := w.create_entity()
		w.add_component(e, PTCompA)
		w.set_field(e, PTCompA, &"x", i)
		ids.append(e)

	var a: Dictionary = w.serialize()
	w.set_field(ids[2], PTCompA, &"x", 99)
	w.set_field(ids[5], PTCompA, &"x", 77)
	var b: Dictionary = w.serialize()

	var diff: Dictionary = w.snapshot_diff(a, b)
	var cn: StringName = &"PTCompA"   # 差分的键是组件**名**(serialize 里就是 name), 不是 Script
	assert_true(diff.has(cn), "应有组件级差分")
	var field_diff: Dictionary = diff[cn]
	assert_true(field_diff.has(&"x"), "应有字段级差分")
	var rows: PackedInt32Array = field_diff[&"x"]["rows"]
	assert_eq(rows.size(), 2, "只应报 2 行变化(不传整列)")

	# 回滚: 把 b 的差异应用回去之前, 先恢复成 a 的值再验证 apply 生效
	w.apply_diff(w.snapshot_diff(b, a))   # 反向差分 = 回滚
	assert_eq(int(w.get_field(ids[2], PTCompA, &"x")), 2, "回滚后应恢复旧值")
	assert_eq(int(w.get_field(ids[5], PTCompA, &"x")), 5, "回滚后第二处也恢复")

	assert_true(w.snapshot_diff(a, a).is_empty(), "无变化时差分应为空")


## 层级: destroy_entity 只解除关联(子变孤儿), destroy_recursive 连坐销毁。
func test_destroy_semantics_orphan_vs_recursive() -> void:
	var w := ECSWorld.new(false)
	var p := w.create_entity()
	var c1 := w.create_entity()
	var c2 := w.create_entity()
	var g := w.create_entity()
	w.set_parent(c1, p)
	w.set_parent(c2, p)
	w.set_parent(g, c1)

	# 语义一: 只销毁自己 → 子实体存活且失去父
	w.destroy_entity(p)
	assert_false(w.is_alive(p), "父已销毁")
	assert_true(w.is_alive(c1) and w.is_alive(c2), "子实体必须存活(语义: 只解除关联)")
	assert_eq(w.get_parent(c1), -1, "子的父关联应被清理")

	# 语义二: 连坐销毁 → 子孙全部消失
	var killed := w.destroy_recursive(c1)
	assert_eq(killed, 2, "c1 + 孙子 g 共 2 个")
	assert_false(w.is_alive(c1), "c1 已销毁")
	assert_false(w.is_alive(g), "孙实体也应销毁")
	assert_true(w.is_alive(c2), "兄弟不受影响")
