class_name PTDSLTest
extends RefCounted

## 规则层 DSL 扩展自检: 列间运算(add_from/set_from/clamp_where) + process 预拉列自动写回

static func _q(w: ECSWorld) -> ECSQuery:
	return load("res://addons/DEVFramework/ECS/ECSQuery.gd").new()._init_rule(w, PTCompA)

static func run() -> bool:
	var all_ok := true
	var w := ECSWorld.new(false)
	w.register_component(PTCompA)
	w.register_component(PTCompB)
	var ids: Array[int] = []
	for i in 10:
		var e := w.create_entity()
		w.add_component(e, PTCompA)
		w.add_component(e, PTCompB)
		w.set_field(e, PTCompA, &"x", i)
		w.set_field(e, PTCompA, &"y", float(i))
		w.set_field(e, PTCompA, &"z", 3.0)
		w.set_field(e, PTCompA, &"max_v", 8.0)
		w.set_field(e, PTCompB, &"x", i * 2)
		ids.append(e)

	# ---- clamp_where: x > 4 的实体 clamp x 到 [0, 8] ----
	var q := _q(w)
	q.where(&"x").greater_than(4)
	q.clamp_where(&"x", PTCompA, &"min_v", PTCompA, &"max_v")
	q.execute()
	all_ok = all_ok and int(w.get_field(ids[9], PTCompA, &"x")) == 8 \
			and int(w.get_field(ids[5], PTCompA, &"x")) == 5 \
			and int(w.get_field(ids[3], PTCompA, &"x")) == 3
	print("[DSL] clamp_x9=", int(w.get_field(ids[9], PTCompA, &"x")),   # 9 → 8
			" clamp_x5=", int(w.get_field(ids[5], PTCompA, &"x")),       # 5 → 5
			" clamp_x3=", int(w.get_field(ids[3], PTCompA, &"x")))       # 3(条件外) → 3

	# ---- add_from: a.x += b.x (INT 列间) ----
	var q2 := _q(w)
	q2.add_from(&"x", PTCompB, &"x")
	q2.execute()
	all_ok = all_ok and int(w.get_field(ids[1], PTCompA, &"x")) == 3
	print("[DSL] add_from=", int(w.get_field(ids[1], PTCompA, &"x")))    # 1+2=3

	# ---- set_from: a.y = a.z * 2 (FLOAT, factor) ----
	var q3 := _q(w)
	q3.set_from(&"y", PTCompA, &"z", 2.0, 1.0)
	q3.execute()
	all_ok = all_ok and is_equal_approx(float(w.get_field(ids[3], PTCompA, &"y")), 7.0)
	print("[DSL] set_from=", float(w.get_field(ids[3], PTCompA, &"y")))  # 3*2+1=7

	# ---- process fields 模式: 预拉列 + 自动写回(回调内零跨语言) ----
	var q4 := _q(w)
	q4.process(func(rows: PackedInt32Array, data: Dictionary):
		var xc: PackedInt32Array = data["PTCompA"]["x"]
		for r in rows:
			xc[r] += 1000
	, {PTCompA: [&"x"]})
	q4.execute()
	all_ok = all_ok and int(w.get_field(ids[0], PTCompA, &"x")) == 1000
	print("[DSL] process_fields=", int(w.get_field(ids[0], PTCompA, &"x")))  # 1000

	# ---- with().process(): 回调直接收列参数(推荐写法, 无字符串 key) ----
	# 注: 前面 q3/q4 均无 where 条件, 作用全部 10 行 —— ids[1] 已被 q4 累加 +1000,
	# 故本步 x = 3(add_from) + 1000(q4) + 500(本步) = 1503; y = 7(set_from) + 0.5 = 7.5
	var q5 := _q(w)
	q5.with([&"x", &"y"])
	q5.process(PTDSLTest._with_cb)
	q5.execute()
	all_ok = all_ok and int(w.get_field(ids[1], PTCompA, &"x")) == 1503 \
			and is_equal_approx(float(w.get_field(ids[1], PTCompA, &"y")), 7.5)
	print("[DSL] with_process_x=", int(w.get_field(ids[1], PTCompA, &"x")),  # 3+1000+500=1503
			" y=", float(w.get_field(ids[1], PTCompA, &"y")))              # 7+0.5=7.5
	return all_ok


static func _with_cb(rows: PackedInt32Array, xc: PackedInt32Array, yc: PackedFloat32Array) -> void:
	for r in rows:
		xc[r] += 500
		yc[r] += 0.5
