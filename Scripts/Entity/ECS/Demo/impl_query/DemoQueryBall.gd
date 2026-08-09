class_name DemoQueryBall
extends ECSComponent

## ECS 查询链实现的小球组件 —— 随机移动 + 生命值周期增减。
## 位置用 Vector2 类型(pos/vel), 不拆分 x/y。纯数据 schema, 运行时数据存 C++ SoA 列。
## (同 entity 里的 BallComponent, 用前缀 DemoQuery 区分实现)

@export var pos: Vector2 = Vector2.ZERO
@export var vel: Vector2 = Vector2.ZERO
@export var hp: float = 50.0
@export var max_hp: float = 100.0
@export var dir: int = 1      # +1 增 / -1 减
@export var size: float = 5.0
