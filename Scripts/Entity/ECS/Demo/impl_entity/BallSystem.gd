class_name DemoEntityBallSystem
extends ECSSystem

## Entity 节点写法实现的系统: 完整小球逻辑用列批量处理(移动+边界回弹+hp周期+size)。
## 这就是"Entity 节点写法借助 ECS 底层"的关键 —— 每帧高频逻辑走系统(SoA 列 + 批量),
## Entity2D 节点的传统写法只用于低频的配置/交互(node.hp = 80), 节点不再逐帧单实体读写。

const HP_RATE := 2.0   # 每秒 hp 变化(满 100 周期约 50 秒)

## 每帧处理的实体数(供 UI 展示)
var processed := 0

func required_components() -> Array[Script]:
	return [DemoEntityBall]


func _run(ctx: ECSSystemContext, delta: float) -> void:
	ctx.for_each(DemoEntityBall).with([&"x", &"y", &"vx", &"vy", &"hp", &"max_hp", &"dir", &"size"]).process(_cb.bind(delta))


func _cb(indices: PackedInt32Array, x: PackedFloat32Array, y: PackedFloat32Array,
		vx: PackedFloat32Array, vy: PackedFloat32Array, hp: PackedFloat32Array,
		max_hp: PackedFloat32Array, dir: PackedInt32Array, size: PackedFloat32Array, delta: float) -> void:
	processed = indices.size()
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
