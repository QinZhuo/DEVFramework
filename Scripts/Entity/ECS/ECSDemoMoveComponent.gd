class_name ECSDemoMoveComponent
extends ECSComponent

## ECS 演示移动组件 —— 纯数据(Vector2 位置/速度 + 颜色)。
## 由 ECSMoveSystem 用 Tier0 batch_vec_add 做原生位置积分。
## color 字段: 表现节点颜色, 存入组件保证存档/读档时颜色一致。

@export var pos: Vector2 = Vector2.ZERO
@export var vel: Vector2 = Vector2.ZERO
@export var color: Color = Color.WHITE
