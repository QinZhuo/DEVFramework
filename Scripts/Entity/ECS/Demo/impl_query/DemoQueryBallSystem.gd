class_name DemoQueryBallSystem
extends ECSSystem

## ECS 查询链实现的小球逻辑系统 —— 全部用**现有通用原语** + **向量分量字段**表达,
## 无 process 回调: 移动/回弹/hp 周期/size 都走 C++ batch。
## 分量字段("pos.x"/"vel.y")由框架解析为向量分量操作。
## Def 风格: @export 可在场景/Inspector 配置(在 ECSWorld 的 systems 里注册本系统即可)。

@export var hp_rate := 2.0   # 每秒 hp 变化(满 100 周期约 50 秒)

func required_components() -> Array[Script]:
	return [DemoQueryBall]


func _run(ctx: ECSSystemContext, delta: float) -> void:
	# 移动: pos += vel*delta(向量积分)
	ctx.for_each(DemoQueryBall).add_from(&"pos", DemoQueryBall, &"vel", delta)
	# 边界回弹: 越界时该方向速度取反 + 位置钳制(分量操作)
	ctx.for_each(DemoQueryBall).where(&"pos.x").less_than(10.0).mul(&"vel.x", -1.0).set_value(&"pos.x", 10.0)
	ctx.for_each(DemoQueryBall).where(&"pos.x").greater_than(1150.0).mul(&"vel.x", -1.0).set_value(&"pos.x", 1150.0)
	ctx.for_each(DemoQueryBall).where(&"pos.y").less_than(10.0).mul(&"vel.y", -1.0).set_value(&"pos.y", 10.0)
	ctx.for_each(DemoQueryBall).where(&"pos.y").greater_than(710.0).mul(&"vel.y", -1.0).set_value(&"pos.y", 710.0)
	# hp 周期: hp += dir*rate, 越界翻转方向 + 钳制(保持 [0, 100])
	ctx.for_each(DemoQueryBall).add_from(&"hp", DemoQueryBall, &"dir", hp_rate * delta * 60.0)
	ctx.for_each(DemoQueryBall).where(&"hp").greater_than(100.0).mul(&"dir", -1.0).set_value(&"hp", 100.0)
	ctx.for_each(DemoQueryBall).where(&"hp").less_than(0.0).mul(&"dir", -1.0).set_value(&"hp", 0.0)
	# size = hp
	ctx.for_each(DemoQueryBall).set_from(&"size", DemoQueryBall, &"hp")
