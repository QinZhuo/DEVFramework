class_name DemoQueryBall
extends ECSComponent

## ECS 查询链实现的小球组件 —— 随机移动 + 生命值周期增减。
## hp 0..100 驱动大小, dir 控制增减方向。纯数据 schema, 运行时数据存 C++ SoA 列。
## (同 entity 里的 BallComponent, 用前缀 DemoQuery 区分实现)

@export var x: float = 0.0
@export var y: float = 0.0
@export var vx: float = 0.0
@export var vy: float = 0.0
@export var hp: float = 50.0
@export var max_hp: float = 100.0
@export var dir: int = 1      # +1 增 / -1 减
@export var size: float = 5.0
