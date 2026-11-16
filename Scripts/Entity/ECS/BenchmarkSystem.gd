class_name BenchmarkSystem
extends ECSSystem

## 基准系统: 模拟战斗数值计算
## 每实体: hp 增加/回复, 位置移动, 属性校验
## 跨组件访问 → process 对齐行号模式(comp_rows)

func required_components() -> Array[Script]:
	return [HealthComponent, MoveComponent]

func _run(ctx: ECSSystemContext, delta: float) -> void:
	ctx.for_each(HealthComponent, [MoveComponent]).process(func(rows, comp_rows, w):
		# 每个组件一次取列(共 2 次跨语言, 而不是 6 次 get_column)
		var hc: Dictionary = w.columns_of(HealthComponent, [&"hp", &"max_hp"])
		var mc: Dictionary = w.columns_of(MoveComponent, [&"x", &"y", &"vx", &"vy"])
		var hp: PackedInt32Array = hc[&"hp"]
		var max_hp: PackedInt32Array = hc[&"max_hp"]
		var x: PackedFloat32Array = mc[&"x"]
		var y: PackedFloat32Array = mc[&"y"]
		var vx: PackedFloat32Array = mc[&"vx"]
		var vy: PackedFloat32Array = mc[&"vy"]
		var hr: PackedInt32Array = comp_rows["HealthComponent"]
		var mr: PackedInt32Array = comp_rows["MoveComponent"]
		for k in rows.size():
			var rh := hr[k]
			var rm := mr[k]
			if hp[rh] < max_hp[rh]:
				hp[rh] = mini(hp[rh] + 1, max_hp[rh])
			x[rm] += vx[rm] * delta
			y[rm] += vy[rm] * delta
		w.set_columns_of(HealthComponent, {&"hp": hp})
		w.set_columns_of(MoveComponent, {&"x": x, &"y": y})
	, [HealthComponent, MoveComponent]).execute()
