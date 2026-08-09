class_name DemoEntityBallSystem
extends ECSSystem

## Entity 节点写法实现的系统: 完整小球逻辑用列批量处理(移动+边界回弹+hp周期+size)。
## 组件就是 Entity2D 子类脚本(DemoEntityBallNode), 其 @export 数据字段即 schema ——
## 无需单独的 ECSComponent 组件资源, 系统直接面向节点脚本处理数据列。

const HP_RATE := 2.0   # 每秒 hp 变化(满 100 周期约 50 秒)

## 每帧处理的实体数(供 UI 展示)
var processed := 0

func required_components() -> Array[Script]:
	return [DemoEntityBallNode]


func _run(ctx: ECSSystemContext, delta: float) -> void:
	ctx.for_each(DemoEntityBallNode).with([&"pos", &"vel", &"hp", &"max_hp", &"dir", &"size"]).process(_cb.bind(delta))


func _cb(indices: PackedInt32Array, pos: PackedVector2Array, vel: PackedVector2Array,
		hp: PackedFloat32Array, max_hp: PackedFloat32Array,
		dir: PackedInt32Array, size: PackedFloat32Array, delta: float) -> void:
	processed = indices.size()
	var rate := HP_RATE * delta * 60.0
	for r in indices:
		# 移动(Vector2 列直算)
		pos[r] += vel[r] * delta
		# 边界回弹
		if pos[r].x < 10.0 or pos[r].x > 1150.0:
			vel[r].x = -vel[r].x
			pos[r].x = clampf(pos[r].x, 10.0, 1150.0)
		if pos[r].y < 10.0 or pos[r].y > 710.0:
			vel[r].y = -vel[r].y
			pos[r].y = clampf(pos[r].y, 10.0, 710.0)
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
