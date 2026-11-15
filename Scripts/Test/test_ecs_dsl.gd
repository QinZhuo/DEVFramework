extends TestCase

## 规则层 DSL: 列间运算(add_from/set_from/clamp_where) + process 预拉列自动写回。
##
## 注意: 下列步骤**共用同一个世界且顺序有依赖**, 期望值是累计出来的(注释里逐项标了来源),
## 所以必须放在同一个 test_ 方法里 —— 拆开会让后半段读到不同的初始值。

var _w: ECSWorld
var _ids: Array[int] = []


func _q() -> ECSQuery:
	return load("res://addons/DEVFramework/ECS/System/ECSQuery.gd").new()._init_rule(_w, PTCompA)


func _x(idx: int) -> int:
	return int(_w.get_field(_ids[idx], PTCompA, &"x"))


func _y(idx: int) -> float:
	return float(_w.get_field(_ids[idx], PTCompA, &"y"))


func test_rule_layer_dsl() -> void:
	_w = ECSWorld.new(false)
	_w.register_component(PTCompA)
	_w.register_component(PTCompB)
	for i in 10:
		var e := _w.create_entity()
		_w.add_component(e, PTCompA)
		_w.add_component(e, PTCompB)
		_w.set_field(e, PTCompA, &"x", i)
		_w.set_field(e, PTCompA, &"y", float(i))
		_w.set_field(e, PTCompA, &"z", 3.0)
		_w.set_field(e, PTCompA, &"max_v", 8.0)
		_w.set_field(e, PTCompB, &"x", i * 2)
		_ids.append(e)

	# ---- clamp_where: x > 4 的实体陷阱 x 到 [0, 8] ----
	var q := _q()
	q.where(&"x").greater_than(4)
	q.clamp_where(&"x", PTCompA, &"min_v", PTCompA, &"max_v")
	q.execute()
	assert_eq(_x(9), 8, "9 应被 clamp 到 8")
	assert_eq(_x(5), 5, "5 在区间内, 不应变")
	assert_eq(_x(3), 3, "3 不满足条件, 不应变")

	# ---- add_from: a.x += b.x (INT 列间) ----
	var q2 := _q()
	q2.add_from(&"x", PTCompB, &"x")
	q2.execute()
	assert_eq(_x(1), 3, "1 + 2 = 3")

	# ---- set_from: a.y = a.z * 2 + 1 (FLOAT) ----
	var q3 := _q()
	q3.set_from(&"y", PTCompA, &"z", 2.0, 1.0)
	q3.execute()
	assert_approx(_y(3), 7.0, "3 * 2 + 1 = 7")

	# ---- process fields 模式: 预拉列 + 自动写回(回调内零跨语言) ----
	var q4 := _q()
	q4.process(func(rows: PackedInt32Array, data: Dictionary):
		var xc: PackedInt32Array = data["PTCompA"]["x"]
		for r in rows:
			xc[r] += 1000
	, {PTCompA: [&"x"]})
	q4.execute()
	assert_eq(_x(0), 1000, "0 + 1000 = 1000")

	# ---- with().process(): 回调直接收列参数(推荐写法, 无字符串 key) ----
	# 累计: x = 3(add_from) + 1000(q4) + 500(本步) = 1503; y = 7(set_from) + 0.5 = 7.5
	var q5 := _q()
	q5.with([&"x", &"y"])
	q5.process(_with_cb)
	q5.execute()
	assert_eq(_x(1), 1503, "3 + 1000 + 500 = 1503")
	assert_approx(_y(1), 7.5, "7 + 0.5 = 7.5")


func _with_cb(rows: PackedInt32Array, xc: PackedInt32Array, yc: PackedFloat32Array) -> void:
	for r in rows:
		xc[r] += 500
		yc[r] += 0.5
