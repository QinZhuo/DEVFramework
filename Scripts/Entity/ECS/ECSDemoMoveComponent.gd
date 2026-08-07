class_name ECSDemoMoveComponent
extends ECSComponent

## ECS 演示移动组件 —— 纯数据(Vector2 位置/速度)。
## 由 ECSMoveSystem 用 Tier0 batch_vec_add 做原生位置积分。

@export var pos: Vector2 = Vector2.ZERO
@export var vel: Vector2 = Vector2.ZERO
