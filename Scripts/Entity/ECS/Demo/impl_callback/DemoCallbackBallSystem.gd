class_name DemoCallbackBallSystem
extends ECSSystem

## ECS 查询链回调实现的小球逻辑系统 —— 与 DemoQueryBallSystem(声明式 batch 多查询)
## 完全相同的组件/节点/同步布局, 唯一区别是逻辑层写法:
##   声明式: 9 个 for_each 链 → C++ batch(SIMD + 并行)
##   本系统: 1 个 for_each.with(字段).process(回调) → GDScript 手写循环
## process 回调借出列(独占引用, 写列无 COW 深拷贝) → 回调内直接读写列, 零跨语言。
## 作为"声明式 vs 手写回调"两种查询链用法的性能对比参照。

const HP_RATE := 2.0   # 每秒 hp 变化(满 100 周期约 50 秒)

## 每帧处理的实体数(供 UI 展示)
var processed := 0


func required_components() -> Array[Script]:
	return [DemoQueryBall]


func _run(ctx: ECSSystemContext, delta: float) -> void:
	ctx.for_each(DemoQueryBall).with([&"pos", &"vel", &"hp", &"max_hp", &"dir", &"size"]).process(_cb.bind(delta))


## 回调: 借出列按声明顺序收参数, 直接读写列数组(与声明式 batch 结果完全一致)。
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
