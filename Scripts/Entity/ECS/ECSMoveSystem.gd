class_name ECSMoveSystem
extends ECSSystem

## ECS 演示移动系统 —— 原生API层(纯 C++ 循环, 无 GDScript 解释)。
##
## 用 Vector2 字段做位置积分:
##   pos += vel * delta   (batch_vec_add, 单次调用处理全部实体)
##
## 对应组件(定义见 Scenes/ECS/ECSDemo.gd 或项目内):
##   ECSDemoMoveComponent: pos: Vector2, vel: Vector2

func required_components() -> Array[Script]:
	return [ECSDemoMoveComponent]

func _run(ctx: ECSSystemContext, delta: float) -> void:
	var w := ctx.world
	# 单次跨语言调用, C++ 内部遍历全部匹配实体: pos += vel * delta
	w.batch_vec_add(ECSDemoMoveComponent, [], ECSDemoMoveComponent, &"pos",
		ECSDemoMoveComponent, &"vel", delta)
