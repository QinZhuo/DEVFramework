class_name DemoQueryBallSystem
extends ECSSystem

## ECS 查询链实现的小球逻辑系统 —— 用 for_each 查询链 + process 回调(列批量访问)。
## 移动 + 边界回弹 + 生命值周期增减 + 大小随 hp(与另外两种实现逻辑一致, 独立实现)。

const HP_RATE := 2.0   # 每秒 hp 变化(满 100 周期约 50 秒)

func required_components() -> Array[Script]:
	return [DemoQueryBall]


func _run(ctx: ECSSystemContext, delta: float) -> void:
	# 声明式写法: 无需 .execute(), 系统 _run 结束后框架自动执行
	ctx.for_each(DemoQueryBall).with([&"x", &"y", &"vx", &"vy", &"hp", &"max_hp", &"dir", &"size"]).process(_cb.bind(delta))


func _cb(indices: PackedInt32Array, x: PackedFloat32Array, y: PackedFloat32Array,
		vx: PackedFloat32Array, vy: PackedFloat32Array, hp: PackedFloat32Array,
		max_hp: PackedFloat32Array, dir: PackedInt32Array, size: PackedFloat32Array, delta: float) -> void:
	var rate := HP_RATE * delta * 60.0
	for r in indices:
		# 移动
		x[r] += vx[r] * delta
		y[r] += vy[r] * delta
		# 边界回弹
		if x[r] < 10.0 or x[r] > 1150.0:
			vx[r] = -vx[r]
			x[r] = clampf(x[r], 10.0, 1150.0)
		if y[r] < 10.0 or y[r] > 710.0:
			vy[r] = -vy[r]
			y[r] = clampf(y[r], 10.0, 710.0)
		# 生命值周期增减: 0 → 100 → 0
		hp[r] += dir[r] * rate
		if hp[r] >= max_hp[r]:
			hp[r] = max_hp[r]
			dir[r] = -1
		elif hp[r] <= 0.0:
			hp[r] = 0.0
			dir[r] = 1
		# 大小 = hp(0 消失, 100 最大)
		size[r] = hp[r]
